// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import SwiftUI
import AppKit
import PowerCore
@testable import TilveroApp

private final class FitLid: LidSleepSystem, @unchecked Sendable {
    var ruleFilePresent: Bool { true }
    var state = false
    func readSleepDisabled() async -> Bool? { state }
    func passwordlessPathWorks() async -> Bool { true }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool { state = disabled; return true }
    func installRule() async -> Bool { true }
    func removeRule() async -> Bool { true }
    func restoreWithAuthorization() async -> Bool { true }
    func lidClosedWouldSleep() -> Bool { false }
    func requestSleep() -> Bool { true }
}
@MainActor private final class FitTimer: SleepTimerTransport {
    var hasIdleHold = false
    func acquireIdleHold(seconds: Int) throws { hasIdleHold = true }
    func extendIdleHold() throws {}
    func replaceIdleHold(seconds: Int) throws { hasIdleHold = true }
    func releaseIdleHold() throws { hasIdleHold = false }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() throws {}
}


/// The running sleep-timer header (title, info, +5/+15, end clock, switch) is the crowdedest row of the quick menu: in
/// both languages its switch must stay inside the padded content width (340 pt panel, 14 pt padding).
@MainActor final class SleepTimerHeaderFitTests: XCTestCase {
    private func switches(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is NSSwitch ? [$0] : []) + switches(in: $0) }
    }
    func testRunningHeaderKeepsItsSwitchInsideTheRowInBothLanguages() async throws {
        UserDefaults.standard.set(true, forKey: "TilveroReleaseTabs"); defer { UserDefaults.standard.removeObject(forKey: "TilveroReleaseTabs") }
        for language in ["en", "ru"] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            let service = SleepTimerService(driver: FitTimer(), allowed: true, sleeper: { _ in try await Task.sleep(for: .seconds(86_400)) })
            let suite = "Fit\(UUID())", prefs = UserDefaults(suiteName: suite)!
            defer { prefs.removePersistentDomain(forName: suite) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                     sleepTimerService: service, lidSleepSystem: FitLid())
            defer { model.stop() }
            try service.selectDuration(minutes: 30)
            let host = NSHostingView(rootView: QuickPanel(model: model, section: .awake))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: QuickPanelMetrics.width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let found = switches(in: host)
            XCTAssertFalse(found.isEmpty)
            let limit = QuickPanelMetrics.width - QuickPanelMetrics.padding
            for control in found {
                let frame = control.convert(control.bounds, to: host)
                XCTAssertLessThanOrEqual(frame.maxX, limit + 0.5, "\(language): a switch pokes out of the content width (maxX \(frame.maxX) > \(limit))")
            }
        }
    }
}
