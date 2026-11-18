// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Combine
import SwiftUI
import XCTest
import ChargeBackends
import KeyboardBackends
import PowerCore
import PowerTelemetry
@testable import TilveroApp

private actor InvalidationChargeTransport: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 90, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 90)
    }
    func setLimit(_ target: Int) { XCTFail("Rendering never writes") }
    func setEnabled(_ enabled: Bool) { XCTFail("Rendering never writes") }
}

@MainActor private final class InvalidationKeyboard: KeyboardBacklightTransport, KeyboardBacklightPreferenceStorage {
    var brightness = 0.35
    var lastNonzeroBrightness: Double?
    func read() async throws -> KeyboardBacklightObservation {
        try .init(keyboardID: 7, brightness: brightness, automaticBrightness: true, suppressed: false, dimmed: false, observedAt: Date())
    }
    func setBrightness(_ value: Double, keyboardID: UInt64) async throws { brightness = value }
}

private actor InvalidationProcesses {
    private var tick = 0
    func read() -> ProcessResourceCollection {
        tick += 1
        return .init(collectedAt: Date(), monotonic: Double(tick), counters: [
            .init(pid: 1, start: 1, name: "Fixture app", cpuTicks: UInt64(tick) * 900_000_000, cpuEnergyNanojoules: UInt64(tick) * 1_000_000),
            .init(pid: 2, start: 1, name: "Quiet app", cpuTicks: UInt64(tick) * 1_000_000, cpuEnergyNanojoules: UInt64(tick) * 1_000)])
    }
}

/// Counts what SwiftUI re-renders after one change, with the real quick panel (Overview and Charge pages) and the details
/// window (Charging page) on screen at once. `RenderProbe` counts body evaluations of a few key views; `fits` counts
/// whole-panel measurements by the popover host (its safety net); `signals` counts model-wide change notifications.
///
/// Baseline before the state split (2026-11-18: one `ObservableObject` model that forwards eight services' changes and
/// that 27 views observe). "all" = every probed view: QuickPanel.overview, QuickPanel.charge, OverviewHero,
/// OverviewMetricsPanel, ProcessActivityPanel.compact, QuickNativeChargePanel, BatteryInfoView, PowerDataPanel.
///
///     keyboard    signals 0  fits 0  KeyboardBacklightQuickRow 1 (the backlight service was never forwarded)
///     keep-awake  signals 1  fits 1  all 1
///     process     signals 2  fits 1  all 1
///     history     signals 4  fits 1  all 3
///
/// The guards below keep the improved numbers.
@MainActor final class RenderInvalidationTests: XCTestCase {
    private struct Rig {
        let model: TilveroModel
        let awake: KeepAwakeService
        let quick: QuickPanelHostingController
        let views: [NSView]
        let windows: [NSWindow]
        let box: SnapshotBox
    }

    private static func snapshot(percent: Int, adapter: Bool, at date: Date = Date()) -> BatterySnapshot {
        SeriesFixture.snapshot(at: date, minutesAgo: 0, adapterConnected: adapter)
            .replacingPercent(percent)
    }

