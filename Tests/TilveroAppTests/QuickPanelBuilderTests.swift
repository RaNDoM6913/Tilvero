// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
@testable import TilveroApp

@MainActor final class QuickPanelBuilderTests: XCTestCase {
    func testLegacyLayoutKeepsOrderAndHiddenWhileNewBlocksStayOptional() throws {
        let data = Data(#"{"order":["history","temperature","forecast","power"],"hidden":["forecast"]}"#.utf8)
        let value = OverviewPreferences.load(data)
        XCTAssertEqual(value.order.map(\.rawValue), ["history","temperature","forecast","power","keepAwake","systemPower","adapter","batteryHealth","applications","keyboardBacklight","powerTiles","powerCombined"])
        XCTAssertEqual(value.hidden, [.forecast,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications,.keyboardBacklight,.powerTiles,.powerCombined])
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(value)), value)
    }
    func testUnknownAndDuplicateIDsDoNotResetKnownComposition() {
        let value = OverviewPreferences.load(Data(#"{"order":["temperature","future","temperature","history","power","forecast"],"hidden":["power","future"]}"#.utf8))
        XCTAssertEqual(value.order.map(\.rawValue), ["temperature","history","power","forecast","keepAwake","systemPower","adapter","batteryHealth","applications","keyboardBacklight","powerTiles","powerCombined"])
        XCTAssertEqual(value.hidden, [.power,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications,.keyboardBacklight,.powerTiles,.powerCombined])
    }
    func testAcceptedLocalDropMovesHiddenRowsBothDirectionsAndRejectsForeignPayload() {
        var value = OverviewPreferences()
        value.hidden.insert(.power)
        let first = OverviewDragSession(source: .forecast)
        XCTAssertFalse(value.acceptDrop("forecast", session: first, onto: .history))
        XCTAssertEqual(value.order.first, .forecast)
        XCTAssertTrue(value.acceptDrop(first.payload, session: first, onto: .history))
        XCTAssertEqual(Array(value.order.prefix(4)), [.power,.temperature,.history,.forecast])
        let second = OverviewDragSession(source: .forecast)
        XCTAssertFalse(value.acceptDrop(first.payload, session: second, onto: .power))
        XCTAssertTrue(value.acceptDrop(second.payload, session: second, onto: .power))
        XCTAssertEqual(Array(value.order.prefix(4)), [.forecast,.power,.temperature,.history])
        XCTAssertFalse(value.acceptDrop(second.payload, session: second, onto: .forecast))
        XCTAssertTrue(value.hidden.contains(.power))
    }
    func testCancelledOrCompletedSourceCannotAuthorizeAReplayedExternalDrop() {
        var lifetime = OverviewDragState(), preferences = OverviewPreferences()
        let original = preferences
        let cancelled = lifetime.begin(.forecast)
        lifetime.end()
        XCTAssertNil(lifetime.prepareDrop())
        XCTAssertFalse(lifetime.completeDrop(cancelled.payload, session: cancelled, onto: .history, preferences: &preferences))
        XCTAssertEqual(preferences, original)
        let accepted = lifetime.begin(.forecast)
        XCTAssertEqual(lifetime.prepareDrop()?.payload, accepted.payload)
        lifetime.end() // Native source-end precedes asynchronous provider completion.
        XCTAssertTrue(lifetime.completeDrop(accepted.payload, session: accepted, onto: .history, preferences: &preferences))
        XCTAssertEqual(preferences.order.first, .power)
        XCTAssertFalse(lifetime.completeDrop(accepted.payload, session: accepted, onto: .power, preferences: &preferences))
        let stale = lifetime.begin(.power)
        _ = lifetime.prepareDrop()
        _ = lifetime.begin(.history) // A new source invalidates an old pending callback.
        XCTAssertFalse(lifetime.completeDrop(stale.payload, session: stale, onto: .forecast, preferences: &preferences))
        lifetime.end()
    }
    func testPassivePreviewAndBuilderPersistWithoutApplyingActions() async throws {
        let suite = "TilveroBuilder-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let original = model.control?.charge
        model.overviewPreferences.move(.history, by: -1)
        model.overviewPreferences.hidden.insert(.temperature)
        let host = NSHostingController(rootView: QuickPanelBuilder(model: model))
        _ = host.sizeThatFits(in: NSSize(width: 720, height: 1200))
        XCTAssertEqual(model.control?.charge, original)
        XCTAssertNil(model.nativeCharge.observed)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.overviewPreferences, model.overviewPreferences)
    }

    func testBuilderListsNewBlocksAndStylePickerWritesPreferences() throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let suite = "TilveroBuilderStyle-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        // The new blocks are rows of the existing ForEach and carry a title and a symbol.
        for block in [OverviewMetric.powerTiles, .powerCombined] {
            XCTAssertTrue(model.overviewPreferences.order.contains(block))
            XCTAssertFalse(L10n.text(block.title).isEmpty)
            XCTAssertNotEqual(L10n.text(block.title), block.title, "\(block) has a Russian title.")
            XCTAssertFalse(block.symbol.isEmpty)
            XCTAssertFalse(QuickPanelBuilder.showsChartStylePicker(for: block), "\(block) takes no style control.")
        }
        XCTAssertEqual(OverviewMetric.allCases.filter(QuickPanelBuilder.showsChartStylePicker(for:)), [.power, .temperature, .systemPower, .adapter])
        XCTAssertEqual(L10n.text("Sparkline"), "Линия")
        XCTAssertEqual(L10n.text("Chart"), "График")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let untouched = try encoder.encode(model.overviewPreferences)
        let binding = QuickPanelBuilder.chartStyleBinding(.temperature, model: model)
        XCTAssertEqual(binding.wrappedValue, .sparkline)
        binding.wrappedValue = .chart
        XCTAssertEqual(model.overviewPreferences.chartStyles, [.temperature: .chart])
        XCTAssertEqual(QuickPanelBuilder.chartStyleBinding(.temperature, model: model).wrappedValue, .chart)
        XCTAssertEqual(TilveroModel(isDemo: true, preferences: preferences).overviewPreferences.chartStyles, [.temperature: .chart], "The choice persists.")
        binding.wrappedValue = .sparkline
        XCTAssertTrue(model.overviewPreferences.chartStyles.isEmpty, "Sparkline removes the key.")
        XCTAssertEqual(try encoder.encode(model.overviewPreferences), untouched, "Untouched preferences stay byte-identical.")
    }

    func testRestoreLayoutDefaultsClearsChartStyles() {
        let suite = "TilveroBuilderReset-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        model.overviewPreferences.chartStyles = [.power: .chart, .adapter: .chart]
        model.overviewPreferences.move(.history, by: -1)
        model.overviewPreferences.hidden.remove(.powerTiles)
        QuickPanelBuilder.restoreLayoutDefaults(model)
        XCTAssertEqual(model.overviewPreferences, OverviewPreferences())
        XCTAssertTrue(model.overviewPreferences.chartStyles.isEmpty)
        XCTAssertEqual(model.overviewPreferences.chartStyle(for: .power), .sparkline)
    }

    // MARK: Preview rendering

    private struct PreviewRender {
        let bitmap: NSBitmapImageRep
        /// Sampled pixels in the saturated orange (battery line) and blue (adapter line) hue bands.
        let orange: Int
        let blue: Int
    }
    private func renderPreview(_ model: TilveroModel, layout: OverviewPreferences, scheme: ColorScheme) throws -> PreviewRender {
        model.overviewPreferences = layout
        let host = NSHostingController(rootView: PassiveQuickPanelPreview(model: model, section: .overview)
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { window.close() }
        let size = host.sizeThatFits(in: NSSize(width: 360, height: 8000))
        XCTAssertTrue(size.width.isFinite && size.height.isFinite)
        window.setContentSize(size)
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        var orange = 0, blue = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.saturationComponent > 0.6, c.brightnessComponent > 0.5 else { continue }
                if (0.04...0.13).contains(c.hueComponent) { orange += 1 }
                if (0.55...0.67).contains(c.hueComponent) { blue += 1 }
            }
        }
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let name = layout.hidden.count == OverviewMetric.allCases.count ? "none" : "\(layout.chartStyles.isEmpty ? "plain" : "styled")-\(OverviewMetric.allCases.filter { !layout.hidden.contains($0) }.map(\.rawValue).joined(separator: "+"))"
            try png.write(to: URL(fileURLWithPath: folder + "/preview-\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
        return PreviewRender(bitmap: bitmap, orange: orange, blue: blue)
    }
    private func layout(showing visible: Set<OverviewMetric>, chartStyle: MetricChartStyle = .sparkline) -> OverviewPreferences {
        var layout = OverviewPreferences()
        layout.hidden = Set(OverviewMetric.allCases).subtracting(visible)
        if chartStyle == .chart { layout.chartStyles = Dictionary(uniqueKeysWithValues: OverviewMetric.allCases.filter(\.supportsChartStyle).map { ($0, MetricChartStyle.chart) }) }
        return layout
    }

    func testPreviewRendersEveryVariant() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        XCTAssertFalse(model.metricSeries(id: "038").points.isEmpty, "The injected history reaches the series.")
        XCTAssertFalse(model.metricSeries(id: "054").points.isEmpty)
        let everything = Set(OverviewMetric.allCases)
        for scheme in [ColorScheme.light, .dark] {
            let tag = "(\(scheme))"
            // (c) With every chart block hidden no series-coloured pixel is drawn: the hue counts measure the charts, not the chrome.
            let none = try renderPreview(model, layout: layout(showing: []), scheme: scheme)
            XCTAssertEqual(none.orange, 0, "No battery-coloured pixels without charts \(tag).")
            XCTAssertEqual(none.blue, 0, "No adapter-coloured pixels without charts \(tag).")
            // Sparkline default draws the battery sparkline and the adapter sparkline.
            let sparkline = try renderPreview(model, layout: layout(showing: [.power, .adapter]), scheme: scheme)
            XCTAssertGreaterThan(sparkline.orange, 20, "Battery sparkline \(tag).")
            XCTAssertGreaterThan(sparkline.blue, 20, "Adapter sparkline \(tag).")
            // Variant A: the same cards as full charts are taller and still draw both lines.
            let chart = try renderPreview(model, layout: layout(showing: [.power, .adapter], chartStyle: .chart), scheme: scheme)
            XCTAssertGreaterThan(chart.bitmap.pixelsHigh, sparkline.bitmap.pixelsHigh, "Chart cards are taller than sparklines \(tag).")
            XCTAssertGreaterThan(chart.orange, 20, "Battery chart line \(tag).")
            XCTAssertGreaterThan(chart.blue, 20, "Adapter chart line \(tag).")
            // Variants B and C, each alone, draw both series (the tiles' two charts, the combined chart's two lines).
            let tiles = try renderPreview(model, layout: layout(showing: [.powerTiles]), scheme: scheme)
            XCTAssertGreaterThan(tiles.orange, 20, "Tiles battery line \(tag).")
            XCTAssertGreaterThan(tiles.blue, 20, "Tiles adapter line \(tag).")
            let combined = try renderPreview(model, layout: layout(showing: [.powerCombined]), scheme: scheme)
            XCTAssertGreaterThan(combined.orange, 20, "Combined battery line \(tag).")
            XCTAssertGreaterThan(combined.blue, 20, "Combined adapter line \(tag).")
            // (a) All variants on at once differ from the sparkline-only layout.
            let all = try renderPreview(model, layout: layout(showing: everything, chartStyle: .chart), scheme: scheme)
            let plain = try renderPreview(model, layout: layout(showing: everything.subtracting([.powerTiles, .powerCombined])), scheme: scheme)
            XCTAssertGreaterThan(all.bitmap.pixelsHigh, plain.bitmap.pixelsHigh + 400, "Charts, tiles and combined block add height \(tag).")
            XCTAssertGreaterThan(all.orange, plain.orange, "More battery-line pixels with every variant \(tag).")
            XCTAssertGreaterThan(all.blue, plain.blue, "More adapter-line pixels with every variant \(tag).")
        }
    }

    func testTilesDoNotGrowToTheHeightAContainerOffers() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let host = NSHostingController(rootView: PowerTilesBlock(model: fixture.model).frame(width: 320))
        let size = host.sizeThatFits(in: NSSize(width: 320, height: 8000))
        XCTAssertLessThan(size.height, 300, "Equal-height tiles stretch to each other, not to the offered height.")
        // Both tiles' cards span the same rows (battery has no boundary caption, adapter wraps one: heights would differ unstretched).
        let renderer = ImageRenderer(content: PowerTilesBlock(model: fixture.model).frame(width: 320).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func extent(column x: Int) -> ClosedRange<Int>? {
            let rows = (0..<bitmap.pixelsHigh).filter {
                guard let c = bitmap.colorAt(x: x, y: $0)?.usingColorSpace(.sRGB) else { return false }
                return c.redComponent < 0.995 || c.greenComponent < 0.995 || c.blueComponent < 0.995
            }
            return rows.first.flatMap { first in rows.last.map { first...$0 } }
        }
        let tileWidth = (320 - PowerTilesBlock.spacing) / 2
        let left = try XCTUnwrap(extent(column: Int(tileWidth / 4)), "Left tile card drawn.")
        let right = try XCTUnwrap(extent(column: Int(tileWidth + PowerTilesBlock.spacing + tileWidth / 4)), "Right tile card drawn.")
        XCTAssertEqual(left.lowerBound, right.lowerBound, accuracy: 1)
        XCTAssertEqual(left.upperBound, right.upperBound, accuracy: 1, "Both tiles share one height.")
        XCTAssertGreaterThan(left.count, 100)
    }
}
