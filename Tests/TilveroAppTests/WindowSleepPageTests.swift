// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
import PowerTelemetry
import PowerPersistence
import ComfortBackends
@testable import TilveroApp

/// Sleep timer transport that records every write. Rendering must leave the counts unchanged; with `failsWrites` any
/// write is a test failure.
@MainActor private final class RecordingTimerTransport: SleepTimerTransport {
    var failsWrites: Bool
    var writes = 0
    var hasIdleHold = false
    init(failsWrites: Bool) { self.failsWrites = failsWrites }
    private func write() throws {
        writes += 1
        if failsWrites { XCTFail("Rendering never writes the sleep timer"); throw KeepAwakeError.unconfirmed }
    }
    func acquireIdleHold(seconds: Int) throws { try write(); hasIdleHold = true }
    func extendIdleHold() throws { try write() }
    func replaceIdleHold(seconds: Int) throws { try write(); hasIdleHold = true }
    func releaseIdleHold() throws { try write(); hasIdleHold = false }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() throws { try write() }
}

/// Lid system that fails on every write while `failsWrites` (rendering); reading the system state is allowed (the row
/// reads it once on appear). A write the test itself causes (a timer it starts) is only counted.
private final class WriteFailingLid: LidSleepSystem, @unchecked Sendable {
    var failsWrites = true
    var writes = 0
    private func write() -> Bool {
        writes += 1
        if failsWrites { XCTFail("Rendering never writes lid sleep"); return false }
        return true
    }
    var ruleFilePresent: Bool { true }
    func readSleepDisabled() async -> Bool? { false }
    func passwordlessPathWorks() async -> Bool { write() }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool { write() }
    func installRule() async -> Bool { write() }
    func removeRule() async -> Bool { write() }
    func restoreWithAuthorization() async -> Bool { write() }
    func lidClosedWouldSleep() -> Bool { false }
    func requestSleep() -> Bool { write() }
}

/// Screen and sound under the lid switch: reads nothing real, every write fails the test.
private struct WriteFailingDisplay: DisplayBrightnessTransport {
    func read() async throws -> DisplayBrightnessReading { throw ComfortBackendError.unavailable }
    func set(_ value: Double, displayID: UInt32) async throws { XCTFail("Rendering never sets brightness"); throw ComfortBackendError.unavailable }
}
private struct WriteFailingAudio: OutputVolumeTransport {
    private final class Sub: ComfortSubscription, @unchecked Sendable { func cancel() {} }
    func defaultOutput() async throws -> OutputVolumeReading { throw ComfortBackendError.unavailable }
    func volume(deviceUID: String) async throws -> Double? { throw ComfortBackendError.deviceMissing }
    func setVolume(_ value: Double, deviceUID: String) async throws { XCTFail("Rendering never sets volume"); throw ComfortBackendError.unavailable }
    func observeDefaultOutputChanges(_ handler: @escaping @Sendable () -> Void) -> any ComfortSubscription { Sub() }
}
private final class OpenLid: LidComfortClamshell, @unchecked Sendable {
    private final class Sub: ComfortSubscription, @unchecked Sendable { func cancel() {} }
    func sample() -> ClamshellSample { ClamshellSample(lidClosed: false, causesSleep: true) }
    func observe(_ handler: @escaping @Sendable (ClamshellSample) -> Void) -> any ComfortSubscription { Sub() }
}

@MainActor private struct SleepPageRig {
    let model: TilveroModel
    let timer: RecordingTimerTransport
    let awake: AwakeFixture
    let lid: WriteFailingLid
    let cleanup: () -> Void

