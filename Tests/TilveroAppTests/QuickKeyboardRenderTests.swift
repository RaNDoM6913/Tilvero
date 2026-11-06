import AppKit
import SwiftUI
import XCTest
import KeyboardBackends
@testable import TilveroApp

/// Renders the real quick panel with the keyboard backlight row. Set TILVERO_QUICK_RENDER_DIR to export PNGs.
@MainActor final class QuickKeyboardRenderTests: XCTestCase {
    func testQuickOverviewShowsTheKeyboardRowWhenAvailableAndNothingWhenNot() async throws {
        for language in ["ru", "en"] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            for available in [true, false] {
                let suite = "QuickKbd-\(UUID())", prefs = UserDefaults(suiteName: suite)!
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
                let service = KeyboardBacklightService(driver: QuickKeyboardDriver(fails: !available), storage: QuickKeyboardMemory())
                XCTAssertFalse(service.isAvailable, "Before the panel opens nothing has been read.")
                let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), keyboardBacklight: service)
                model.overviewPreferences.hidden.remove(.keyboardBacklight)
                await model.quickPanelWillOpen()
                XCTAssertEqual(service.isAvailable, available, "Opening the quick panel reads the backlight.")
                let quick = QuickPanel(model: model, section: .overview)
                let host = NSHostingController(rootView: quick.frame(width: 360).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark).environment(\.locale, L10n.locale))
                let size = host.sizeThatFits(in: NSSize(width: 360, height: 900))
                let window = NSWindow(contentViewController: host)
                window.appearance = NSAppearance(named: .darkAqua)
                window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutSubtreeIfNeeded()
                if let folder = ProcessInfo.processInfo.environment["TILVERO_QUICK_RENDER_DIR"] {
                    let dir = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("quick-\(language)-\(available ? "kbd" : "nokbd").png"))
                }
                window.orderOut(nil); model.stop()
            }
        }
    }
}
@MainActor private final class QuickKeyboardMemory: KeyboardBacklightPreferenceStorage { var lastNonzeroBrightness: Double? }
@MainActor private final class QuickKeyboardDriver: KeyboardBacklightTransport {
    let fails: Bool
    init(fails: Bool) { self.fails = fails }
    func read() async throws -> KeyboardBacklightObservation {
        if fails { throw KeyboardBacklightError.unsupported }
        return try KeyboardBacklightObservation(keyboardID: 1, brightness: 0.36, automaticBrightness: true, suppressed: false, dimmed: false, observedAt: Date())
    }
    func setBrightness(_ value: Double, keyboardID: UInt64) async throws {}
}
