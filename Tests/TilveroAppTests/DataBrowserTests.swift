import XCTest
import AppKit
import SwiftUI
import PowerCore
@testable import TilveroApp

@MainActor final class DataBrowserTests: XCTestCase {
    func testAllDataKeepsEveryFieldIncludingUnavailableAndSensitiveOnes() {
        let catalog = BatteryCatalog.unavailable()
        let groups = CatalogDataGroup.allData(catalog)
        let rows = groups.flatMap(\.readings)
        XCTAssertEqual(rows.count, 115)
        XCTAssertEqual(Set(rows.map(\.id)).count, 115)
        XCTAssertTrue(rows.contains { $0.id == "048" && $0.privacy == .sensitive })
        XCTAssertTrue(rows.contains { $0.id == "115" && $0.value == nil })
        XCTAssertEqual(CatalogDataGroup.filtered(rows, search: "номинальная", showUnavailable: false).map(\.id), ["113", "115"])
    }

    func testWhitespaceSearchBehavesLikeEmptyAndTrimmedQueryRetainsUnavailableMatches() {
        let available = CatalogReading(definition: BatteryCatalog.definition("038"), value: .decimal(-8.4), source: "fixture")
        let unavailable = BatteryCatalog.unavailable().first { $0.id == "115" }!
        let rows = [available, unavailable]
        XCTAssertEqual(CatalogDataGroup.filtered(rows, search: " ", showUnavailable: false).map(\.id), ["038"])
        XCTAssertEqual(CatalogDataGroup.filtered(rows, search: " \n\t ", showUnavailable: false).map(\.id), ["038"])
        XCTAssertEqual(CatalogDataGroup.filtered(rows, search: "", showUnavailable: false).map(\.id), ["038"])
        XCTAssertEqual(CatalogDataGroup.filtered(rows, search: " \n115\t ", showUnavailable: false).map(\.id), ["115"])
    }

    func testDisplayPreservesExactIntegerAndQualifiesDerivedAndPrivateValues() {
        let counter = CatalogReading(definition: BatteryCatalog.definition("110"), value: .integer(9_007_199_254_740_993), source: "fixture")
        let shown = CatalogDataPresentation.value(counter, reveal: false, fahrenheit: false)
        XCTAssertEqual(shown.filter(\.isNumber), "9007199254740993", "Large source counters must never pass through Double")
        let derived = CatalogReading(definition: BatteryCatalog.definition("026"), value: .decimal(94.2), source: "fixture", provenance: .inferred)
        XCTAssertTrue(CatalogDataPresentation.value(derived, reveal: false, fahrenheit: false).hasPrefix("≈ "))
        let privateReading = CatalogReading(definition: BatteryCatalog.definition("059"), value: .text("PRIVATE-SERIAL"), rawValue: .text("PRIVATE-RAW"), source: "fixture")
        XCTAssertEqual(CatalogDataPresentation.value(privateReading, reveal: false, fahrenheit: false), "••••••")
        XCTAssertNil(CatalogDataPresentation.rawValue(privateReading, reveal: false))
        XCTAssertEqual(CatalogDataPresentation.rawValue(privateReading, reveal: true), "PRIVATE-RAW")
        XCTAssertEqual(CatalogDataPresentation.value(BatteryCatalog.unavailable()[0], reveal: true, fahrenheit: false), "—")
    }

    func testUnitsStayLocalWhileStaleAndUnavailableReadingsRemainHonest() {
        XCTAssertEqual(CatalogDataPresentation.unit("W", language: "ru"), "Вт")
        XCTAssertEqual(CatalogDataPresentation.unit("mAh", language: "ru"), "мА·ч")
        XCTAssertEqual(CatalogDataPresentation.unit("Wh", language: "en"), "Wh")
        let previous = CatalogReading(definition: BatteryCatalog.definition("038"), value: .decimal(-8.4), source: "fixture", freshness: .fresh)
        let missing = CatalogReading(definition: BatteryCatalog.definition("038"), source: "fixture")
        let stale = missing.retainingPrevious(previous, age: 120)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertTrue(CatalogDataPresentation.value(stale, reveal: false, fahrenheit: false).contains("8"))
        XCTAssertEqual(CatalogDataGroup.filtered([stale, missing], search: "", showUnavailable: false).count, 1)
        XCTAssertEqual(CatalogDataGroup.filtered([stale, missing], search: "", showUnavailable: true).count, 2)
    }

