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
    func testChartMetricsAlwaysDrawChartsAndLegacyStylesAreIgnored() throws {
        let old = OverviewPreferences.load(Data(#"{"order":["history","power"],"hidden":["temperature"],"chartStyles":{"power":"sparkline","nonsense":"x"}}"#.utf8))
        for metric in OverviewMetric.allCases {
            XCTAssertEqual(old.chartStyle(for: metric), metric.supportsChartStyle ? .chart : .sparkline)
        }
        XCTAssertEqual(old.order.prefix(2).map(\.rawValue), ["history", "power"])
        XCTAssertTrue(old.hidden.contains(.temperature))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(encoded.contains("chartStyles"), "The legacy key is dropped on the next save.")
        let wrongType = OverviewPreferences.load(Data(#"{"order":["history","power"],"chartStyles":[1,2]}"#.utf8))
        XCTAssertEqual(wrongType.order.prefix(2).map(\.rawValue), ["history", "power"])
    }
}
