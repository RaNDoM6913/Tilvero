// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import PowerCore
import PowerPersistence
import PowerTelemetry
@testable import TilveroApp

@MainActor final class PowerCardsTests: XCTestCase {
    func testNewPowerCardsAppendHiddenWithoutReplacingSavedComposition() {
        let saved = OverviewPreferences.load(Data(#"{"order":["history","power","temperature","forecast","chargeLimit","keepAwake"],"hidden":["temperature"]}"#.utf8))
        XCTAssertEqual(Array(saved.order.prefix(6)).map(\.rawValue), ["history","power","temperature","forecast","chargeLimit","keepAwake"])
        XCTAssertEqual(Array(saved.order.suffix(7)).map(\.rawValue), ["systemPower","adapter","batteryHealth","applications","keyboardBacklight","powerTiles","powerCombined"])
        XCTAssertEqual(saved.hidden.map(\.rawValue).sorted(), ["adapter","applications","batteryHealth","keyboardBacklight","powerCombined","powerTiles","systemPower","temperature"])
    }
    func testPowerTilesAppendHiddenAndKeepSavedComposition() throws {
        XCTAssertEqual(Array(OverviewMetric.allCases.suffix(2)), [.powerTiles, .powerCombined], "The tiles block keeps its place; the combined chart is appended after it.")
        XCTAssertEqual(OverviewMetric.powerTiles.title, "Power tiles")
        XCTAssertEqual(L10n.text("Power tiles"), L10n.language == "ru" ? "Мощность: тайлы" : "Power tiles")
        XCTAssertTrue(OverviewPreferences().hidden.contains(.powerTiles), "Off by default for new users too.")
        // A composition saved before the block existed: order kept, the block appended hidden and never visible.
        let saved = OverviewPreferences.load(Data(#"{"order":["history","power","forecast"],"hidden":["forecast"]}"#.utf8))
        XCTAssertEqual(Array(saved.order.prefix(3)).map(\.rawValue), ["history", "power", "forecast"])
        XCTAssertEqual(Array(saved.order.suffix(2)), [.powerTiles, .powerCombined])
        XCTAssertTrue(saved.hidden.contains(.powerTiles))
        XCTAssertFalse(saved.hidden.contains(.power), "A visible saved block stays visible.")
        // An owner who enabled it keeps it enabled across a save/load round trip.
        var enabled = saved
        enabled.hidden.remove(.powerTiles)
        let reloaded = OverviewPreferences.load(try JSONEncoder().encode(enabled))
        XCTAssertFalse(reloaded.hidden.contains(.powerTiles))
        XCTAssertEqual(reloaded.order, enabled.order)
    }
    func testTilesShowEmptyStateForMissingAdapterWithoutZero() {
        let absent = L10n.text("Adapter not connected — no reading")
        // No reading, adapter known absent: dash value, the absent message exactly once, no boundary line next to it.
        let none = PowerTilesBlock.tileLines(id: "054", reading: nil, adapterConnected: false)
        XCTAssertEqual(none.value, "—")
        XCTAssertEqual(none.captions, [absent])
        XCTAssertFalse(none.isStale)
        // A reading that is not available is a dash, never a zero, and the absent message still appears once.
        let unavailable = CatalogReading(definition: BatteryCatalog.definition("054"), value: nil, source: "fixture", keyPath: "input")
        let missing = PowerTilesBlock.tileLines(id: "054", reading: unavailable, adapterConnected: false)
        XCTAssertEqual(missing.value, "—")
        XCTAssertEqual(missing.captions, [absent])
        // Unknown external-power state (nil) is treated as connected: no "not connected" claim without evidence.
        let unknown = PowerTilesBlock.tileLines(id: "054", reading: nil, adapterConnected: true)
        XCTAssertEqual(unknown.value, "—")
        XCTAssertFalse(unknown.captions.contains(absent))
        // Connected with a reading: the value and the boundary caption.
        let live = PowerTilesBlock.tileLines(id: "054", reading: reading("054", value: 7.8, provenance: .measured), adapterConnected: true)
        XCTAssertEqual(live.captions, [L10n.text("Adapter input — a different boundary")])
        XCTAssertNotEqual(live.value, "—")
        // The battery tile carries the V×A estimate caption and the approximation prefix from the shared presentation.
        let battery = PowerTilesBlock.tileLines(id: "038", reading: reading("038", value: -10, provenance: .estimated), adapterConnected: false)
        XCTAssertTrue(battery.value.hasPrefix("≈ "), battery.value)
        XCTAssertEqual(battery.captions, [L10n.text("battery · V×A estimate")], "Battery tile never shows the adapter message.")
        XCTAssertEqual(PowerTilesBlock.tileLines(id: "038", reading: nil, adapterConnected: false).value, "—")
        // The empty chart of that tile is the dashed frame (no scale, no axis), not a flat zero line.
        let window = Date(timeIntervalSince1970: 1_800_000_000)...Date(timeIntervalSince1970: 1_800_003_600)
        let empty = MetricChartSeriesSpec(id: "054", series: .make(points: [], window: window, now: window.upperBound), color: .blue, endLabel: nil)
        let layout = MetricChartView.layout(specs: [empty], scale: MetricChartScale.scale(forMetric: "054", values: []), density: .compact)
        XCTAssertTrue(layout.isDashedEmpty)
        XCTAssertEqual(layout.valueTickCount, 0)
    }
    // MARK: Variant C - one combined chart

    private let combinedWindow = Date(timeIntervalSince1970: 1_800_000_000)...Date(timeIntervalSince1970: 1_800_003_600)
    private func combinedSeries(_ values: [Double]) -> MetricChartSeries {
        let step = 3600.0 / Double(values.count)
        let points = values.enumerated().map {
            HistoryChartPoint(id: UUID(), date: combinedWindow.lowerBound.addingTimeInterval(step * Double($0.offset + 1) - 1), value: $0.element, series: "s")
        }
        return .make(points: points, window: combinedWindow, now: combinedWindow.upperBound)
    }
    func testCombinedScaleComesFromUnionOfBothSeries() {
        let battery = combinedSeries([-12, -10, -9])
        let adapter = combinedSeries([30, 35, 38])
        let union = MetricChartScale.scale(forMetric: "038", values: [-12, -10, -9, 30, 35, 38])
        let combined = PowerCombinedBlock.combinedScale(battery: battery, adapter: adapter)
        XCTAssertEqual(combined, union)
        let batteryOnly = MetricChartScale.scale(forMetric: "038", values: [-12, -10, -9])
        XCTAssertNotEqual(combined, batteryOnly, "The adapter values widen the shared axis.")
        XCTAssertTrue(try XCTUnwrap(combined).domain.contains(38))
        XCTAssertTrue(try XCTUnwrap(combined).domain.contains(-12))
        XCTAssertTrue(try XCTUnwrap(combined).domain.contains(0), "Power axes always include zero.")
        // Without an adapter series the scale is the battery's own (never padded by a phantom zero line).
        XCTAssertEqual(PowerCombinedBlock.combinedScale(battery: battery, adapter: nil), batteryOnly)
    }
    func testEndLabelsNeverOverlap() {
        // Last values 0.5 W apart on a 0...30 W axis: 120 pt plot, so the raw label centres are 2 pt apart.
        let battery = combinedSeries([13.0, 13.9]), adapter = combinedSeries([17.5, 14.4])
        let scale = PowerCombinedBlock.combinedScale(battery: battery, adapter: adapter)
        let content = PowerCombinedBlock.content(battery: reading("038", value: 13.9, provenance: .estimated),
                                                 adapter: reading("054", value: 14.4, provenance: .measured), adapterConnected: true)
        let specs = PowerCombinedBlock.specs(content: content, battery: battery, adapter: adapter)
        XCTAssertEqual(specs.count, 2)
        let ys = MetricChartView.endLabelPositions(specs: specs, scale: try! XCTUnwrap(scale), plotHeight: 120, minGap: 14)
        let placed = ys.compactMap { $0 }
        XCTAssertEqual(placed.count, 2)
        XCTAssertGreaterThanOrEqual(abs(placed[0] - placed[1]), 12)
        XCTAssertTrue(placed.allSatisfy { $0 >= 0 && $0 <= 120 }, "Labels stay inside the plot.")
        // The same on the compact plot height, and for identical last values.
        let tight = MetricChartView.endLabelPositions(specs: specs, scale: try! XCTUnwrap(scale), plotHeight: 70, minGap: 14).compactMap { $0 }
        XCTAssertGreaterThanOrEqual(abs(tight[0] - tight[1]), 12)
        let same = [combinedSeries([5.0]), combinedSeries([5.0])]
        let sameSpecs = zip(["a", "b"], same).map { MetricChartSeriesSpec(id: $0, series: $1, color: .blue, endLabel: $0) }
        let sameYs = MetricChartView.endLabelPositions(specs: sameSpecs, scale: try! XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: [5])), plotHeight: 120, minGap: 14).compactMap { $0 }
        XCTAssertGreaterThanOrEqual(abs(sameYs[0] - sameYs[1]), 12)
    }
    func testEndLabelsReadAsTitleAndNumberFromTheSharedPresentation() {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let content = PowerCombinedBlock.content(battery: reading("038", value: -10.4, provenance: .estimated),
                                                 adapter: reading("054", value: 38.2, provenance: .measured), adapterConnected: true)
        // Number formatting is the shared presentation's (locale decimal comma, no unit, no approximation prefix).
        XCTAssertEqual(content.batteryLabel, "Батарея -10,4")
        XCTAssertEqual(content.adapterLabel, "Адаптер 38,2")
        XCTAssertEqual(content.title, "Мощность")
        XCTAssertEqual(content.caption, "батарея: оценка V×A, знак: + в батарею · адаптер: вход, другая граница")
        // A measured battery reading does not claim an estimate.
        let measured = PowerCombinedBlock.content(battery: reading("038", value: -10, provenance: .measured), adapter: nil, adapterConnected: true)
        XCTAssertFalse(measured.caption.contains("V×A"))
        XCTAssertTrue(measured.caption.contains("адаптер"))
    }
    func testAdapterMissingDrawsOnlyBatteryLineAndOneMessage() {
        let battery = combinedSeries([-10, -9.5, -10.4]), adapter = combinedSeries([5, 6, 7])
        let absent = L10n.text("Adapter not connected — no adapter line")
        XCTAssertEqual(absent, L10n.language == "ru" ? "Адаптер не подключён — линии адаптера нет" : "Adapter not connected — no adapter line")
        for adapterReading in [nil, reading("054", value: nil, provenance: .measured)] {
            let content = PowerCombinedBlock.content(battery: reading("038", value: -10.4, provenance: .estimated), adapter: adapterReading, adapterConnected: false)
            XCTAssertEqual(content.absentMessage, absent, "The message appears exactly once.")
            XCTAssertNil(content.adapterLabel)
            XCTAssertFalse(content.caption.contains(absent))
            // Even if the history still holds earlier adapter samples, an unplugged adapter draws no line and does not widen the axis.
            let specs = PowerCombinedBlock.specs(content: content, battery: battery, adapter: adapter)
            XCTAssertEqual(specs.map(\.id), ["038"], "Only the battery series is drawn, never a zero adapter line.")
            XCTAssertEqual(PowerCombinedBlock.combinedScale(battery: battery, adapter: content.drawsAdapter ? adapter : nil),
                           MetricChartScale.scale(forMetric: "038", values: [-10, -9.5, -10.4]))
        }
        // Unknown external-power state counts as connected: both lines, no "not connected" claim.
        let unknown = PowerCombinedBlock.content(battery: reading("038", value: -10.4, provenance: .estimated), adapter: nil, adapterConnected: true)
        XCTAssertNil(unknown.absentMessage)
        XCTAssertEqual(PowerCombinedBlock.specs(content: unknown, battery: battery, adapter: adapter).map(\.id), ["038", "054"])
        // No battery reading: the missing-reading caption, never a zero.
        let nothing = PowerCombinedBlock.content(battery: nil, adapter: nil, adapterConnected: true)
        XCTAssertEqual(nothing.caption, L10n.text("no reading from macOS"))
        XCTAssertNil(nothing.batteryLabel)
    }
    func testNoLegendIsRendered() {
        let battery = combinedSeries([-10, -9, -10]), adapter = combinedSeries([30, 31, 32])
        let content = PowerCombinedBlock.content(battery: reading("038", value: -10, provenance: .estimated),
                                                 adapter: reading("054", value: 32, provenance: .measured), adapterConnected: true)
        let specs = PowerCombinedBlock.specs(content: content, battery: battery, adapter: adapter)
        let layout = MetricChartView.layout(specs: specs, scale: PowerCombinedBlock.combinedScale(battery: battery, adapter: adapter), density: .full)
        XCTAssertEqual(specs.count, 2)
        XCTAssertFalse(layout.hasLegend)
        XCTAssertFalse(layout.isDashedEmpty)
        XCTAssertTrue(specs.allSatisfy { $0.endLabel != nil }, "Lines are named by end labels instead.")
    }
    func testCombinedStringsHaveRuAndEn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        for key in MetricCaption.combinedKeys + [OverviewMetric.powerCombined.title, "Power"] {
            let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: [String: Any]], key)
            for language in ["en", "ru"] {
                let unit = localizations[language]?["stringUnit"] as? [String: String] ?? [:]
                XCTAssertEqual(unit["state"], "translated", "\(key) \(language)")
                XCTAssertFalse((unit["value"] ?? "").isEmpty, "\(key) \(language)")
            }
        }
        XCTAssertEqual(OverviewMetric.powerCombined.title, "Power: combined chart")
    }
    func testCombinedChartRendersTwoRealLinesInLightAndDark() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let connected = try await renderModel(minutesOfHistory: 55, adapterConnected: true)
        defer { connected.cleanup() }
        let discharge = try await renderModel(minutesOfHistory: 55, adapterConnected: false)
        defer { discharge.cleanup() }
        for scheme in [ColorScheme.light, .dark] {
            let two = try renderBlock(PowerCombinedBlock(model: connected.model), width: 320, scheme: scheme, label: "combined-connected")
            XCTAssertGreaterThan(two.orange, 100, "Battery line is drawn (\(scheme)).")
            XCTAssertGreaterThan(two.blue, 100, "Adapter line is drawn (\(scheme)).")
            let one = try renderBlock(PowerCombinedBlock(model: discharge.model), width: 320, scheme: scheme, label: "combined-discharge")
            XCTAssertGreaterThan(one.orange, 100)
            XCTAssertEqual(one.blue, 0, "No adapter line while unplugged (\(scheme)).")
            XCTAssertEqual(two.size.width, 320)
        }
    }
    /// 360 pt popover minus the panel's 2 x 20 pt padding, two tiles and the gap between them.
    private var tileWidth: CGFloat { (360 - 40 - PowerTilesBlock.spacing) / 2 }
    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    func testTileTextFitsAt360InRussian() async throws {
        // Volatile argument domain only: nothing is written to disk, and the saved domain is restored on exit.
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        XCTAssertEqual(L10n.language, "ru")
        let inner = tileWidth - 2 * 10 - 1   // tile chrome padding 10 pt, hairline
        XCTAssertEqual(tileWidth, 156)
        let estimated = reading("038", value: -100.5, provenance: .estimated)
        let stale = CatalogReading(definition: BatteryCatalog.definition("054"), value: .decimal(7.8), source: "fixture", keyPath: "input", freshness: .stale)
        let tiles = [
            PowerTilesBlock.tileLines(id: "038", reading: estimated, adapterConnected: true),
            PowerTilesBlock.tileLines(id: "054", reading: nil, adapterConnected: false),
            PowerTilesBlock.tileLines(id: "054", reading: stale, adapterConnected: true),
        ]
        XCTAssertEqual(tiles[0].title, "Батарея")
        XCTAssertEqual(tiles[1].title, "Адаптер")
        for tile in tiles {
            // Title row (title + optional "Устарело" tag) and the value are single-line; they must fit the inner width.
            let tag = tile.isStale ? 4 + width(L10n.text("Stale"), size: 10) : 0
            XCTAssertLessThanOrEqual(width(tile.title, size: 11) + tag, inner, "title row of \(tile.title)")
            XCTAssertLessThanOrEqual(width(tile.value, size: 15, weight: .semibold), inner, "value \(tile.value)")
            // Captions may wrap, but never inside a word.
            XCTAssertLessThanOrEqual(tile.captions.count, 1)
            for caption in tile.captions {
                for word in caption.split(separator: " ") { XCTAssertLessThanOrEqual(width(String(word), size: 10), inner, "word \(word)") }
            }
        }
        XCTAssertTrue(tiles[2].isStale)
        // The rendered block is not blank and is exactly the offered width, with two tiles filling the row.
        let model = try await renderModel(minutesOfHistory: 60, adapterConnected: false)
        defer { model.cleanup() }
        for scheme in [ColorScheme.light, .dark] {
            let size = try renderTiles(model.model, width: 320, scheme: scheme)
            XCTAssertEqual(size.width, 320)
            XCTAssertGreaterThan(size.height, 70 + 40, "A tile is a title, a value and a 70 pt plot.")
            XCTAssertLessThan(size.height, 260)
        }
    }
    private func renderTiles(_ model: TilveroModel, width: CGFloat, scheme: ColorScheme, label: String = "tiles") throws -> CGSize {
        try renderBlock(PowerTilesBlock(model: model), width: width, scheme: scheme, label: label).size
    }
    /// Renders a block offscreen; returns its size and how many sampled pixels are saturated orange / blue (the two chart lines).
    private func renderBlock<V: View>(_ block: V, width: CGFloat, scheme: ColorScheme, label: String) throws -> (size: CGSize, orange: Int, blue: Int) {
        let view = block.frame(width: width)
            .background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var colors = Set<UInt32>()
        var orange = 0, blue = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if x % 2 == 0 && y % 2 == 0 {
                    colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
                if c.saturationComponent > 0.6, c.brightnessComponent > 0.5 {
                    if (0.04...0.13).contains(c.hueComponent) { orange += 1 }
                    if (0.55...0.67).contains(c.hueComponent) { blue += 1 }
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 2, "The bitmap must not be blank.")
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder + "/\(label)-\(scheme == .dark ? "dark" : "light").png"))
        }
        return (CGSize(width: image.width, height: image.height), orange, blue)
    }
    /// A model whose history holds `minutesOfHistory` of battery-power samples (adapter samples only when connected).
    private func renderModel(minutesOfHistory: Int, adapterConnected: Bool) async throws -> (model: TilveroModel, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TilveroTiles-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        func snapshot(_ minutesAgo: Double) -> BatterySnapshot {
            let at = now.addingTimeInterval(-minutesAgo * 60)
            var catalog = [CatalogReading(definition: BatteryCatalog.definition("038"), value: .decimal(-10 + 2 * sin(minutesAgo / 6)), source: "fixture",
                                          keyPath: "Voltage×Amperage", collectedAt: at, provenance: .estimated)]
            if adapterConnected {
                catalog.append(CatalogReading(definition: BatteryCatalog.definition("054"), value: .decimal(7.5 + sin(minutesAgo / 9)), source: "fixture",
                                              keyPath: "SystemPowerIn", collectedAt: at, provenance: .measured))
            }
            return BatterySnapshot(chargePercent: .init(value: 62, source: "fixture"), isExternalPower: .init(value: adapterConnected, source: "fixture"),
                                   collectedAt: at, catalog: catalog)
        }
        let store = try BatteryHistoryStore(url: url)
        for minute in stride(from: Double(minutesOfHistory), to: 0, by: -1) { try store.record(snapshot(minute)) }
        try store.close()
        let latest = snapshot(0)
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { latest })
        await model.refresh()
        return (model, { model.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) })
    }
    func testTilesRenderRealSeriesAndEmptyStatesInLightAndDark() async throws {
        let withData = try await renderModel(minutesOfHistory: 55, adapterConnected: true)
        defer { withData.cleanup() }
        XCTAssertFalse(withData.model.metricSeries(id: "038").points.isEmpty, "The injected history reaches the series.")
        XCTAssertFalse(withData.model.metricSeries(id: "054").points.isEmpty)
        let discharge = try await renderModel(minutesOfHistory: 55, adapterConnected: false)
        defer { discharge.cleanup() }
        XCTAssertFalse(discharge.model.metricSeries(id: "038").points.isEmpty)
        XCTAssertTrue(discharge.model.metricSeries(id: "054").points.isEmpty, "No adapter samples while unplugged.")
        for scheme in [ColorScheme.light, .dark] {
            _ = try renderTiles(withData.model, width: 320, scheme: scheme, label: "tiles-connected")
            _ = try renderTiles(discharge.model, width: 320, scheme: scheme, label: "tiles-discharge")
        }
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
