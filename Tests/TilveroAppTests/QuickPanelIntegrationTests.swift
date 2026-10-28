import XCTest
import AppKit
import SwiftUI
import PowerCore
import ChargeBackends
@testable import TilveroApp

@MainActor final class QuickPanelIntegrationTests: XCTestCase {
    func testCompactModesExposeSavedSelectionWithoutEditingControls() async throws {
        let suite = "TilveroCompact-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: prefs)
        await model.refresh()
        var saved = model.modeLibrary.plan(.economy); saved.chargeTarget = 90; saved.brightnessPercent = 40
        try model.saveMode(saved)
        let host = NSHostingController(rootView: QuickPanel(model: model, maximumHeight: 1000, section: .modes))
        let size = host.sizeThatFits(in: NSSize(width: 360, height: 1200))
        let window = NSWindow(contentViewController: host); window.setContentSize(size)
        host.view.layoutSubtreeIfNeeded()
        let views = descendants(host.view)
        XCTAssertTrue(views.compactMap { $0 as? NSSlider }.isEmpty, "Quick Modes must use saved plans; full sliders stay in the editor")
        XCTAssertTrue(views.compactMap { $0 as? NSStepper }.isEmpty)
        XCTAssertLessThan(size.height, 560)
        XCTAssertNil(model.modeReport, "Opening Modes never applies a plan")
    }
    func testKnownACSuppressesDischargeForecastWithoutChangingSavedComposition() async throws {
        let suite = "TilveroForecast-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), snapshotProvider: {
            BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", freshness: .fresh), isExternalPower: .init(value: true, source: "fixture", freshness: .unknown))
        })
        defer { model.stop() }
        await model.refresh()
        XCTAssertTrue(model.overviewPreferences.order.contains(.forecast))
        XCTAssertFalse(model.visibleOverviewMetrics.contains(.forecast))
        XCTAssertNil(model.dischargeForecast)
    }
    func testAlreadyConfirmedNativeTargetDoesNotOfferApply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = NativeChargeService(client: PanelChargeFixture(), journalURL: root.appendingPathComponent("session.json"), admitted: true)
        await service.refresh()
        XCTAssertFalse(service.needsApply(target: 80))
        XCTAssertTrue(service.needsApply(target: 90))
        XCTAssertFalse(service.needsApply(target: 79))
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
private actor PanelChargeFixture: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 80, optimizedCharging: true), supportedTargets: [80,85,90,95,100], registeredManualLimit: 80)
    }
    func setLimit(_ target: Int) { XCTFail("Presentation never writes") }
    func setEnabled(_ enabled: Bool) { XCTFail("Presentation never writes") }
}
