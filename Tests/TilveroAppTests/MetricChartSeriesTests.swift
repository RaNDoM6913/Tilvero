// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
@testable import TilveroApp

final class MetricChartSeriesTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func point(_ offset: TimeInterval, _ value: Double, series: String = "a:0") -> HistoryChartPoint {
        HistoryChartPoint(id: UUID(), date: origin.addingTimeInterval(offset), value: value, series: series)
    }

    private func window(_ start: TimeInterval = 0, _ end: TimeInterval = 600) -> ClosedRange<Date> {
        origin.addingTimeInterval(start)...origin.addingTimeInterval(end)
    }

    func testNoPointsIsEmptyNotZero() {
        let series = MetricChartSeries.make(points: [], window: window(), now: origin.addingTimeInterval(300))
        XCTAssertEqual(series.state, .empty)
        XCTAssertTrue(series.points.isEmpty)
        XCTAssertTrue(series.gaps.isEmpty)
        XCTAssertNil(series.staleSince)
    }

    func testSeriesChangeBecomesGapNotConnectedLine() {
        let points = [
            point(0, 1, series: "a:0"), point(10, 2, series: "a:0"),
            point(100, 3, series: "a:1"), point(110, 4, series: "a:1"),
        ]
        let series = MetricChartSeries.make(points: points, window: window(), now: origin.addingTimeInterval(115))
        XCTAssertEqual(series.state, .data)
        XCTAssertEqual(series.gaps.count, 1)
        XCTAssertEqual(series.gaps.first?.start.id, points[1].id)
        XCTAssertEqual(series.gaps.first?.end.id, points[2].id)
        XCTAssertEqual(series.points.map(\.id), points.map(\.id))
        XCTAssertEqual(series.points.map(\.series), points.map(\.series))
    }

    func testLastPointOlderThanStaleAfterMarksStaleSince() {
        let points = [point(0, 1), point(10, 2)]
        let now = origin.addingTimeInterval(10 + 121)
        let stale = MetricChartSeries.make(points: points, window: window(), now: now)
        XCTAssertEqual(stale.state, .staleTail)
        XCTAssertEqual(stale.staleSince, points[1].date)
        let fresh = MetricChartSeries.make(points: points, window: window(), now: origin.addingTimeInterval(10 + 120))
        XCTAssertEqual(fresh.state, .data)
        XCTAssertNil(fresh.staleSince)
        let custom = MetricChartSeries.make(points: points, window: window(), now: now, staleAfter: 200)
        XCTAssertEqual(custom.state, .data)
    }

    func testPointsOutsideWindowAreDropped() {
        let points = [point(-50, 1), point(100, 2), point(200, 3), point(700, 4)]
        let series = MetricChartSeries.make(points: points, window: window(0, 600), now: origin.addingTimeInterval(210))
        XCTAssertEqual(series.points.map(\.value), [2, 3])
        XCTAssertEqual(series.state, .data)
        let none = MetricChartSeries.make(points: [point(-50, 1)], window: window(0, 600), now: origin.addingTimeInterval(10))
        XCTAssertEqual(none.state, .empty)
    }

    func testSinglePointIsIsolatedAndStillData() {
        let only = point(100, 5)
        let series = MetricChartSeries.make(points: [only], window: window(), now: origin.addingTimeInterval(130))
        XCTAssertEqual(series.state, .data)
        XCTAssertEqual(series.points.count, 1)
        XCTAssertEqual(series.isolatedPoints.map(\.id), [only.id])
        XCTAssertTrue(series.gaps.isEmpty)
    }
}
