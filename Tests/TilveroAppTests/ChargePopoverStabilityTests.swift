import AppKit
import SwiftUI
import XCTest
import ChargeBackends
@testable import TilveroApp

@MainActor final class ChargePopoverStabilityTests: XCTestCase {
    func testChargeReadDoesNotRepeatedlyResizeOrRestartFromLayout() async throws {
        let suite = "ChargeStability-\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeStability-\(UUID())")
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(false, forKey: "historyEnabled")
        let transport = PopoverReadTransport()
        let native = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("native.json"), admitted: true)
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

    func testCompactRefreshKeepsStableProgressAndFailedPolicyVisible() async throws {
        let fixture = try StatusFixture()
        defer { fixture.cleanUp() }
        await fixture.native.refresh()
        let panel = NativeChargeStatusPanel(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.frame(width: 320))
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
        XCTAssertNil(panel.statusText(fixture.native.presentation()), "Known-setting reads use the in-place progress indicator")

        await fixture.transport.releaseRead(failing: true)
        await refresh.value
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.native.presentation().attention, .policyUnconfirmed)
        XCTAssertEqual(panel.statusText(fixture.native.presentation()), "Active charge policy is unconfirmed",
                      "Read failure must still expose policy uncertainty")
        XCTAssertGreaterThan(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height,
                             "A real policy warning must still grow the compact panel")
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

        let panel = NativeChargeStatusPanel(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.frame(width: 320))
        let window = NSWindow(contentViewController: host)
        let proposal = NSSize(width: 320, height: 900)
        let initialSize = host.sizeThatFits(in: proposal)
        window.setContentSize(initialSize)
        host.view.layoutSubtreeIfNeeded()
        let warning = try XCTUnwrap(panel.statusText(fixture.native.presentation()))

        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.model.refreshNativeCharge() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.native.presentation().pendingPurpose, .read)
        XCTAssertEqual(panel.statusText(fixture.native.presentation()), warning)
        XCTAssertEqual(host.sizeThatFits(in: proposal), initialSize)
        XCTAssertFalse(fixture.model.canApply)
        await fixture.transport.releaseRead()
        await refresh.value

        XCTAssertEqual(panel.statusText(fixture.native.presentation()), warning)
        XCTAssertEqual(fixture.model.draftText, "100")
        let writes = await fixture.transport.writes
        XCTAssertEqual(writes, 0)
    }

    func testPendingTargetAndSavedRecoveryStayVisibleDuringRead() async throws {
        let normal = try StatusFixture()
        defer { normal.cleanUp() }
        await normal.native.refresh()
        let normalHost = NSHostingController(rootView: NativeChargeStatusPanel(model: normal.model, compact: true).frame(width: 320))
        let normalHeight = normalHost.sizeThatFits(in: NSSize(width: 320, height: 900)).height
        let pending = try StatusFixture()
        defer { pending.cleanUp() }
        await pending.native.refresh()
        try await pending.native.apply(80, batteryPercent: 85, batteryFresh: true)
        XCTAssertEqual(pending.native.pendingTarget, 80)
        try await assertReadKeepsWarningVisible(pending, normalHeight: normalHeight)

        let configuration = NativeChargeConfiguration(enabled: true, target: 90, optimizedCharging: true)
        let recovery = try StatusFixture(journal: .init(sessionID: UUID(), environment: "popover-fixture",
            baseline: .init(enabled: true, target: 80, optimizedCharging: true), lastVerified: configuration,
            plannedTarget: nil, phase: .restorationPending, hasWritten: true))
        defer { recovery.cleanUp() }
        await recovery.native.refresh()
        XCTAssertTrue(recovery.native.recoveryRequired)
        try await assertReadKeepsWarningVisible(recovery, normalHeight: normalHeight)
        XCTAssertEqual(recovery.native.presentation().restorationTarget, 80)
        let pendingWrites = await pending.transport.writes, recoveryWrites = await recovery.transport.writes
        XCTAssertEqual(pendingWrites + recoveryWrites, 0)
    }

    func testFirstUnknownReadAndFullDiagnosticPanelKeepDetailedProgress() async throws {
        for compact in [false, true] {
            let fixture = try StatusFixture()
            defer { fixture.cleanUp() }
            if !compact { await fixture.native.refresh() }
            let panel = NativeChargeStatusPanel(model: fixture.model, compact: compact)
            let host = NSHostingController(rootView: panel.frame(width: 320))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(host.sizeThatFits(in: NSSize(width: 320, height: 900)))
            await fixture.transport.holdNextRead()
            let refresh = Task { await fixture.native.refresh() }
            await fixture.transport.waitUntilSuspended()
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(panel.statusText(fixture.native.presentation()), "Reading the native charge policy…")
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
        let panel = NativeChargeStatusPanel(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.frame(width: 320))
        let normalHeight = host.sizeThatFits(in: NSSize(width: 320, height: 900)).height
        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        await refresh.value
        XCTAssertFalse(fixture.native.isBusy, "The deadline returns control without claiming transport cancellation")
        XCTAssertEqual(fixture.native.presentation().pendingPurpose, .read)
        let warning = try XCTUnwrap(fixture.native.message)
        XCTAssertEqual(panel.statusText(fixture.native.presentation()), warning,
                       "An overdue read needs its warning, rather than only the compact progress indicator")
        XCTAssertGreaterThan(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, normalHeight)
        await fixture.transport.releaseRead()
        let writes = await fixture.transport.writes
        XCTAssertEqual(writes, 0)
    }

    private func assertReadKeepsWarningVisible(_ fixture: StatusFixture, normalHeight: CGFloat) async throws {
        let panel = NativeChargeStatusPanel(model: fixture.model, compact: true)
        let host = NSHostingController(rootView: panel.frame(width: 320))
        let window = NSWindow(contentViewController: host)
        let initialSize = host.sizeThatFits(in: NSSize(width: 320, height: 900))
        window.setContentSize(initialSize)
        let originalStatus = panel.statusText(fixture.native.presentation())
        XCTAssertGreaterThan(initialSize.height, normalHeight, "Pending or saved-recovery warnings must occupy visible space")
        await fixture.transport.holdNextRead()
        let refresh = Task { await fixture.native.refresh() }
        await fixture.transport.waitUntilSuspended()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 320, height: 900)).height, initialSize.height,
                       "Read progress must preserve pending-target and recovery warning rows")
        XCTAssertEqual(panel.statusText(fixture.native.presentation()), originalStatus)
        await fixture.transport.releaseRead()
        await refresh.value
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor private struct StatusFixture {
    let suite = "ChargeStatusFixture-\(UUID())"
    let preferences: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChargeStatusFixture-\(UUID())")
    let transport = PopoverReadTransport()
    let native: NativeChargeService
    let model: TilveroModel

    init(journal: NativeChargeJournal? = nil, operationTimeout: Duration = .seconds(15)) throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(false, forKey: "historyEnabled")
        let url = root.appendingPathComponent("native.json")
        if let journal {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(journal).write(to: url)
        }
        native = NativeChargeService(client: transport, journalURL: url, admitted: true, environment: "popover-fixture",
                                     operationTimeout: operationTimeout)
        model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                            snapshotProvider: { .unavailable(reason: "Charge status fixture — no hardware read") }, nativeCharge: native)
    }
    func cleanUp() {
        model.stop()
        preferences.removePersistentDomain(forName: suite)
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
    func setEnabled(_ enabled: Bool) async throws { writes += 1; throw NativeChargeServiceError.unavailable }
}
