// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import PowerPersistence
import PowerTelemetry
@testable import TilveroApp

@MainActor final class PowerCardsTests: XCTestCase {
    func testNewPowerCardsAppendHiddenWithoutReplacingSavedComposition() {
        let saved = OverviewPreferences.load(Data(#"{"order":["history","power","temperature","forecast","chargeLimit","keepAwake"],"hidden":["temperature"]}"#.utf8))
        XCTAssertEqual(Array(saved.order.prefix(6)).map(\.rawValue), ["history","power","temperature","forecast","chargeLimit","keepAwake"])
        XCTAssertEqual(Array(saved.order.suffix(5)).map(\.rawValue), ["systemPower","adapter","batteryHealth","applications","keyboardBacklight"])
        XCTAssertEqual(saved.hidden.map(\.rawValue).sorted(), ["adapter","applications","batteryHealth","keyboardBacklight","systemPower","temperature"])
    }
    func testMetricGraphBreaksAtStaleMissingSourceAndPowerTransitions() throws {
        let now = Date()
        let snapshots = [sample(0, now, value: 3), sample(1, now, value: nil), sample(2, now, value: 5),
                      sample(3, now, value: 6, freshness: .stale), sample(4, now, value: 7),
                      sample(5, now, value: 8, source: "changed"), sample(6, now, value: 9, source: "changed", ac: false)]
        let store = try BatteryHistoryStore(url: nil)
        defer { try? store.close() }
        for snapshot in snapshots { try store.record(snapshot) }
        let values = try store.samples()
        let points = PowerMetricHistory.points(values, id: "054", since: now.addingTimeInterval(-1))
        XCTAssertEqual(points.map(\.value), [3,5,7,8,9])
        XCTAssertEqual(Set(points.map(\.series)).count, 5)
        let summary = try XCTUnwrap(PowerMetricHistory.summary(points))
        XCTAssertEqual(summary.count, 1, "Summary covers only the latest comparable continuous series")
        XCTAssertEqual(summary.mean, 9)
        XCTAssertEqual(PowerMetricHistory.points(values, id: "050", since: now).count, 0, "Adapter rating cannot stand in for input history")
    }
    func testPersistedSameProviderPathAndDerivedInputsBreakGraphAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite"), date = Date()
        let provider = MacBatteryProvider(qualification: .appleSilicon)
        let store = try BatteryHistoryStore(url: url)
        for index in 0..<4 {
            let at = date.addingTimeInterval(Double(index))
            var registry: [String: Any] = ["DesignCapacity":5000,"UpdateTime":at.timeIntervalSince1970]
            if index < 2 { registry["Temperature"] = 3000; registry["AppleRawMaxCapacity"] = 4900 }
            else { registry["BatteryData"] = ["Temperature":3100]; registry["NominalChargeCapacity"] = 4800 }
            try store.record(provider.normalize(powerSource:["Current Capacity":80,"Max Capacity":100,"Power Source State":"AC Power"], registry:registry, at:at, uptime:Double(index + 100)))
        }
        try store.close()
        let reopened = try BatteryHistoryStore(url: url)
        defer { try? reopened.close() }
        for id in ["039","026"] {
            let points = PowerMetricHistory.points(try reopened.samples(),id:id,since:date)
            XCTAssertEqual(points.count,4)
            XCTAssertEqual(Set(points.map(\.series)).count,2)
            XCTAssertEqual(PowerMetricHistory.summary(points)?.count,2)
        }
    }
    private func reading(_ id: String, value: Double?, provenance: TelemetryProvenance) -> CatalogReading {
        .init(definition: BatteryCatalog.definition(id), value: value.map(CatalogValue.decimal), source: "fixture", keyPath: "input", provenance: provenance)
    }
    func testEstimateCaptionFollowsProvenance() {
        let estimated = reading("038", value: 12.5, provenance: .estimated)
        let inferred = reading("038", value: 12.5, provenance: .inferred)
        let measured = reading("038", value: 12.5, provenance: .measured)
        XCTAssertEqual(MetricCaption.boundary(for: "038", reading: estimated), L10n.text("battery · V×A estimate"))
        XCTAssertEqual(MetricCaption.boundary(for: "038", reading: inferred), L10n.text("battery · V×A estimate"))
        XCTAssertNil(MetricCaption.boundary(for: "038", reading: measured), "A measured reading carries no estimate wording")
        XCTAssertNil(MetricCaption.boundary(for: "038", reading: nil))
        XCTAssertFalse(MetricCaption.boundary(for: "038", reading: estimated)?.contains("≈") ?? false, "The value formatter owns the approximation prefix")
        XCTAssertEqual(MetricCaption.boundary(for: "054", reading: reading("054", value: 30, provenance: .measured)), L10n.text("Adapter input — a different boundary"))
        XCTAssertNil(MetricCaption.boundary(for: "054", reading: nil))
        XCTAssertNil(MetricCaption.boundary(for: "043", reading: reading("043", value: 9, provenance: .estimated)))
    }
    func testAdapterAbsentMessageAppearsOnce() {
        let message = L10n.text("Adapter not connected — no reading")
        XCTAssertEqual(MetricCaption.absent(for: "054", adapterConnected: false), message)
        XCTAssertNil(MetricCaption.absent(for: "054", adapterConnected: true))
        XCTAssertNil(MetricCaption.absent(for: "038", adapterConnected: false))
        let rating = reading("050", value: 67, provenance: .reported)
        let lines = AdapterMetricCard.captionLines(input: nil, rating: rating, adapterConnected: false)
        XCTAssertEqual(lines.filter { $0 == message }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("not connected") || $0.contains("не подключён") }.count, 1)
        let connected = AdapterMetricCard.captionLines(input: reading("054", value: 30, provenance: .measured), rating: rating, adapterConnected: true)
        XCTAssertFalse(connected.contains(message))
        XCTAssertTrue(connected.contains(L10n.text("Adapter input — a different boundary")))
    }
    func testAllNewStringsHaveRuAndEn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        for key in MetricCaption.allKeys {
            let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: [String: Any]], key)
            for language in ["en", "ru"] {
                let unit = localizations[language]?["stringUnit"] as? [String: String] ?? [:]
                let state: String = unit["state"] ?? ""
                let value: String = unit["value"] ?? ""
                XCTAssertEqual(state, "translated", "\(key) \(language)")
                XCTAssertFalse(value.isEmpty, "\(key) \(language)")
            }
        }
        XCTAssertEqual(Set(MetricCaption.allKeys).count, 3)
    }
    func testTemperatureHasNoChartInSparklineStyle() {
        XCTAssertFalse(PowerMetricCard.showsChart(id: "039", style: .sparkline))
        XCTAssertFalse(PowerMetricCard.showsSparkline(id: "039", style: .sparkline), "Temperature never had a sparkline on the quick page.")
        XCTAssertTrue(PowerMetricCard.showsChart(id: "039", style: .chart))
        XCTAssertFalse(PowerMetricCard.showsSparkline(id: "039", style: .chart))
        for id in ["038", "043", "054"] {
            XCTAssertTrue(PowerMetricCard.showsSparkline(id: id, style: .sparkline), id)
            XCTAssertFalse(PowerMetricCard.showsChart(id: id, style: .sparkline), id)
            XCTAssertTrue(PowerMetricCard.showsChart(id: id, style: .chart), id)
            XCTAssertFalse(PowerMetricCard.showsSparkline(id: id, style: .chart), id)
        }
        XCTAssertFalse(PowerMetricCard.showsChart(id: "026", style: .chart), "Capacity retention takes no chart style.")
        XCTAssertFalse(PowerMetricCard.showsSparkline(id: "026", style: .chart))
    }
    func testCardChromeIsAppliedOnlyInChartStyle() {
        for id in ["038", "043", "054", "039"] {
            XCTAssertTrue(PowerMetricCard.showsChrome(id: id, style: .chart), id)
            XCTAssertFalse(PowerMetricCard.showsChrome(id: id, style: .sparkline), id)
        }
        XCTAssertFalse(PowerMetricCard.showsChrome(id: "026", style: .chart), "No chart, no chrome.")
        XCTAssertEqual(MetricCardChrome.cornerRadius, 12)
        XCTAssertEqual(MetricCardChrome.defaultPadding, 12)
    }
    func testChartStyleUsesDataDrivenScaleWithZeroOnlyForPower() throws {
        let values = [3.2, 4.1, 5.0]
        for id in ["038", "043", "054"] {
            let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: id, values: values), id)
            XCTAssertEqual(scale.ticks.first, 0, "Power axes are anchored at zero (\(id)).")
        }
        let temperature = try XCTUnwrap(MetricChartScale.scale(forMetric: "039", values: [31.2, 33.5, 34.0]))
        XCTAssertGreaterThan(try XCTUnwrap(temperature.ticks.first), 0, "Temperature must not force zero.")
        XCTAssertLessThanOrEqual(try XCTUnwrap(temperature.ticks.first), 31.2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(temperature.ticks.last), 34.0)
        XCTAssertNil(MetricChartScale.scale(forMetric: "038", values: []), "No data, no scale; the chart shows its empty frame.")
    }
    func testChartUnitComesFromTheReadingAndTemperatureFollowsFahrenheit() {
        XCTAssertEqual(PowerMetricCard.chartUnit(id: "038", readingUnit: "W", fahrenheit: false, language: "ru"), "Вт")
        XCTAssertEqual(PowerMetricCard.chartUnit(id: "038", readingUnit: nil, fahrenheit: false, language: "en"), "W")
        XCTAssertEqual(PowerMetricCard.chartUnit(id: "039", readingUnit: "°C", fahrenheit: false, language: "ru"), "°C")
        XCTAssertEqual(PowerMetricCard.chartUnit(id: "039", readingUnit: nil, fahrenheit: true, language: "ru"), "°F")
        XCTAssertEqual(PowerMetricCard.chartValue(20, id: "039", fahrenheit: true), 68)
        XCTAssertEqual(PowerMetricCard.chartValue(20, id: "038", fahrenheit: true), 20)
    }
    private func sample(_ index: Int, _ date: Date, value: Double?, freshness: TelemetryFreshness = .unknown, source: String = "fixture", ac: Bool = true) -> BatterySnapshot {
        let at = date.addingTimeInterval(Double(index))
        return .init(chargePercent: .init(value: 80, source: "fixture"), isExternalPower: .init(value: ac, source: "fixture"), collectedAt: at,
            catalog: [.init(definition: BatteryCatalog.definition("054"), value: value.map(CatalogValue.decimal), source: source, keyPath: "input", collectedAt: at, freshness: freshness)])
    }
}
