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
        XCTAssertEqual(value.order.map(\.rawValue), ["history","temperature","forecast","power","chargeLimit","keepAwake","systemPower","adapter","batteryHealth","applications","keyboardBacklight","powerTiles","powerCombined"])
        XCTAssertEqual(value.hidden, [.forecast,.chargeLimit,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications,.keyboardBacklight,.powerTiles,.powerCombined])
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(value)), value)
    }
    func testUnknownAndDuplicateIDsDoNotResetKnownComposition() {
        let value = OverviewPreferences.load(Data(#"{"order":["temperature","future","temperature","history","power","forecast"],"hidden":["power","future"]}"#.utf8))
        XCTAssertEqual(value.order.map(\.rawValue), ["temperature","history","power","forecast","chargeLimit","keepAwake","systemPower","adapter","batteryHealth","applications","keyboardBacklight","powerTiles","powerCombined"])
        XCTAssertEqual(value.hidden, [.power,.chargeLimit,.keepAwake,.systemPower,.adapter,.batteryHealth,.applications,.keyboardBacklight,.powerTiles,.powerCombined])
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

    func testPreviewRendersEveryVariant() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        var layout = OverviewPreferences()
        layout.hidden = []
        layout.chartStyles = [.power: .chart, .temperature: .chart, .systemPower: .chart, .adapter: .chart]
        model.overviewPreferences = layout
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: PassiveQuickPanelPreview(model: model, section: .overview))
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: scheme)
            let size = host.sizeThatFits(in: NSSize(width: 360, height: 6000))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertGreaterThan(size.height, 800, "Every block, charts included, takes room.")
            window.setContentSize(size)
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            var colors = Set<UInt32>()
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
            XCTAssertGreaterThan(colors.count, 20, "The preview bitmap must not be blank (\(scheme.rawValue)).")
            if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: folder + "/preview-all-variants-\(scheme == .darkAqua ? "dark" : "light").png"))
            }
        }
    }

    func testTilesDoNotGrowToTheHeightAContainerOffers() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let host = NSHostingController(rootView: PowerTilesBlock(model: fixture.model).frame(width: 320))
        let size = host.sizeThatFits(in: NSSize(width: 320, height: 8000))
        XCTAssertLessThan(size.height, 300, "Equal-height tiles stretch to each other, not to the offered height.")
    }
}