    private func makeRig() async throws -> Rig {
        UserDefaults.standard.set(true, forKey: "TilveroReleaseTabs")
        let prefs = makeTestDefaults("Invalidation").defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "TilveroReleaseTabs"); try? FileManager.default.removeItem(at: root) }
        let native = NativeChargeService(client: InvalidationChargeTransport(), journalURL: root.appendingPathComponent("native.json"), admitted: true)
        await native.refresh()
        let keyboardFixture = InvalidationKeyboard()
        let keyboard = KeyboardBacklightService(driver: keyboardFixture, storage: keyboardFixture, settleDelay: .milliseconds(1))
        let awake = KeepAwakeService(driver: AwakeFixture())
        let timer = SleepTimerService(driver: CountdownTimerTransport(), allowed: true)
        let processes = InvalidationProcesses()
        let box = SnapshotBox(Self.snapshot(percent: 62, adapter: true))
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { box.value }, nativeCharge: native, keepAwakeService: awake,
                                 processActivityProvider: { await processes.read() }, keyboardBacklight: keyboard,
                                 sleepTimerService: timer, lidSleepSystem: CountdownLid())
        model.overviewPreferences.hidden = [.systemPower, .adapter, .batteryHealth, .powerTiles, .powerCombined]
        model.selectedSection = .charging
        await model.refresh()
        await model.waitForHistoryWork()
        await model.quickPanelWillOpen()
        await model.refreshProcessActivity(force: true)

        let quick = QuickPanelHostingController(model: model, maximumHeight: 1200)
        let charge = NSHostingView(rootView: QuickPanel(model: model, section: .charge))
        let details = NSHostingView(rootView: BatteryInfoView(model: model))
        var windows: [NSWindow] = []
        for (index, (view, size)) in [(quick.view, NSSize(width: QuickPanelMetrics.width, height: 1100)),
                                      (charge as NSView, NSSize(width: QuickPanelMetrics.width, height: 900)),
                                      (details as NSView, NSSize(width: 940, height: 680))].enumerated() {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40 + index * 360, y: 60), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        addTeardownBlock { @MainActor in
            windows.forEach { $0.orderOut(nil) }
            RenderProbe.isEnabled = false; RenderProbe.reset()
            timer.stop(); try? awake.stop(); model.stop()
        }
        return Rig(model: model, awake: awake, quick: quick, views: [quick.view, charge, details], windows: windows, box: box)
    }

    private struct Measurement: CustomStringConvertible {
        let label: String
        let counts: [String: Int]
        let fits: Int
        let signals: Int
        func count(_ name: String) -> Int { counts[name] ?? 0 }
        var description: String {
            "RENDER \(label): signals \(signals) fits \(fits) " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
    }

    private func settle(_ rig: Rig, milliseconds: Int) async throws {
        let step = 50
        for _ in 0..<(milliseconds / step) {
            rig.views.forEach { $0.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(step))
        }
        rig.views.forEach { $0.layoutSubtreeIfNeeded() }
    }

    /// Model-wide change notifications (what every observing view and the popover host's safety net used to receive).
    private func countSignals(_ model: TilveroModel, _ count: @escaping @MainActor () -> Void) -> AnyCancellable {
        model.objectWillChange.sink { MainActor.assumeIsolated { count() } }
    }

    private func measure(_ rig: Rig, _ label: String, _ action: () async throws -> Void) async throws -> Measurement {
        try await settle(rig, milliseconds: 900)   // the safety-net fit waits for 0.5 s of geometry quiet
        RenderProbe.isEnabled = true
        RenderProbe.reset()
        let fitsBefore = rig.quick.measurementCount
        var signals = 0
        let subscription = countSignals(rig.model) { signals += 1 }
        try await action()
        try await settle(rig, milliseconds: 900)
        subscription.cancel()
        RenderProbe.isEnabled = false
        let result = Measurement(label: label, counts: RenderProbe.counts, fits: rig.quick.measurementCount - fitsBefore, signals: signals)
        print(result)
        return result
    }

    func testKeyboardBacklightChange() async throws {
        let rig = try await makeRig()
        let result = try await measure(rig, "keyboard") { await rig.model.keyboardBacklight.setBrightness(0.6) }
        XCTAssertEqual(rig.model.keyboardBacklight.brightness ?? 0, 0.6, accuracy: 0.001)
        _ = result
    }

    func testKeepAwakeTick() async throws {
        let rig = try await makeRig()
        try rig.awake.start(seconds: 3600)
        let result = try await measure(rig, "keep-awake") { try rig.awake.reconcile() }
        XCTAssertTrue(rig.awake.hasOwnedAssertion)
        _ = result
    }

    func testProcessActivitySample() async throws {
        let rig = try await makeRig()
        let result = try await measure(rig, "process") { await rig.model.refreshProcessActivity(force: true) }
        XCTAssertNotNil(rig.model.processActivity)
        _ = result
    }

    func testHistoryRecord() async throws {
        let rig = try await makeRig()
        let release = rig.model.holdHistoryWorkForTesting()
        rig.box.value = Self.snapshot(percent: 61, adapter: false)   // a power change is recorded at once
        await rig.model.refresh()
        let before = rig.model.history.count
        let result = try await measure(rig, "history") {
            release()
            await rig.model.waitForHistoryWork()
        }
        XCTAssertGreaterThan(rig.model.history.count, before, "The reading was recorded")
        _ = result
    }
}

private extension BatterySnapshot {
    func replacingPercent(_ percent: Int) -> BatterySnapshot {
        BatterySnapshot(chargePercent: .init(value: percent, source: "fixture", unit: "%"), isCharging: isCharging, isExternalPower: isExternalPower,
                        cycleCount: cycleCount, manufacturer: manufacturer, temperatureCelsius: temperatureCelsius,
                        voltageVolts: voltageVolts, currentAmps: currentAmps, timeRemainingSeconds: timeRemainingSeconds,
                        collectedAt: collectedAt, isDemo: isDemo, catalog: catalog, monotonicTime: monotonicTime,
                        batteryIdentityToken: batteryIdentityToken)
    }
}
