// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class MetricChartSizeTests: XCTestCase {
    func testTheModerateSizeIsTheDefaultAndStaysUnwritten() throws {
        let value = OverviewPreferences()
        XCTAssertEqual(value.chartSize, .moderate)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("chartSize"), "an untouched preference file does not change")
        XCTAssertEqual(OverviewPreferences.load(Data(#"{"order":["history"],"hidden":[]}"#.utf8)).chartSize, .moderate, "a layout saved before the setting")
    }

    func testAChosenSizeRoundTripsAndABadOneFallsBackWithoutLosingTheLayout() throws {
        var value = OverviewPreferences()
        value.chartSize = .regular
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(value)), value)
        let bad = OverviewPreferences.load(Data(#"{"order":["temperature","history"],"hidden":["power"],"chartSize":"huge"}"#.utf8))
        XCTAssertEqual(bad.chartSize, .moderate)
        XCTAssertEqual(bad.order.prefix(2).map(\.rawValue), ["temperature", "history"])
        XCTAssertTrue(bad.hidden.contains(.power))
    }

    func testPlotHeightsAndTimeLabelsFollowTheSize() {
        XCTAssertEqual(MetricChartSize.regular.density.plotHeight, 120)
        XCTAssertEqual(MetricChartSize.moderate.density.plotHeight, 80)
        XCTAssertEqual(MetricChartSize.strip.density.plotHeight, 40)
        XCTAssertEqual([MetricChartSize.regular, .moderate, .strip].map { $0.density.timeTickCount }, [5, 3, 2])
        XCTAssertLessThanOrEqual(80.0 / 120.0, 0.67, "the moderate chart is about a third shorter")
    }

    func testAStripLabelsOnlyTheEndsOfItsValueAxis() {
        XCTAssertEqual(MetricChartView.labelledTickIndices(count: 5, density: .strip), [0, 4])
        XCTAssertEqual(MetricChartView.labelledTickIndices(count: 5, density: .moderate), [0, 1, 2, 3, 4])
    }

    func testRestoringLayoutDefaultsResetsTheSizeToo() {
        var value = OverviewPreferences(); value.chartSize = .strip
        value = OverviewPreferences()
        XCTAssertEqual(value.chartSize, .moderate)
    }
}
