// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import ChargeBackends
@testable import TilveroApp

@MainActor final class ChargePopoverStabilityTests: XCTestCase {
    func testChargeReadDoesNotRepeatedlyResizeOrRestartFromLayout() async throws {
        let suite = TestDefaults.name("ChargeStability"), preferences = TestDefaults.defaults(suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeStability-\(UUID())")
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(false, forKey: "historyEnabled")
        let transport = PopoverReadTransport()
        let native = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("native.json"))
        await native.refresh()
        await transport.setDelay(.milliseconds(50))
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                snapshotProvider: { .unavailable(reason: "Popover fixture") }, nativeCharge: native)
        defer { model.stop() }
        let host = QuickPanelHostingController(model: model, maximumHeight: 900)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let segments = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSegmentedControl }.first)
        var heights: [CGFloat] = []
        host.onSizeChange = { size in heights.append(size.height); window.setContentSize(size) }
        segments.selectedSegment = 1; _ = segments.sendAction(segments.action, to: segments.target)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded()
        }
        let reads = await transport.readCount
        print("Charge opening geometry: \(heights); native reads: \(reads)")
        XCTAssertLessThanOrEqual(reads, 2, "Layout must not remount the charge reader after a read-only update")
        XCTAssertLessThanOrEqual(heights.count, 1, "Opening Charge should commit its natural height once, without a loading-row jump")
        heights = []
        await model.refreshNativeCharge()
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        print("Charge refresh geometry: \(heights)")
        XCTAssertTrue(heights.isEmpty, "A read-only refresh with unchanged settings must not resize the open menu")
        let writes = await transport.writes
        XCTAssertEqual(writes, 0)
    }

    func testOpeningChargeAfterThePanelOpenedResizesOnceEvenWithoutAdmission() async throws {
        let suite = TestDefaults.name("ChargeOpenOnce"), preferences = TestDefaults.defaults(suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeOpenOnce-\(UUID())")
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(false, forKey: "historyEnabled")
        let transport = PopoverReadTransport()
        // Nothing read yet: the panel discovers (and is granted) the interface up front.
        let native = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("native.json"))
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                snapshotProvider: { .unavailable(reason: "Popover fixture") }, nativeCharge: native)
        defer { model.stop() }
        await model.quickPanelWillOpen()
        XCTAssertTrue(model.usesNativeCharge, "Opening the panel discovers the native interface.")
        await transport.setDelay(.milliseconds(50))
        let host = QuickPanelHostingController(model: model, maximumHeight: 900)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let segments = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSegmentedControl }.first)
        var heights: [CGFloat] = []
        host.onSizeChange = { size in heights.append(size.height); window.setContentSize(size) }
        segments.selectedSegment = 1; _ = segments.sendAction(segments.action, to: segments.target)
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertLessThanOrEqual(heights.count, 1, "Opening Charge must resize once, not grow and shrink: \(heights)")
    }

    func testCompactRefreshKeepsStableProgressAndFailedPolicyVisible() async throws {
        let fixture = try StatusFixture()
        defer { fixture.cleanUp() }
        await fixture.native.refresh()
        let panel = StatusProbe(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.rows.frame(width: 320))
        let window = NSWindow(contentViewController: host)
        let initialSize = host.sizeThatFits(in: NSSize(width: 320, height: 900))
        window.setContentSize(initialSize)
        host.view.layoutSubtreeIfNeeded()

        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height,
                       "Known settings need an in-place read indicator, without adding a loading row")
        XCTAssertEqual(fixture.native.presentation().pendingPurpose, .read)
        XCTAssertNil(panel.text, "Known-setting reads use the in-place progress indicator")

        await fixture.transport.releaseRead(failing: true)
        await refresh.value
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.native.presentation().attention, .policyUnconfirmed)
        XCTAssertNil(fixture.native.presentation().activePolicy, "the policy is not claimed")
        XCTAssertNotNil(fixture.native.message, "the failure is recorded (Details show it)")
        // The stored setting read moments ago is still fresh and shown as it is: no line flashes for a one-off read error.
        XCTAssertNil(panel.text)
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height)

        // A held background read keeps the attention, the status text and the height (no flicker on every poll).
        let before = panel.text
        await fixture.transport.holdNextRead()
        let poll = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.native.presentation().attention, .policyUnconfirmed)
        XCTAssertEqual(panel.text, before)
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height)
        await fixture.transport.releaseRead()
        await poll.value
        let writes = await fixture.transport.writes
        XCTAssertEqual(writes, 0)
    }

    func testCompactReadPreservesFreshPartialPolicyWarningAndHeight() async throws {
        let fixture = try StatusFixture()
        defer { fixture.cleanUp() }
        await fixture.transport.useIncompleteReads()
        await fixture.native.refresh()
        XCTAssertEqual(fixture.native.currentReportedTarget, 100)
        XCTAssertEqual(fixture.native.diagnosticStoredTarget, 90)
        XCTAssertFalse(fixture.model.canApply)

        let panel = StatusProbe(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.rows.frame(width: 320))
        let window = NSWindow(contentViewController: host)
        let proposal = NSSize(width: 320, height: 900)
        let initialSize = host.sizeThatFits(in: proposal)
        window.setContentSize(initialSize)
        host.view.layoutSubtreeIfNeeded()
        let warning = try XCTUnwrap(panel.text)

        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.model.refreshNativeCharge() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.native.presentation().pendingPurpose, .read)
        XCTAssertEqual(panel.text, warning)
        XCTAssertEqual(host.sizeThatFits(in: proposal), initialSize)
        XCTAssertFalse(fixture.model.canApply)
        await fixture.transport.releaseRead()
        await refresh.value

        XCTAssertEqual(panel.text, warning)
        XCTAssertEqual(fixture.model.draftText, "100")
        let writes = await fixture.transport.writes
        XCTAssertEqual(writes, 0)
    }

    /// An unconfirmed change keeps its line (and the height) through a background read, as a conflict hint does.
    func testAnUnresolvedSessionLineStaysVisibleDuringRead() async throws {
        let normal = try StatusFixture()
        defer { normal.cleanUp() }
        await normal.native.refresh()
        let normalHost = NSHostingController(rootView: StatusProbe(model: normal.model, compact: true).rows.frame(width: 320))
        let normalHeight = normalHost.sizeThatFits(in: NSSize(width: 320, height: 900)).height
        let configuration = NativeChargeConfiguration(enabled: true, target: 90, optimizedCharging: true)
        var journal = NativeChargeJournal(sessionID: UUID(), environment: "popover-fixture", baseline: configuration,
            lastVerified: configuration, plannedTarget: 85, phase: .indeterminate, hasWritten: true,
            expectedMutation: .init(enabled: true, target: 85, optimizedCharging: true))
        journal.version = 2; journal.semanticContract = NativeChargeAdmission.semanticContract
        journal.persistentTargets = NativeChargeAdmission.persistentTargets
        journal.baselineSnapshot = .init(configuration: configuration, supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 90)
        let unresolved = try StatusFixture(journal: journal)
        defer { unresolved.cleanUp() }
        await unresolved.native.refresh()   // young: the session stays
        XCTAssertTrue(unresolved.native.hasUnresolvedSession)
        XCTAssertEqual(StatusProbe(model: unresolved.model, compact: true).text, "macOS has not confirmed the last change yet.")
        try await assertReadKeepsWarningVisible(unresolved, normalHeight: normalHeight)
        let normalWrites = await normal.transport.writes, unresolvedWrites = await unresolved.transport.writes
        XCTAssertEqual(normalWrites + unresolvedWrites, 0)
    }

    /// The very first read (nothing known yet) shows its progress; a later background read keeps the confirmed state.
    func testFirstUnknownReadShowsProgressAndABackgroundReadKeepsTheConfirmedState() async throws {
        for known in [false, true] {
            let fixture = try StatusFixture()
            defer { fixture.cleanUp() }
            if known { await fixture.native.refresh() }
            let panel = StatusProbe(model: fixture.model, compact: !known)
            let host = NSHostingController(rootView: panel.rows.frame(width: 320))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(host.sizeThatFits(in: NSSize(width: 320, height: 900)))
            await fixture.transport.holdNextRead()
            let refresh = Task { await fixture.native.refresh() }
            await fixture.transport.waitUntilSuspended()
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutSubtreeIfNeeded()
            if known {
                XCTAssertEqual(fixture.native.presentation().attention, .none, "a background read is not a pending operation")
                XCTAssertEqual(fixture.native.presentation().activePolicy?.target, 90, "the confirmed policy stays shown")
                XCTAssertNil(panel.text)
            } else {
                XCTAssertEqual(panel.text, "Reading the native charge policy…")
            }
            await fixture.transport.releaseRead()
            await refresh.value
            let writes = await fixture.transport.writes
            XCTAssertEqual(writes, 0)
        }
    }

    func testTimedOutReadKeepsItsWarningWhileUnderlyingReadRemainsPending() async throws {
        let fixture = try StatusFixture(operationTimeout: .milliseconds(30))
        defer { fixture.cleanUp() }
        await fixture.native.refresh()
        let panel = StatusProbe(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.rows.frame(width: 320))
        let normalHeight = host.sizeThatFits(in: NSSize(width: 320, height: 900)).height
        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        await refresh.value
        XCTAssertFalse(fixture.native.isBusy, "The deadline returns control without claiming transport cancellation")
        XCTAssertEqual(fixture.native.presentation().pendingPurpose, .read)
        XCTAssertTrue(fixture.native.presentation().pendingTimedOut)
        // A fixed line (the service message is overwritten by the refresh that timed out).
        XCTAssertEqual(panel.text, "The native policy read timed out. Further actions wait for the read to return.",
                       "An overdue read needs its warning, rather than only the compact progress indicator")
        XCTAssertGreaterThan(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, normalHeight)
        await fixture.transport.releaseRead()
        for _ in 0..<200 where fixture.native.presentation().pendingPurpose != nil { await Task.yield() }
        XCTAssertFalse(fixture.native.presentation().pendingTimedOut, "the late return clears it")
        XCTAssertNil(panel.text, "the fresh stored setting is shown as it is")
        let writes = await fixture.transport.writes
        XCTAssertEqual(writes, 0)
    }

    private func assertReadKeepsWarningVisible(_ fixture: StatusFixture, normalHeight: CGFloat) async throws {
        let panel = StatusProbe(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.rows.frame(width: 320))
        let window = NSWindow(contentViewController: host)
        let initialSize = host.sizeThatFits(in: NSSize(width: 320, height: 900))
        window.setContentSize(initialSize)
        let originalStatus = panel.text
        XCTAssertGreaterThan(initialSize.height, normalHeight, "An unresolved-session line must occupy visible space")
        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height,
                       "Read progress must preserve the status line")
        XCTAssertEqual(panel.text, originalStatus)
        await fixture.transport.releaseRead()
        await refresh.value
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

