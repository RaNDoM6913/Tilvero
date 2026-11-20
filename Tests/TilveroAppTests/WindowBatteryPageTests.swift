// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
import PowerPersistence
@testable import TilveroApp

/// A model over an empty temporary history store with a full battery snapshot (capacity, cells, identity, lifetime
/// counters). Fixture data only; no production preferences, journals or control services.
@MainActor private struct BatteryFixture {
    let model: TilveroModel
    let cleanup: () -> Void

    static func reading(_ id: String, _ value: CatalogValue?, at date: Date = Date(),
                        provenance: TelemetryProvenance = .measured, freshness: TelemetryFreshness = .fresh) -> CatalogReading {
        guard let value else {
            return CatalogReading(definition: BatteryCatalog.definition(id), source: "fixture", collectedAt: date, reason: "fixture")
        }
        return CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: "fixture", keyPath: "fixture",
                              collectedAt: date, provenance: provenance, availability: .available, freshness: freshness)
    }

    static func catalog(at date: Date) -> [CatalogReading] {
        let supplied: [CatalogReading] = [
            reading("011", .integer(72), at: date), reading("013", .boolean(true), at: date), reading("015", .boolean(true), at: date),
            reading("023", .text("Good"), at: date), reading("025", .integer(96), at: date),
            reading("026", .decimal(94.2), at: date, provenance: .estimated), reading("027", .integer(146), at: date),
            reading("029", .integer(6249), at: date), reading("030", .integer(5887), at: date),
            reading("035", .decimal(12.64), at: date), reading("036", .decimal(1.42), at: date),
            reading("039", .decimal(32.4), at: date),
            reading("041", .list([.decimal(4.214), .decimal(4.212), .decimal(4.210)]), at: date),
            reading("042", .decimal(4), at: date, provenance: .estimated),
            reading("059", .text("F8Y1234567890"), at: date), reading("062", .text("LION"), at: date),
            reading("103", .decimal(41), at: date, provenance: .inferred), reading("104", .decimal(12), at: date, provenance: .inferred),
            reading("110", .integer(9123), at: date),
        ]
        return BatteryCatalog.complete(supplied, at: date)
    }

    static func make() async throws -> BatteryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowBattery"), defaults = TestDefaults.defaults(suite)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        try await store.close()
        let current = BatterySnapshot(chargePercent: .init(value: 72, source: "fixture", collectedAt: now, freshness: .fresh),
                                      isCharging: .init(value: true, source: "fixture", collectedAt: now, freshness: .fresh),
                                      isExternalPower: .init(value: true, source: "fixture", collectedAt: now, freshness: .fresh),
                                      temperatureCelsius: .init(value: 32.4, source: "fixture", collectedAt: now, freshness: .fresh),
                                      collectedAt: now, catalog: catalog(at: now), monotonicTime: 2_000_000,
                                      batteryIdentityToken: "fixture-battery")
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { current },
                                 liveSampler: { nil }, newWindow: true)
        await model.refresh()
        await model.waitForHistoryWork()
        return BatteryFixture(model: model, cleanup: {
            model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class WindowBatteryPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    private func setLanguage(_ language: String, model: TilveroModel? = nil) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model?.language = language
    }

    private let ru = Locale(identifier: "ru_RU"), en = Locale(identifier: "en_US")

    // MARK: Lead

    func testLeadPrefersWeeklyMedianThenInstantaneousThenDash() {
        setLanguage("ru")
        var input = BatteryLeadInputs(weeklyPercent: 93.6, retention: 94.2, condition: "Хорошее", conditionGood: true, cycles: 146)
        var lead = BatteryLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(lead.value, "≈ 94 %")
        XCTAssertEqual(lead.status, "Хорошее")
        XCTAssertEqual(lead.tone, .accent)
        XCTAssertEqual(lead.detail, L10n.text("capacity retention (lead)") + " · 146 циклов")
        XCTAssertFalse(lead.stale)

        input.weeklyPercent = nil
        input.retention = 91.4
        input.retentionStale = true
        lead = BatteryLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(lead.value, "≈ 91 %", "no weekly median yet: the instantaneous 026 with ≈")
        XCTAssertTrue(lead.stale, "a stale instantaneous value carries the clock")

        input.retention = nil
        lead = BatteryLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(lead.value, "—")
        XCTAssertEqual(lead.detail, "146 циклов", "the retention fragment is dropped with its value")
        XCTAssertFalse(lead.stale)

        input.cycles = nil
        input.condition = nil
        lead = BatteryLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(lead.detail, "")
        XCTAssertEqual(lead.status, L10n.text("No data"))
        XCTAssertEqual(lead.tone, .secondary)
    }

    func testLeadConditionToneAndCyclePlurals() {
        setLanguage("ru")
        let lead = BatteryLead.make(BatteryLeadInputs(retention: 80, condition: "Service", conditionGood: false), language: "ru", locale: ru)
        XCTAssertEqual(lead.tone, .attention)
        XCTAssertEqual(BatteryLead.cyclesText(1, language: "ru", locale: ru), "1 цикл")
        XCTAssertEqual(BatteryLead.cyclesText(3, language: "ru", locale: ru), "3 цикла")
        XCTAssertEqual(BatteryLead.cyclesText(12, language: "ru", locale: ru), "12 циклов")
        let thousand = BatteryLead.cyclesText(1021, language: "ru", locale: ru)
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(thousand, "1 021 цикл")
        setLanguage("en")
        XCTAssertEqual(BatteryLead.cyclesText(0, language: "en", locale: en), "0 cycles", "a valid zero stays 0")
        XCTAssertEqual(BatteryLead.cyclesText(1, language: "en", locale: en), "1 cycle")
    }

    func testWearIsDerivedFromTheShownRetention() {
        XCTAssertEqual(BatteryLead.wear(retention: 94.2, locale: en).text, "≈ 5.8 %")
        XCTAssertEqual(BatteryLead.wear(retention: 100, locale: en).text, "≈ 0.0 %", "no «-0»")
        XCTAssertEqual(BatteryLead.wear(retention: nil).text, "—")
        XCTAssertEqual(BatteryLead.wear(retention: 90, stale: true).state, .stale)
        XCTAssertEqual(BatteryLead.retention(BatteryLeadInputs(weeklyPercent: 93, retention: 95)), 93)
        XCTAssertEqual(BatteryLead.retention(BatteryLeadInputs(weeklyPercent: nil, retention: 95)), 95)
        XCTAssertNil(BatteryLead.retention(BatteryLeadInputs()))
    }

    // MARK: Rows

    func testRowsUseDashMaskAndCatalogTitles() {
        setLanguage("ru")
        let catalog = BatteryFixture.catalog(at: Date())
        let battery = BatteryRows.rows(BatteryRows.battery, catalog: catalog, fahrenheit: false)
        XCTAssertEqual(battery.map(\.id), ["023", "025", "057", "062", "059"])
        let serial = battery.first { $0.id == "059" }!
        XCTAssertEqual(serial.value, "••••••", "sensitive until Reveal identifiers")
        XCTAssertTrue(serial.dim)
        XCTAssertNil(serial.infoID)
        let revealed = BatteryRows.rows(BatteryRows.battery, catalog: catalog, fahrenheit: false, reveal: true).first { $0.id == "059" }!
        XCTAssertEqual(revealed.value, "F8Y1234567890")
        let manufacturer = battery.first { $0.id == "057" }!
        XCTAssertEqual(manufacturer.value, "—")
        XCTAssertEqual(manufacturer.state, .unavailable)
        XCTAssertEqual(manufacturer.infoID, "057")
        XCTAssertEqual(battery.first { $0.id == "023" }!.value, L10n.text("Good"))

        let lifetime = BatteryRows.rows(BatteryRows.lifetime, catalog: catalog, fahrenheit: false)
        XCTAssertEqual(lifetime.count, 9)
        XCTAssertEqual(lifetime.first!.label, BatteryCatalog.definition("103").titleRussian, "catalog title without an app key")
        XCTAssertTrue(lifetime.first!.value.hasPrefix("≈ "), "inferred scale is an estimate")

        let now = BatteryRows.rows(BatteryRows.now, catalog: catalog, fahrenheit: true)
        XCTAssertEqual(now.first { $0.id == "039" }!.value, "90,3 °F")
        XCTAssertEqual(now.first { $0.id == "035" }!.value, "12,64 В")
        XCTAssertEqual(now.first { $0.id == "011" }!.value, "72 %")
    }

    func testCellsSplitTheReportedListOnly() {
        setLanguage("en")
        let catalog = BatteryFixture.catalog(at: Date())
        let rows = BatteryRows.cells(catalog, fahrenheit: false, language: "en", locale: en)
        XCTAssertEqual(rows.map(\.label), ["Cell 1", "Cell 2", "Cell 3", "Battery current", L10n.text("Cell temperatures")])
        XCTAssertEqual(rows[0].value, "4.214 V")
        XCTAssertEqual(rows[2].value, "4.210 V")
        XCTAssertEqual(rows[3].value, "1.42 A")
        XCTAssertEqual(rows[4].value, "—", "missing cell temperatures are not reconstructed")

        let missing = catalog.map { $0.id == "041" ? BatteryFixture.reading("041", nil) : $0 }
        let fallback = BatteryRows.cells(missing, fahrenheit: false, language: "en", locale: en)
        XCTAssertEqual(fallback.count, 3)
        XCTAssertEqual(fallback[0].value, "—")
        XCTAssertEqual(fallback[0].infoID, "041")
    }

    func testCatalogSectionsFilterAndCount() {
        setLanguage("en")
        let catalog = BatteryFixture.catalog(at: Date())
        let all = BatteryCatalogSections.make(catalog, search: "", showUnavailable: true, reveal: false, fahrenheit: false)
        XCTAssertEqual(all.reduce(0) { $0 + $1.rows.count }, catalog.count, "every catalog field stays reachable")
        XCTAssertEqual(all.map(\.id).prefix(3), ["device", "charge", "condition"])
        let available = BatteryCatalogSections.make(catalog, search: "", showUnavailable: false, reveal: false, fahrenheit: false)
        XCTAssertLessThan(available.reduce(0) { $0 + $1.rows.count }, catalog.count)
        XCTAssertTrue(available.allSatisfy { $0.rows.allSatisfy { $0.value != "—" || $0.id == "059" } })
        let byID = BatteryCatalogSections.make(catalog, search: "027", showUnavailable: false, reveal: false, fahrenheit: false)
        XCTAssertEqual(byID.flatMap(\.rows).map(\.id), ["027"])
        XCTAssertEqual(byID.first?.rows.first?.value, "146")
        let none = BatteryCatalogSections.make(catalog, search: "zzzz-no-match", showUnavailable: true, reveal: false, fahrenheit: false)
        XCTAssertTrue(none.isEmpty)
        let serial = all.flatMap(\.rows).first { $0.id == "059" }!
        XCTAssertEqual(serial.value, "••••••")
        let revealed = BatteryCatalogSections.make(catalog, search: "059", showUnavailable: true, reveal: true, fahrenheit: false)
        XCTAssertEqual(revealed.flatMap(\.rows).first?.value, "F8Y1234567890")
    }

    // MARK: Render

    /// Hosts the page in a window configured like the production one; RU/EN × light/dark for Summary and All data.
    /// Writes PNGs when `TILVERO_RENDER_OUT` is set (display must be awake; windows flash on screen).
    func testBatteryGallery() async throws {
        let fixture = try await BatteryFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                for mode in BatteryMode.allCases {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
                    MainWindowController.configure(window)
                    let theme = WindowTheme.resolve(dark: dark, reduceTransparency: false, increaseContrast: false)
                    let host = NSHostingView(rootView: NavigationStack { BatteryPage(model: model, mode: mode) }
                        .background { WindowCanvas().ignoresSafeArea() }
                        .tint(WindowTheme.accent)
                        .environment(\.windowTheme, theme)
                        .environment(\.locale, L10n.locale)
                        .font(.system(size: 13)))
                    host.sceneBridgingOptions = [.title, .toolbars]
                    window.contentView = host
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setFrame(NSRect(x: 60, y: 60, width: 800, height: 940), display: true)
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(1.5))
                    XCTAssertEqual(window.title, L10n.text("Battery"), "page title reaches the window toolbar")
                    if let output {
                        let name = "battery-\(mode == .summary ? "" : "all-")\(language)-\(dark ? "dark" : "light").png"
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name).path]
                        try capture.run(); capture.waitUntilExit()
                    }
                    window.close()
                }
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["BatteryPage"] ?? 0, 1)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion, "rendering never starts a control")
        XCTAssertNil(model.nativeCharge.observed)
    }
}
