// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import SwiftUI
import AppKit
import PowerCore
@testable import TilveroApp

final class CountdownLid: LidSleepSystem, @unchecked Sendable {
    var ruleFilePresent: Bool { true }
    func readSleepDisabled() async -> Bool? { false }
    func passwordlessPathWorks() async -> Bool { true }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool { true }
    func installRule() async -> Bool { true }
    func removeRule() async -> Bool { true }
    func restoreWithAuthorization() async -> Bool { true }
    func lidClosedWouldSleep() -> Bool { false }
    func requestSleep() -> Bool { true }
}
@MainActor final class CountdownTimerTransport: SleepTimerTransport {
    var hasIdleHold = false
    func acquireIdleHold(seconds: Int) throws { hasIdleHold = true }
    func extendIdleHold() throws {}
    func replaceIdleHold(seconds: Int) throws { hasIdleHold = true }
    func releaseIdleHold() throws { hasIdleHold = false }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() throws {}
}

/// The running pill's countdown must advance once per second for a preset exactly as for a custom time. The pill row is a
/// `ForEach` inside a one-second `TimelineView`; a `ForEach` over constants was not re-run by the tick, so the preset pills
/// froze (or moved only when something else invalidated them) while the custom pill ticked. These tests host the real quick
/// panel in a window and watch its pixels, because the defect was in what SwiftUI re-rendered, not in the model.
@MainActor final class SleepPillCountdownTests: XCTestCase {
    private struct Rig {
        let model: TilveroModel, service: SleepTimerService, keepAwake: KeepAwakeService
        let host: NSHostingView<QuickPanel>, window: NSWindow
    }
    private func makeRig() -> Rig {
        UserDefaults.standard.set(true, forKey: "TilveroReleaseTabs")
        let service = SleepTimerService(driver: CountdownTimerTransport(), allowed: true)
        let awake = KeepAwakeService(driver: AwakeFixture())
        let suite = TestDefaults.name("Cd"), prefs = TestDefaults.defaults(suite)
        addTeardownBlock { TestDefaults.remove(suite); UserDefaults.standard.removeObject(forKey: "TilveroReleaseTabs") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 keepAwakeService: awake, sleepTimerService: service, lidSleepSystem: CountdownLid())
        let host = NSHostingView(rootView: QuickPanel(model: model, section: .awake))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: QuickPanelMetrics.width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil); service.stop(); try? awake.stop(); model.stop() }
        return Rig(model: model, service: service, keepAwake: awake, host: host, window: window)
    }
    private func snapshot(_ host: NSView) -> Data? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .tiff, properties: [:])
    }
    /// Seconds (from now) at which the rendered panel changed during `window` seconds.
    private func changes(_ host: NSView, during window: Double) async throws -> [Double] {
        var last = snapshot(host), result: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < window {
            try await Task.sleep(for: .milliseconds(40))
            let data = snapshot(host)
            if data != last { result.append(Date().timeIntervalSince(start)) }
            last = data
        }
        return result
    }
    private func assertOncePerSecond(_ times: [Double], _ label: String, window: Double = 4.2, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(times.count, Int(window) - 1, "\(label): the countdown redrew only at \(times)", file: file, line: line)
        var previous = 0.0
        for time in times {
            XCTAssertLessThan(time - previous, 1.6, "\(label): a gap longer than 1.6 s between redraws \(times)", file: file, line: line)
            previous = time
        }
        XCTAssertLessThan(window - previous, 1.6, "\(label): the countdown stopped redrawing \(times)", file: file, line: line)
    }

    func testSleepTimerPresetAndCustomCountdownsTickEverySecond() async throws {
        for minutes in [30, 15, 60, 20] {   // three presets and a custom time
            let rig = makeRig()
            try rig.service.selectDuration(minutes: minutes)
            try await Task.sleep(for: .milliseconds(200))
            assertOncePerSecond(try await changes(rig.host, during: 4.2), "timer \(minutes) min")
            rig.service.stop(); rig.window.orderOut(nil)
        }
    }
    func testKeepAwakePresetCountdownTicksEverySecond() async throws {
        let rig = makeRig()
        rig.model.selectedSleepPage = .awake
        try rig.keepAwake.start(seconds: 1800)
        try await Task.sleep(for: .milliseconds(300))
        assertOncePerSecond(try await changes(rig.host, during: 4.2), "keep awake 30 min")
    }
    func testSwitchingBetweenPresetAndCustomRepaintsAtOnceAndKeepsTicking() async throws {
        let rig = makeRig()
        try rig.service.selectDuration(minutes: 30)
        try await Task.sleep(for: .milliseconds(250))
        let preset = snapshot(rig.host)
        try rig.service.selectDuration(minutes: 20)    // custom
        try await Task.sleep(for: .milliseconds(250))
        let custom = snapshot(rig.host)
        XCTAssertNotEqual(preset, custom, "the selection moved from the preset pill to the custom one but the panel did not repaint")
        assertOncePerSecond(try await changes(rig.host, during: 3.2), "after switching to custom", window: 3.2)
        try rig.service.selectDuration(minutes: 60)    // back to a preset
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotEqual(custom, snapshot(rig.host))
        assertOncePerSecond(try await changes(rig.host, during: 3.2), "after switching back to a preset", window: 3.2)
    }
    func testPillItemsCarryTheCountdownOnlyOnTheAppliedPreset() {
        XCTAssertEqual(QuickPresets.defaults.sleepTimer, [15, 30, 60])
        let items = SleepPillItem.items(of: QuickPresets.defaults.sleepTimer, applied: .preset(30), countdown: "29:59")
        XCTAssertEqual(items.map(\.countdown), [nil, "29:59", nil])
        XCTAssertNotEqual(items, SleepPillItem.items(of: QuickPresets.defaults.sleepTimer, applied: .preset(30), countdown: "29:58"))
        XCTAssertEqual(SleepPillItem.items(of: QuickPresets.defaults.sleepTimer, applied: .custom, countdown: "1:00").map(\.countdown), [nil, nil, nil])
    }
}
