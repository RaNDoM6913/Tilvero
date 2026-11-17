// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import SwiftUI
import AppKit
import QuartzCore
import PowerCore
@testable import TilveroApp

/// The header switch of the Keep Awake and Sleep timer pages must stay the same `NSSwitch` while a session starts and
/// ends. The header sits in a `ViewThatFits` (roomy variant with the end time, compact fallback); a switch inside the
/// variants was rebuilt on every swap, which cut its on/off animation and made the thumb jump. These tests host the real
/// quick panel in a window and watch the AppKit switch itself.
@MainActor final class SleepSwitchIdentityTests: XCTestCase {
    private struct Rig {
        let model: TilveroModel, timer: SleepTimerService, awake: KeepAwakeService
        let host: NSHostingView<QuickPanel>, window: NSWindow
    }
    private func makeRig(awakePage: Bool) async -> Rig {
        let timer = SleepTimerService(driver: CountdownTimerTransport(), allowed: true)
        let awake = KeepAwakeService(driver: AwakeFixture())
        let suite = "TilveroTests.SwitchId.\(UUID().uuidString)", prefs = UserDefaults(suiteName: suite)!
        addTeardownBlock { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 keepAwakeService: awake, sleepTimerService: timer, lidSleepSystem: CountdownLid())
        // The Sleep tab opens on Keep Awake only while a session runs.
        if awakePage { try? awake.start(seconds: 1800) }
        let host = NSHostingView(rootView: QuickPanel(model: model, section: .awake))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: QuickPanelMetrics.width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        _ = NSApplication.shared
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil); timer.stop(); try? awake.stop(); model.stop() }
        try? await Task.sleep(for: .milliseconds(700))
        return Rig(model: model, timer: timer, awake: awake, host: host, window: window)
    }
    /// Runs `body` once per interface language: the header's width, and so the layout it picks, depends on the language.
    private func inEachLanguage(_ body: (String) async throws -> Void) async rethrows {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        for language in ["en", "ru"] {
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            try await body(language)
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// Whether the view, or any ancestor, is hidden or fully transparent (the invisible `SwitchSlot` twins, should one ever be an AppKit view).
    private func isVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alphaValue == 0 { return false }
            current = candidate.superview
        }
        return true
    }
    /// The master switch is the topmost visible switch of the page.
    private func masterSwitch(_ rig: Rig) -> NSSwitch? {
        descendants(rig.host).compactMap { $0 as? NSSwitch }.filter(isVisible)
            .max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }
    private func signature(_ layer: CALayer) -> String {
        let p = layer.presentation() ?? layer
        return String(format: "%.1f,%.1f,%.1f,%.1f,%.2f", p.position.x, p.position.y, p.bounds.width, p.bounds.height, p.opacity)
            + (layer.sublayers ?? []).map(signature).joined(separator: "|")
    }
    /// How many distinct renderings the switch went through, and whether its view was ever replaced.
    private func watch(_ rig: Rig, seconds: Double, action: () -> Void) async -> (frames: Int, replaced: Bool) {
        let first = masterSwitch(rig)
        var signatures = Set<String>(), replaced = false
        action()
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(8))
            guard let now = masterSwitch(rig) else { continue }
            if now !== first { replaced = true }
            if let layer = now.layer { signatures.insert(signature(layer)) }
        }
        return (signatures.count, replaced)
    }

    /// With Reduce Motion the switch is allowed to jump, so the frame-count checks apply only without it; the identity
    /// checks (the switch is never rebuilt) hold either way.
    private var switchMayAnimate: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func testKeepAwakeSwitchAnimatesAndKeepsItsViewWhenASessionStartsAndEnds() async throws {
        try await inEachLanguage { language in
            let rig = await makeRig(awakePage: true)
            defer { rig.window.orderOut(nil); try? rig.awake.stop() }
            try rig.awake.stop()
            try await Task.sleep(for: .milliseconds(500))
            let programmatic = await watch(rig, seconds: 0.7) { try? rig.awake.start(seconds: 1800) }   // timed: the end time appears
            XCTAssertFalse(programmatic.replaced, "starting a timed session rebuilt the switch (\(language))")
            try await Task.sleep(for: .milliseconds(500))
            let ending = await watch(rig, seconds: 0.7) { try? rig.awake.stop() }
            XCTAssertFalse(ending.replaced, "ending the session rebuilt the switch (\(language))")
            try await Task.sleep(for: .milliseconds(500))
            let clickOn = await watch(rig, seconds: 0.7) { self.masterSwitch(rig)?.performClick(nil) }
            XCTAssertTrue(rig.awake.hasOwnedAssertion, "the click must start Keep Awake")
            XCTAssertFalse(clickOn.replaced, "the clicked switch was replaced by a new one")
            if switchMayAnimate { XCTAssertGreaterThanOrEqual(clickOn.frames, 5, "the switch must animate on, not jump (\(clickOn.frames) renderings, \(language))") }
            try await Task.sleep(for: .milliseconds(500))
            let clickOff = await watch(rig, seconds: 0.7) { self.masterSwitch(rig)?.performClick(nil) }
            XCTAssertFalse(rig.awake.hasOwnedAssertion)
            XCTAssertFalse(clickOff.replaced)
            if switchMayAnimate { XCTAssertGreaterThanOrEqual(clickOff.frames, 5, "the switch must animate off, not jump (\(clickOff.frames) renderings, \(language))") }
        }
    }

    func testSleepTimerSwitchAnimatesAndKeepsItsViewWhenTheTimerStartsAndEnds() async throws {
        try await inEachLanguage { language in
            let rig = await makeRig(awakePage: false)
            defer { rig.window.orderOut(nil); rig.timer.stop() }
            // Whether the roomy header variant fits depends on the width of the end clock, so end the timer at the widest
            // time of day ("10:38 PM"); at a narrow one (or in Russian, 24 h) the swap this test guards against would not happen.
            let widest = try XCTUnwrap(Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 22, minute: 38), matchingPolicy: .nextTime))
            let minutes = min(1440, max(1, Int((widest.timeIntervalSinceNow / 60).rounded(.up))))
            let started = await watch(rig, seconds: 0.7) { try? rig.timer.selectDuration(minutes: minutes) }
            XCTAssertTrue(rig.timer.isActive)
            XCTAssertFalse(started.replaced, "starting the timer rebuilt the switch (\(language))")
            if switchMayAnimate { XCTAssertGreaterThanOrEqual(started.frames, 5, "the switch must animate on (\(started.frames) renderings, \(language))") }
            try await Task.sleep(for: .milliseconds(500))
            let clickOff = await watch(rig, seconds: 0.7) { self.masterSwitch(rig)?.performClick(nil) }
            XCTAssertFalse(rig.timer.isActive)
            XCTAssertFalse(clickOff.replaced, "ending the timer rebuilt the switch (\(language))")
            if switchMayAnimate { XCTAssertGreaterThanOrEqual(clickOff.frames, 5, "the switch must animate off (\(clickOff.frames) renderings, \(language))") }
        }
    }
}
