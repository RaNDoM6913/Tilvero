// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp
@MainActor private final class CapsuleSleepDriver: SleepTimerTransport {
    var hasIdleHold = false
    func acquireIdleHold(seconds: Int) throws { hasIdleHold = true }
    func extendIdleHold() throws {}
    func replaceIdleHold(seconds: Int) { hasIdleHold = true }
    func releaseIdleHold() throws { hasIdleHold = false }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() {}
}
@MainActor final class QuickCapsuleRenderTests: XCTestCase {
    func testLook() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, v in v }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let suite = "QL-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), sleepTimerTransport: CapsuleSleepDriver())
        let out = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] ?? NSTemporaryDirectory() + "TilveroCapsuleRender"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        func shot(_ name: String, _ section: QuickPanelSection, awakeTab: Bool = false) async throws {
            let host = NSHostingController(rootView: QuickPanel(model: model, section: section).frame(width: QuickPanelMetrics.width).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark).environment(\.controlActiveState, .key).environment(\.locale, L10n.locale))
            let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))
            let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            if awakeTab {
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                let c = try XCTUnwrap(all(host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Таймер сна" })
                c.selectedSegment = 1; _ = c.sendAction(c.action, to: c.target)
                try await Task.sleep(for: .milliseconds(250))
            }
            host.view.layoutSubtreeIfNeeded()
            let size2 = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900)); window.setContentSize(size2); host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "/look-\(name).png"))
            window.orderOut(nil)
        }
        try await shot("overview", .overview)
        try await shot("timer", .awake)
        try await shot("awake", .awake, awakeTab: true)
        try model.selectSleepTimer(minutes: 30)
        try await shot("timer-running", .awake)
        model.stop()
    }

    func testSelectingATabSlidesTheCapsulePillOnALayerAndNeverTakesFocus() async throws {
        var section = QuickPanelSection.overview
        let tabs = QuickPanelTabs(selection: Binding(get: { section }, set: { section = $0 }))
        let host = NSHostingController(rootView: tabs.frame(width: 360).padding(20).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark).environment(\.controlActiveState, .key))
        let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 400, height: 76)); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let control = try XCTUnwrap(all(host.view).compactMap { $0 as? FullWidthSegmentedTabs.FullWidthControl }.first)
        XCTAssertEqual(control.focusRingType, NSFocusRingType.none, "No focus frame around the tabs.")
        XCTAssertFalse(control.isPillSliding)
        let segmentWidth = control.bounds.width / 4
        XCTAssertEqual(control.pillTargetFrame.midX, segmentWidth / 2, accuracy: 1, "The pill starts under the first tab.")
        control.selectedSegment = 3
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(section, QuickPanelSection.allCases[3], "Selecting a tab reports the typed route.")
        XCTAssertEqual(control.pillTargetFrame.midX, segmentWidth * 3.5, accuracy: 1, "The model position is final at once; the spring runs on the layer.")
        XCTAssertTrue(control.isPillSliding, "The slide is a Core Animation spring, not per-frame redrawing.")
        XCTAssertFalse(window.firstResponder === control, "Selecting a tab must not take keyboard focus (no focus block).")
        try await Task.sleep(for: .milliseconds(700))
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] {
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-tabs.png"))
        }
        control.selectedSegment = 0
        _ = control.sendAction(control.action, to: control.target)
        XCTAssertEqual(section, QuickPanelSection.allCases[0])
        window.orderOut(nil)
    }

    /// A real press (native NSSegmentedControl tracking), not a programmatic selection: the pill must follow it.
    func testARealClickMovesThePillAndTheBinding() async throws {
        var section = QuickPanelSection.overview
        let tabs = QuickPanelTabs(selection: Binding(get: { section }, set: { section = $0 }))
        let host = NSHostingController(rootView: tabs.frame(width: 360).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 400, height: 76)); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let control = try XCTUnwrap(all(host.view).compactMap { $0 as? FullWidthSegmentedTabs.FullWidthControl }.first)
        let segmentWidth = control.bounds.width / 4
        let point = control.convert(NSPoint(x: segmentWidth * 2.5, y: control.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
        }
        window.makeKeyAndOrderFront(nil)
        window.sendEvent(try event(.leftMouseDown, 1))
        window.sendEvent(try event(.leftMouseUp, 2))
        XCTAssertEqual(section, QuickPanelSection.allCases[2], "A real click selects the clicked tab.")
        XCTAssertEqual(control.pillTargetFrame.midX, segmentWidth * 2.5, accuracy: 1, "The pill follows a real click.")
        XCTAssertTrue(control.isPillSliding)
        try await Task.sleep(for: .milliseconds(120))
        control.needsLayout = true; control.layoutSubtreeIfNeeded()
        XCTAssertTrue(control.isPillSliding, "A layout pass in the middle of the slide must not cancel it.")
        window.orderOut(nil)
    }

    /// Press, move and release over the tabs: the pill follows the pointer without selecting, then springs to the nearest tab.
    func testDraggingThePillFollowsThePointerAndSelectsTheNearestTabOnRelease() async throws {
        var section = QuickPanelSection.overview
        let tabs = QuickPanelTabs(selection: Binding(get: { section }, set: { section = $0 }))
        let host = NSHostingController(rootView: tabs.frame(width: 360).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 400, height: 76)); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let control = try XCTUnwrap(all(host.view).compactMap { $0 as? FullWidthSegmentedTabs.FullWidthControl }.first)
        let width = control.bounds.width / 4
        func event(_ type: NSEvent.EventType, fraction: CGFloat, number: Int) throws -> NSEvent {
            let point = control.convert(NSPoint(x: fraction * width, y: control.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
        }
        // Grab the selected pill at the centre of tab 0 and drag to 2.6 tabs.
        window.sendEvent(try event(.leftMouseDown, fraction: 0.5, number: 1))
        window.sendEvent(try event(.leftMouseDragged, fraction: 1.5, number: 2))
        XCTAssertEqual(control.pillTargetFrame.midX, width * 1.5, accuracy: 1, "The pill follows the pointer one to one.")
        window.sendEvent(try event(.leftMouseDragged, fraction: 2.6, number: 3))
        XCTAssertEqual(control.pillTargetFrame.midX, width * 2.6, accuracy: 1)
        XCTAssertEqual(section, .overview, "Nothing is selected while dragging.")
        window.sendEvent(try event(.leftMouseDragged, fraction: 9, number: 4))
        XCTAssertEqual(control.pillTargetFrame.midX, width * 3.5, accuracy: 1, "The pill stays inside the control.")
        window.sendEvent(try event(.leftMouseDragged, fraction: 2.6, number: 5))
        window.sendEvent(try event(.leftMouseUp, fraction: 2.6, number: 6))
        XCTAssertEqual(section, QuickPanelSection.allCases[2], "Released over tab 2 (nearest to the pill): it is selected.")
        XCTAssertEqual(control.pillTargetFrame.midX, width * 2.5, accuracy: 1)
        XCTAssertTrue(control.isPillSliding, "The release settles with a spring.")
        XCTAssertFalse(window.firstResponder === control)
        // Drag away and back to the same tab: no selection change, the pill springs back.
        try await Task.sleep(for: .milliseconds(600))   // let the previous spring finish
        window.sendEvent(try event(.leftMouseDown, fraction: 2.5, number: 7))
        window.sendEvent(try event(.leftMouseDragged, fraction: 2.9, number: 8))
        window.sendEvent(try event(.leftMouseUp, fraction: 2.9, number: 9))
        XCTAssertEqual(section, QuickPanelSection.allCases[2])
        XCTAssertEqual(control.pillTargetFrame.midX, width * 2.5, accuracy: 1)
        XCTAssertTrue(control.isPillSliding, "Dropping on the same tab springs back from the release point.")
        window.orderOut(nil)
    }
}