/// The native read-only rows (the older window's view) and the one status text they print.
@MainActor private struct StatusProbe {
    let model: TilveroModel
    let compact: Bool
    var rows: NativeChargeReadOnlyRows { NativeChargeReadOnlyRows(model: model, compact: compact) }
    var text: String? { NativeChargeStatusText.text(model.nativeCharge.presentation(), model: model, compact: compact) }
}

@MainActor private struct StatusFixture {
    let suite = TestDefaults.name("ChargeStatusFixture")
    let preferences: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeStatusFixture-\(UUID())")
    let transport = PopoverReadTransport()
    let native: NativeChargeService
    let model: TilveroModel

    init(journal: NativeChargeJournal? = nil, operationTimeout: Duration = .seconds(15)) throws {
        preferences = TestDefaults.defaults(suite)
        preferences.set(false, forKey: "historyEnabled")
        let url = root.appendingPathComponent("native.json")
        if let journal {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: url)
        }
        native = NativeChargeService(client: transport, journalURL: url, environment: "popover-fixture",
                                     operationTimeout: operationTimeout)
        model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                            snapshotProvider: { .unavailable(reason: "Charge status fixture — no hardware read") }, nativeCharge: native)
    }
    func cleanUp() {
        model.stop()
        TestDefaults.remove(suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor PopoverReadTransport: NativeChargeTransport {
    private var delay = Duration.zero
    private var holdsNextRead = false
    private var failsRead = false
    private var incompleteReads = false
    private var suspendedRead: CheckedContinuation<Void, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    private(set) var writes = 0
    func setDelay(_ value: Duration) { delay = value }
    func useIncompleteReads() { incompleteReads = true }
    func holdNextRead() { holdsNextRead = true }
    func waitUntilSuspended() async {
        if suspendedRead != nil { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }
    func releaseRead(failing: Bool = false) {
        failsRead = failing
        suspendedRead?.resume(); suspendedRead = nil
    }
    func read() async throws -> NativeChargeSnapshot {
        readCount += 1
        if holdsNextRead {
            holdsNextRead = false
            await withCheckedContinuation { continuation in
                suspendedRead = continuation
                suspensionWaiter?.resume(); suspensionWaiter = nil
            }
        }
        if failsRead { failsRead = false; throw NativeChargeServiceError.readbackMismatch }
        if delay > .zero { try await Task.sleep(for: delay) }
        if incompleteReads {
            throw NativeChargeReadFailure(supportedTargets: [80, 85, 90, 95, 100],
                currentTarget: 100, rawManualState: 3, diagnosticStoredTarget: 90)!
        }
        return .init(configuration: .init(enabled: true, target: 90, optimizedCharging: true),
                     supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 90)
    }
    func setLimit(_ target: Int) async throws { writes += 1; throw NativeChargeServiceError.unavailable }
}
