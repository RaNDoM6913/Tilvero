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
            let host = NSHostingController(rootView: QuickPanel(model: model, section: section).frame(width: 360).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark).environment(\.controlActiveState, .key).environment(\.locale, L10n.locale))
            let size = host.sizeThatFits(in: NSSize(width: 360, height: 900))
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
            let size2 = host.sizeThatFits(in: NSSize(width: 360, height: 900)); window.setContentSize(size2); host.view.layoutSubtreeIfNeeded()
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

    func testDraggingAcrossTheTabsMovesThePillAndSelectsTheSegmentUnderThePointerOnRelease() async throws {
        var section = QuickPanelSection.overview
        let tabs = QuickPanelTabs(selection: Binding(get: { section }, set: { section = $0 }))
        let host = NSHostingController(rootView: tabs.frame(width: 360).padding(20).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark).environment(\.controlActiveState, .key))
        let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 400, height: 76)); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let control = try XCTUnwrap(all(host.view).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(control.focusRingType, NSFocusRingType.none, "No focus frame around the tabs.")
        func point(_ fraction: CGFloat) -> NSPoint {
            control.convert(NSPoint(x: (fraction + 0.5) * control.bounds.width / CGFloat(control.segmentCount), y: control.bounds.midY), to: nil)
        }
        func event(_ type: NSEvent.EventType, _ fraction: CGFloat, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point(fraction), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
        }
        control.mouseDown(with: try event(.leftMouseDown, 0, number: 1))
        control.mouseDragged(with: try event(.leftMouseDragged, 1.5, number: 2))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(section, .overview, "Nothing is selected until the pointer is released.")
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] {
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-dragging.png"))
        }
        control.mouseDragged(with: try event(.leftMouseDragged, 3, number: 3))
        control.mouseUp(with: try event(.leftMouseUp, 3, number: 4))
        XCTAssertEqual(section, QuickPanelSection.allCases[3], "Releasing over the last tab selects it.")
        XCTAssertFalse(window.firstResponder === control, "Pressing a tab must not take keyboard focus (no focus block).")
        control.mouseDown(with: try event(.leftMouseDown, 1, number: 5))
        control.mouseUp(with: try event(.leftMouseUp, 1, number: 6))
        XCTAssertEqual(section, QuickPanelSection.allCases[1], "A plain click selects the clicked tab.")
        control.mouseDown(with: try event(.leftMouseDown, 2, number: 7))
        control.mouseDragged(with: try event(.leftMouseDragged, -4, number: 8))
        control.mouseUp(with: try event(.leftMouseUp, -4, number: 9))
        XCTAssertEqual(section, QuickPanelSection.allCases[0], "Dragging far past the end clamps to the first tab.")
        window.orderOut(nil)
    }
}