    /// Three recorded intervals (a night, a nap, one without a wake reading) and two current process assertions.
    static func make(timerFailsWrites: Bool = true, lidOn: Bool = true) async throws -> SleepPageRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowSleep"), defaults = TestDefaults.defaults(suite)
        if lidOn { defaults.set(true, forKey: LidSleepOverrideService.scheduledSleepPreferenceKey) }
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        for record in try records(now: now) { try await store.upsertSleepSession(record) }
        try await store.close()
        let current = WindowFixture.snapshot(at: now, level: 72, minutesAgo: 0, charging: false)
        let activity = SleepAssertionSnapshot(collectedAt: now, aggregateAvailability: .available, processAvailability: .available,
                                              activeTypes: [.systemIdle],
                                              rows: [SleepAssertionRow(id: "1", processID: 101, processName: "Music", type: .systemIdle),
                                                     SleepAssertionRow(id: "2", processID: 102, processName: "Tilvero", type: .systemIdle)])
        let transport = RecordingTimerTransport(failsWrites: timerFailsWrites)
        let timer = SleepTimerService(driver: transport, allowed: true)
        let fixture = AwakeFixture()
        let awake = KeepAwakeService(driver: fixture)
        let lid = WriteFailingLid()
        let comfort = LidComfortService(display: WriteFailingDisplay(), audio: WriteFailingAudio(), clamshell: OpenLid(),
                                        defaults: defaults, allowed: true)
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { current },
                                 sleepActivityProvider: { activity }, keepAwakeService: awake, sleepTimerService: timer,
                                 lidSleepSystem: lid, lidComfortService: comfort, liveSampler: { nil }, newWindow: true)
        await model.refresh()
        await model.waitForHistoryWork()
        return SleepPageRig(model: model, timer: transport, awake: fixture, lid: lid, cleanup: {
            transport.failsWrites = false; lid.failsWrites = false
            timer.stop(); try? awake.stop(); model.stop()
            TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }

    static func records(now: Date) throws -> [SleepSessionRecord] {
        func endpoint(_ date: Date, level: Int, continuous: Double, run: UUID) throws -> SleepBatteryEndpoint {
            try XCTUnwrap(SleepBatteryEndpoint(snapshot: WindowFixture.snapshot(at: date, level: level, minutesAgo: 0, charging: false),
                                               stamp: SleepObservationStamp(wallDate: date, continuousSeconds: continuous, runID: run)))
        }
        func interval(wake: Date, minutes: Double, before: Int, after: Int?) throws -> SleepSessionRecord {
            let run = UUID(), sleep = wake.addingTimeInterval(-minutes * 60)
            let base = 10_000.0
            let start = SleepObservationStamp(wallDate: sleep, continuousSeconds: base, runID: run)
            let end = SleepObservationStamp(wallDate: wake, continuousSeconds: base + minutes * 60, runID: run)
            let first = try endpoint(sleep, level: before, continuous: base, run: run)
            guard let after else {
                return SleepSessionRecord(sleepBoundary: start, wakeBoundary: end, before: first, phase: .incomplete,
                                          issues: [.postReadingMissing], endedAt: end)
            }
            let second = try endpoint(wake.addingTimeInterval(10), level: after, continuous: base + minutes * 60 + 10, run: run)
            return SleepSessionRecord(sleepBoundary: start, wakeBoundary: end, before: first, after: second, phase: .closed, endedAt: second.stamp)
        }
        return [try interval(wake: now.addingTimeInterval(-2 * 3600), minutes: 438, before: 61, after: 58),
                try interval(wake: now.addingTimeInterval(-20 * 3600), minutes: 25, before: 77, after: 77),
                try interval(wake: now.addingTimeInterval(-30 * 3600), minutes: 415, before: 80, after: nil)]
    }
}