    func testDataTabsAndEveryPassivePreviewTabRenderWithoutMutatingActionsOrComposition() async throws {
        let suite = "TilveroDataUI-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: prefs)
        defer { model.stop() }
        await model.refresh()
        model.overviewPreferences.move(.history, by: -1)
        model.overviewPreferences.hidden.insert(.temperature)
        let composition = model.overviewPreferences
        let original = model.control?.charge
        for tab in BatteryDataTab.allCases {
            let host = NSHostingController(rootView: BatteryDataPanel(model: model, tab: tab))
            let size = host.sizeThatFits(in: NSSize(width: 650, height: 2000))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.height, 100)
            try renderIfRequested(ScrollView { BatteryDataPanel(model: model, tab: tab).padding(24) }, name: "battery-" + tab.rawValue)
        }
        for tab in PowerDataTab.allCases {
            let host = NSHostingController(rootView: PowerDataPanel(model: model, tab: tab))
            XCTAssertGreaterThan(host.sizeThatFits(in: NSSize(width: 650, height: 2500)).height, 100)
            try renderIfRequested(ScrollView { PowerDataPanel(model: model, tab: tab).padding(24) }, name: "power-" + tab.rawValue)
        }
        for tab in QuickPanelSection.allCases {
            let host = NSHostingController(rootView: PassiveQuickPanelPreview(model: model, section: tab))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 1400)))
            host.view.layoutSubtreeIfNeeded()
            let controls = descendants(host.view).compactMap { $0 as? NSControl }
            XCTAssertFalse(controls.contains { $0.identifier?.rawValue == "keep-awake-start" || $0.identifier?.rawValue == "keep-awake-stop" })
            try renderIfRequested(PassiveQuickPanelPreview(model: model, section: tab), name: "preview-" + tab.rawValue, width: 360)
        }
        model.selectedSection = .settings
        for page in SettingsPage.allCases {
            model.selectedSettingsPage = page
            let host = NSHostingController(rootView: BatteryInfoView(model: model))
            let size = host.sizeThatFits(in: NSSize(width: 1100, height: 900))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            try renderIfRequested(BatteryInfoView(model: model), name: "settings-" + page.rawValue, width: 1100)
        }
        XCTAssertEqual(model.overviewPreferences, composition)
        XCTAssertEqual(model.control?.charge, original)
        XCTAssertNil(model.nativeCharge.observed)
        XCTAssertNil(model.modeReport)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }
    func testPassivePreviewWithAvailableAwakeTransportNeverExposesEnabledActionButtons() async throws {
        let suite = "TilveroPassiveLive-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        prefs.set(false, forKey: "historyEnabled")
        let transport = AwakeFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("history.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "Data UI fixture — no hardware read") }, keepAwakeTransport: transport)
        defer { model.stop(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        await model.refresh()
        let draft = model.keepAwakeDraft
        for tab in QuickPanelSection.allCases {
            let host = NSHostingController(rootView: PassiveQuickPanelPreview(model: model, section: tab))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 1200)))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(descendants(host.view).compactMap { $0 as? NSButton }.contains { $0.isEnabled },
                           "Only local tab selection is interactive; action-looking controls must be disabled")
        }
        XCTAssertEqual(model.keepAwakeDraft, draft)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertTrue(transport.assertions.isEmpty)
        XCTAssertNil(model.modeReport)
        // An owned finite session still offers no working Stop/extension in preview.
        try model.keepAwake.start(seconds: 900)
        let active = NSHostingController(rootView: PassiveQuickPanelPreview(model: model, section: .awake))
        let activeWindow = NSWindow(contentViewController: active)
        activeWindow.setContentSize(active.sizeThatFits(in: NSSize(width: 360, height: 1200)))
        active.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(active.view).compactMap { $0 as? NSButton }.contains { $0.isEnabled })
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        try model.keepAwake.stop()
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }
    private func renderIfRequested<V: View>(_ view: V, name: String, width: CGFloat = 700) throws {
        guard let path = ProcessInfo.processInfo.environment["TILVERO_DATA_UI_RENDER_ROOT"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = NSHostingController(rootView: view.frame(width: width, height: 900, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: width, height: 900))
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
