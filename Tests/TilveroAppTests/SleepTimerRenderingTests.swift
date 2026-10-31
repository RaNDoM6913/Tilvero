import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

/// Renders the actual production views with an injected sleep transport and clock.
/// No request is ever allowed to reach IOKit; exports are opt-in fixture evidence.
@MainActor final class SleepTimerRenderingTests: XCTestCase {
    func testCompactMainAndMenuRenderBothStatesWithoutRequestingSleep() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let suite = "TimerRender-\(UUID())", prefs = UserDefaults(suiteName: suite)!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let driver = RenderSleepDriver(), clock = RenderSleepClock()
            let service = SleepTimerService(driver: driver, monotonic: { clock.value }, suspending: { clock.value }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
            let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), sleepTimerService: service)
            model.selectedSection = .sleep
            for running in [false, true] {
                if running { try service.start(minutes: 30); clock.value = 138 }
                let card = NSHostingController(rootView: SleepTimerPanel(model: model))
                let cardSize = card.sizeThatFits(in: NSSize(width: 490, height: 1000))
                XCTAssertLessThanOrEqual(cardSize.height, running ? 170 : 230, "Compact timer must not regrow into the large hero")
                for width in [760.0, 1000.0] {
                    try await render(BatteryInfoView(model: model), size: NSSize(width: width, height: 730), name: "\(language)-main-\(running ? "running" : "setup")-\(Int(width))")
                }
                let quick = QuickPanel(model: model, section: .awake)
                let host = NSHostingController(rootView: quick)
                let quickSize = host.sizeThatFits(in: NSSize(width: 360, height: 700))
                XCTAssertEqual(quickSize.width, 360, accuracy: 1)
                XCTAssertLessThan(quickSize.height, 620)
                try await render(quick, size: quickSize, name: "\(language)-quick-\(running ? "running" : "setup")", dark: true)
            }
            service.cancel(); try service.start(minutes: 1)
            try await render(SleepTimerWarningContent(service: service, openDetails: {}), size: NSSize(width: 440, height: 180), name: "\(language)-minute-warning", dark: true)
            XCTAssertTrue(service.isWarning)
            XCTAssertEqual(driver.requests, 0)
            model.stop(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
    }
    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = false) async throws {
        let host = NSHostingController(rootView: view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 1)
        if let folder = ProcessInfo.processInfo.environment["TILVERO_TIMER_RENDER_DIR"] {
            let root = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        window.orderOut(nil)
    }
}
@MainActor private final class RenderSleepClock { var value = 0.0 }
@MainActor private final class RenderSleepDriver: SleepTimerTransport {
    var requests = 0
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() { requests += 1; XCTFail("Fixture rendering must not request sleep") }
}
