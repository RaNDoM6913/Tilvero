import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

/// The closed-lid control is a plain bottom row of the Keep Awake page: title, info button, switch. The earlier
/// "Settings" disclosure with its explanation text is gone; the explanation lives in the info popover.
@MainActor final class ClosedLidRowTests: XCTestCase {
    func testTheRowIsOneStableSwitchRowAndStaysOff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var heights: [CGFloat] = []
        for width: CGFloat in [320, 240] {
            let host = NSHostingController(rootView: ClosedLidExplanationView(model: fixture.model).frame(width: width))
            let window = NSWindow(contentViewController: host)
            defer { window.orderOut(nil) }
            window.setContentSize(NSSize(width: width, height: 200))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            heights.append(host.sizeThatFits(in: NSSize(width: width, height: 1000)).height)
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "No wrapping caption: the row height does not depend on width.")
        XCTAssertEqual(heights[0], 32, accuracy: 1)
        XCTAssertFalse(fixture.model.closedLid.isOn)
    }

    func testTheKeepAwakePageShowsTheChargeBlockAndTheLidRowWithoutHelperCaptions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let host = NSHostingController(rootView: KeepAwakePillsPanel(model: fixture.model).frame(width: 320).padding(20))
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 900)))
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let labels = all(host.view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(labels.contains(L10n.text("Choose a time to start immediately.")), "The instruction moved into the info popover.")
        XCTAssertFalse(labels.contains(L10n.text("Settings")), "The closed-lid disclosure is a plain row now.")
        XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(fixture.model.closedLid.isOn)
    }

    @MainActor private struct Fixture {
        let suite = "ClosedLidRow-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClosedLidRow-\(UUID())")
        let preferences: UserDefaults
        let model: TilveroModel
        init() throws {
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set(false, forKey: "historyEnabled")
            model = TilveroModel(isDemo: true, preferences: preferences,
                historyURL: root.appendingPathComponent("History.sqlite"),
                snapshotProvider: { .unavailable(reason: "Closed-lid row fixture — no hardware read") })
        }
        func cleanUp() {
            model.stop()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

extension ClosedLidRowTests {
    /// Renders the real Keep Awake page (RU/EN) when TILVERO_LOOK_DIR is set.
    func testRenderKeepAwakePage() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] else { throw XCTSkip("render is opt-in") }
        let suite = "KeepRender-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") })
        defer { model.stop() }
        await model.keepAwakeUntilCharge.observe(percent: 64, fresh: true, externalPower: false)
        for language in ["ru", "en"] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            for (name, section) in [("awake", QuickPanelSection.awake)] {
                let host = NSHostingController(rootView: QuickPanel(model: model, section: section).frame(width: 360)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                    .environment(\.controlActiveState, .key).environment(\.locale, L10n.locale))
                let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
                window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 1000))); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                // second tab of the Sleep page = Keep Awake
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                if let tabs = all(host.view).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 2 }) {
                    tabs.selectedSegment = 1; _ = tabs.sendAction(tabs.action, to: tabs.target)
                    try await Task.sleep(for: .milliseconds(300))
                }
                window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 1000))); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-\(name)-page-\(language).png"))
                window.orderOut(nil)
            }
        }
    }
}
