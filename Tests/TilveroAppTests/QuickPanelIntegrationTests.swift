import XCTest
import AppKit
import SwiftUI
import PowerCore
import ChargeBackends
@testable import TilveroApp

@MainActor final class QuickPanelIntegrationTests: XCTestCase {
    func testFourthAwakeTabFitsEnglishAndRussianAndDoesNotStartOnSelection() async throws {
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain) }
        let fixture = try AwakePanelFixture()
        defer { fixture.cleanUp() }
        for language in ["en", "ru"] {
            UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                                   forName: UserDefaults.argumentDomain)
            fixture.model.language = language
            let host = QuickPanelHostingController(model: fixture.model, maximumHeight: 900)
            let window = NSWindow(contentViewController: host)
            window.setContentSize(host.preferredContentSize)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let segments = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSegmentedControl }.first)
            XCTAssertEqual(segments.segmentCount, 4)
            guard segments.segmentCount == 4 else { return }
            XCTAssertEqual(segments.label(forSegment: 3), language == "ru" ? "Не спать" : "Awake")
            XCTAssertLessThanOrEqual(segments.fittingSize.width, 320, "Four localized tabs must fit the content width")
            host.onSizeChange = { window.setContentSize($0) }
            segments.selectedSegment = 3
            _ = segments.sendAction(segments.action, to: segments.target)
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.preferredContentSize.width, 360)
            XCTAssertLessThan(host.preferredContentSize.height, 620, "Flexible Awake remains bounded in the native panel")
            XCTAssertGreaterThan(host.preferredContentSize.height, 180)
            XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
            XCTAssertTrue(fixture.driver.assertions.isEmpty, "Opening or selecting Awake must not start a session")
        }
    }

    func testDurationSelectionAndSettingsPreviewStayPassiveAndShareSavedDuration() async throws {
        let fixture = try AwakePanelFixture()
        defer { fixture.cleanUp() }
        let awakeHost = NSHostingController(rootView: QuickPanel(model: fixture.model, maximumHeight: 900, section: .awake))
        let awakeWindow = NSWindow(contentViewController: awakeHost)
        awakeWindow.setContentSize(awakeHost.sizeThatFits(in: NSSize(width: 360, height: 900)))
        awakeHost.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        for option in [15, 30, 60, 120, 240, 480, -1, -2, 0] {
            fixture.model.selectKeepAwakeOption(option)
            awakeHost.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(fixture.model.keepAwakeSelectedOption, option)
            XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
        }
        fixture.model.selectKeepAwakeOption(120)
        XCTAssertEqual(fixture.model.keepAwakeDuration, .twoHours)
        fixture.model.overviewPreferences.hidden.remove(.keepAwake)
        let host = NSHostingController(rootView: QuickPanelBuilder(model: fixture.model))
        let size = host.sizeThatFits(in: NSSize(width: 720, height: 1200))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(size)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
        let reopened = TilveroModel(isDemo: true, preferences: fixture.prefs, keepAwakeTransport: fixture.driver)
        defer { reopened.stop() }
        XCTAssertEqual(reopened.keepAwakeDuration, .twoHours)
        let settingsAwake = NSHostingController(rootView: KeepAwakePanel(model: reopened))
        _ = settingsAwake.sizeThatFits(in: NSSize(width: 360, height: 600))
        XCTAssertFalse(reopened.keepAwake.isAvailable, "Simulation keeps the shared Start unavailable")
        XCTAssertFalse(reopened.keepAwake.hasOwnedAssertion)
        XCTAssertTrue(fixture.driver.assertions.isEmpty, "No opening, duration change or preview may acquire an assertion")
    }

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

@MainActor private struct AwakePanelFixture {
    let suite: String
    let prefs: UserDefaults
    let root: URL
    let driver: AwakeFixture
    let model: TilveroModel

    init(isDemo: Bool = false) throws {
        suite = "TilveroAwakePanel-\(UUID())"
        prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        prefs.set(false, forKey: "historyEnabled")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        driver = AwakeFixture()
        model = TilveroModel(isDemo: isDemo, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                             snapshotProvider: { .unavailable(reason: "Panel fixture — no hardware read") },
                             keepAwakeTransport: driver)
    }
    func cleanUp() {
        model.stop()
        prefs.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
private actor PanelChargeFixture: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 80, optimizedCharging: true), supportedTargets: [80,85,90,95,100], registeredManualLimit: 80)
    }
    func setLimit(_ target: Int) { XCTFail("Presentation never writes") }
    func setEnabled(_ enabled: Bool) { XCTFail("Presentation never writes") }
}
