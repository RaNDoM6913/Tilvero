// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class OverviewPreferencesTests: XCTestCase {
    func testPreferencesPersistWithoutMutatingTelemetryOrControl() async throws {
        let suite = "TilveroOverview-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let telemetry = model.snapshot, control = model.control
        model.overviewPreferences.hidden.insert(.temperature)
        model.overviewPreferences.move(.history, by: -1)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.overviewPreferences, model.overviewPreferences)
        XCTAssertEqual(model.snapshot.chargePercent, telemetry.chargePercent)
        XCTAssertEqual(model.control?.charge, control?.charge)
        XCTAssertNil(model.nativeCharge.observed)
    }
    func testCorruptOrDuplicateOrderCannotHideOrDuplicateTheWholePanel() throws {
        XCTAssertEqual(OverviewPreferences.load(Data("bad".utf8)), .init())
        var duplicate = OverviewPreferences(); duplicate.order = [.forecast,.forecast]
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(duplicate)), .init())
    }
    func testChartStylesAreBackwardCompatibleAndDefaultToSparkline() throws {
        let old = OverviewPreferences.load(Data(#"{"order":["history","power"],"hidden":["temperature"]}"#.utf8))
        XCTAssertEqual(old.chartStyles, [:], "A saved composition without the key decodes to no overrides.")
        for metric in OverviewMetric.allCases { XCTAssertEqual(old.chartStyle(for: metric), .sparkline) }
        XCTAssertEqual(OverviewPreferences().chartStyles, [:])
        // An untouched preference set encodes exactly as before: no chartStyles key.
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(OverviewPreferences()), encoding: .utf8))
        XCTAssertFalse(encoded.contains("chartStyles"))
        // Corrupt or unknown entries cannot break the rest of the composition.
        let corrupt = OverviewPreferences.load(Data(#"{"order":["history","power"],"hidden":["temperature"],"chartStyles":{"power":"chart","temperature":"bogus","nonsense":"chart"}}"#.utf8))
        XCTAssertEqual(corrupt.chartStyles, [.power: .chart])
        XCTAssertEqual(corrupt.order.prefix(2).map(\.rawValue), ["history", "power"])
        XCTAssertTrue(corrupt.hidden.contains(.temperature))
        let wrongType = OverviewPreferences.load(Data(#"{"order":["history","power"],"chartStyles":[1,2]}"#.utf8))
        XCTAssertEqual(wrongType.chartStyles, [:])
        XCTAssertEqual(wrongType.order.prefix(2).map(\.rawValue), ["history", "power"])
    }
    func testChartStyleRoundTrips() throws {
        var preferences = OverviewPreferences()
        preferences.chartStyles = [.power: .chart, .temperature: .sparkline, .adapter: .chart]
        let data = try JSONEncoder().encode(preferences)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["chartStyles"] as? [String: String], ["power": "chart", "temperature": "sparkline", "adapter": "chart"])
        let decoded = OverviewPreferences.load(data)
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.chartStyle(for: .power), .chart)
        XCTAssertEqual(decoded.chartStyle(for: .systemPower), .sparkline)
    }
}