@MainActor final class WindowSleepPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        setLanguage("en", model: nil)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    private func setLanguage(_ language: String, model: TilveroModel?) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model?.language = language
    }

    // MARK: Leads

    func testTimerLead() {
        var input = SleepTimerLeadInputs()
        var lead = SleepDrainLead.timer(input)
        XCTAssertEqual(lead.value, L10n.text("Off (short)"))
        XCTAssertEqual(lead.status, L10n.text("Sleep timer"))
        XCTAssertEqual(lead.tone, .secondary)

        input.phase = .armed; input.remainingSeconds = 24 * 60 + 37
        input.endDate = Date(timeIntervalSince1970: 0)
        lead = SleepDrainLead.timer(input)
        XCTAssertEqual(lead.value, "24:37")
        XCTAssertTrue(lead.status.hasPrefix(L10n.text("Sleeps at (time)") + " "))
        XCTAssertEqual(lead.tone, .sleep)

        input.needsHoldRelease = true
        XCTAssertEqual(SleepDrainLead.timer(input).tone, .attention)

        lead = SleepDrainLead.timer(SleepTimerLeadInputs(chargeTarget: 20), language: "ru")
        XCTAssertEqual(lead.value, "20 %")
        XCTAssertEqual(lead.status, L10n.text("Sleep at charge"))

        lead = SleepDrainLead.timer(SleepTimerLeadInputs(available: false))
        XCTAssertEqual(lead.value, "—", "unavailable is «—», never «Off»")
    }

    func testKeepAwakeLead() {
        XCTAssertEqual(SleepDrainLead.awake(KeepAwakeLeadInputs()).value, L10n.text("Off (short)"))
        var input = KeepAwakeLeadInputs(hasOwnedAssertion: true, isActive: true, untilStopped: true)
        XCTAssertEqual(SleepDrainLead.awake(input).value, "∞")
        XCTAssertEqual(SleepDrainLead.awake(input).tone, .awake)
        input.untilStopped = false; input.remainingSeconds = 6120; input.endDate = Date()
        let lead = SleepDrainLead.awake(input)
        XCTAssertEqual(lead.value, "1:42:00")
        XCTAssertTrue(lead.detail.hasPrefix(L10n.text("until (lead)") + " "))
        input.isActive = false
        XCTAssertEqual(SleepDrainLead.awake(input).status, L10n.text("Check session"))
        XCTAssertEqual(SleepDrainLead.awake(KeepAwakeLeadInputs(available: false)).value, "—")
    }

    // MARK: Reports

    func testReportValuesComeOnlyFromTheRecord() throws {
        let records = try SleepPageRig.records(now: Date())
        let night = records[0], nap = records[1], missing = records[2]
        XCTAssertEqual(SleepReportDisplay.change(night, language: "en", locale: Locale(identifier: "en_US")), "−3%")
        XCTAssertEqual(SleepReportDisplay.change(nap, language: "ru", locale: Locale(identifier: "ru_RU")), "0 %", "a valid 0 stays 0")
        XCTAssertNil(SleepReportDisplay.change(missing), "no wake reading: no change")
        XCTAssertEqual(SleepReportDisplay.endpoints(night, language: "ru", locale: Locale(identifier: "ru_RU")), "61 → 58 %")
        XCTAssertNil(SleepReportDisplay.endpoints(missing))
        let rate = try XCTUnwrap(SleepReportDisplay.drainPerHour(night))
        XCTAssertEqual(rate, 3 / (438.0 / 60), accuracy: 0.001)
        XCTAssertNil(SleepReportDisplay.drainPerHour(nap), "under half an hour: no per-hour estimate")
        XCTAssertTrue(SleepReportDisplay.drainDisplay(night).approximate)
        XCTAssertNil(SleepReportDisplay.drainDisplay(nil).number)
        XCTAssertNil(SleepReportDisplay.percentDisplay(nil).number)
    }

    // MARK: Actions

    /// The page hosts the quick menu's panels, so a pill or switch runs the same `SleepPillActions` call; these are the
    /// calls the hosted pills make, with the confirmation another mode requires.
    func testSameActionsAndConfirmationsAsTheQuickMenu() async throws {
        let rig = try await SleepPageRig.make(timerFailsWrites: false)
        defer { rig.cleanup() }
        let model = rig.model
        try SleepPillActions.awake(model, request: .duration(15))
        let awakeID = try XCTUnwrap(model.keepAwake.ownedAssertionID)
        XCTAssertEqual(SleepPillActions.awakeSelection(model), .preset(15))
        XCTAssertThrowsError(try SleepPillActions.timer(model, minutes: 30)) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.endAwake(awakeID)))
        }
        try SleepPillActions.timer(model, minutes: 30, consent: .endAwake(awakeID))
        XCTAssertEqual(SleepPillActions.timerSelection(model), .preset(30))
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        let lead = SleepDrainLead.timer(SleepTimerLeadInputs(phase: model.sleepTimer.phase, remainingSeconds: model.sleepTimer.remainingSeconds,
                                                             endDate: model.sleepTimer.endDate))
        XCTAssertEqual(lead.tone, .sleep)
        let token = try XCTUnwrap(SleepPillActions.controlToken(model, awake: false))
        try SleepPillActions.setTimerEnabled(model, enabled: false, token: token)
        XCTAssertFalse(model.sleepTimer.isActive)
    }

    // MARK: Structure

    func testNoViewThatFitsInThePage() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/TilveroApp/SleepDrainPage.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertFalse(source.contains("ViewThatFits"), "no control inside ViewThatFits")
        XCTAssertFalse(source.contains("AnyView"))
        XCTAssertFalse(source.contains("studioElement"))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func visibleSwitches(_ host: NSView) -> [NSSwitch] {
        descendants(host).compactMap { $0 as? NSSwitch }.filter { view in
            var current: NSView? = view
            while let candidate = current {
                if candidate.isHidden || candidate.alphaValue == 0 { return false }
                current = candidate.superview
            }
            return true
        }.sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
    }

    private func makeWindow(_ model: TilveroModel, dark: Bool = false, height: CGFloat = 720) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let host = NSHostingView(rootView:
            WindowThemeResolver {
                NavigationStack { SleepDrainPage(model: model) }
                    .background { WindowCanvas().ignoresSafeArea() }
                    .tint(WindowTheme.accent)
            }
            .environment(\.locale, L10n.locale)
            .font(.system(size: 13)))
        host.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: 60, y: 60, width: 1000, height: height), display: true)
        return (window, host)
    }

    /// Starting a timer adds the shortcuts and the end time to the header: the master switch stays the same `NSSwitch`.
    func testTimerSwitchKeepsItsIdentityWhenASessionStarts() async throws {
        let rig = try await SleepPageRig.make(timerFailsWrites: false, lidOn: false)
        defer { rig.cleanup() }
        rig.model.navigation.navigate(to: .sleep(.timer))
        let (window, host) = makeWindow(rig.model)
        defer { window.close() }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(800))
        let before = try XCTUnwrap(visibleSwitches(host).first)
        try SleepPillActions.timer(rig.model, minutes: 30)
        try await Task.sleep(for: .milliseconds(800))
        let after = try XCTUnwrap(visibleSwitches(host).first)
        XCTAssertTrue(before === after, "the master switch was rebuilt")
        XCTAssertEqual(after.state, .on)
    }

    // MARK: Render

    /// RU/EN × light/dark for the three tabs and a running timer, in a window configured like the main window. PNGs when
    /// `TILVERO_RENDER_OUT` is set. Rendering never starts a session or writes (write-failing transports).
    func testSleepGallery() async throws {
        let rig = try await SleepPageRig.make(timerFailsWrites: false)
        defer { rig.cleanup() }
        let model = rig.model
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        func capture(_ window: NSWindow, _ name: String) throws {
            guard let output else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name + ".png").path]
            try process.run(); process.waitUntilExit()
        }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let (window, _) = makeWindow(model, dark: dark)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                for page in SleepPage.allCases {
                    model.navigation.navigate(to: .sleep(page))
                    try await Task.sleep(for: .seconds(1.5))
                    XCTAssertEqual(window.title, L10n.text("Sleep & drain"))
                    try capture(window, "sleep-\(page == .timer ? "timer" : page == .awake ? "awake" : "reports")-\(suffix)")
                }
                window.close()
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["SleepDrainPage"] ?? 0, 1)
        XCTAssertEqual(rig.timer.writes, 0, "rendering never starts the timer")
        XCTAssertEqual(rig.awake.createCount + rig.awake.updateCount + rig.awake.releaseCount, 0, "rendering never starts Keep Awake")
        XCTAssertFalse(model.sleepAtCharge.isArmed)
        XCTAssertFalse(model.keepAwakeUntilCharge.isArmed)
        XCTAssertEqual(rig.lid.writes, 0, "rendering never writes lid sleep")

        // Timer running: started by the test through the quick menu's action, then rendered. With the lid switch on, the
        // timer itself asks for the lid override (refused here); that write is the test's, not the page's.
        rig.lid.failsWrites = false
        try SleepPillActions.timer(model, minutes: 30)
        let writes = rig.timer.writes
        model.navigation.navigate(to: .sleep(.timer))
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let (window, _) = makeWindow(model, dark: dark)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .seconds(1.5))
                try capture(window, "sleep-timer-running-\(language)-\(dark ? "dark" : "light")")
                window.close()
            }
        }
        XCTAssertEqual(rig.timer.writes, writes, "rendering a running timer never writes")
    }

    /// Strict variant: every write fails the test while all three tabs render.
    func testRenderingNeverWrites() async throws {
        let rig = try await SleepPageRig.make(timerFailsWrites: true)
        defer { rig.cleanup() }
        let (window, _) = makeWindow(rig.model)
        defer { window.close() }
        window.orderFrontRegardless()
        for page in SleepPage.allCases {
            rig.model.navigation.navigate(to: .sleep(page))
            try await Task.sleep(for: .milliseconds(700))
        }
        XCTAssertEqual(rig.timer.writes, 0)
        XCTAssertEqual(rig.lid.writes, 0)
        XCTAssertEqual(rig.awake.createCount, 0)
        XCTAssertFalse(rig.model.sleepTimer.isActive)
        XCTAssertFalse(rig.model.keepAwake.hasOwnedAssertion)
        XCTAssertNotNil(rig.model.sleepActivity, "Reports read the current blockers (a read, not a write)")
    }
}
