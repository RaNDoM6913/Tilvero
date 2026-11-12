// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerTelemetry
@testable import TilveroApp

final class LiveMetricTailTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ offset: TimeInterval, system: Double? = 7, adapter: Double? = 7.5, temperature: Double? = 33) -> LivePowerSample {
        LivePowerSample(collectedAt: t0.addingTimeInterval(offset), systemWatts: system, adapterWatts: adapter, temperatureCelsius: temperature)
    }
    private func point(_ offset: TimeInterval, _ value: Double, _ series: String) -> HistoryChartPoint {
        HistoryChartPoint(id: UUID(), date: t0.addingTimeInterval(offset), value: value, series: series)
    }

    func testTailFeedsTheFourMetricsFromOneSample() {
        var tail = LiveMetricTail()
        tail.append(sample(0))
        XCTAssertEqual(tail.points(id: "043").first?.value, 7)
        XCTAssertEqual(tail.points(id: "054").first?.value, 7.5)
        XCTAssertEqual(tail.points(id: "038").first?.value ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tail.points(id: "039").first?.value, 33)
        XCTAssertTrue(tail.points(id: "001").isEmpty)
    }
    func testMissingChannelsLeaveNoPointNeverAZero() {
        var tail = LiveMetricTail()
        tail.append(sample(0, system: nil, adapter: nil))
        XCTAssertTrue(tail.points(id: "043").isEmpty); XCTAssertTrue(tail.points(id: "038").isEmpty)
        XCTAssertEqual(tail.points(id: "039").count, 1)
    }
    func testConsecutiveSecondsShareASegmentAndAPauseStartsANewOne() {
        var tail = LiveMetricTail()
        for i in 0..<5 { tail.append(sample(TimeInterval(i))) }
        tail.append(sample(60))
        let series = tail.points(id: "043").map(\.series)
        XCTAssertEqual(Set(series.prefix(5)).count, 1)
        XCTAssertNotEqual(series[4], series[5])
    }
    func testOnlyTheLastTenMinutesAreKept() {
        var tail = LiveMetricTail()
        for i in stride(from: 0, through: 900, by: 1) { tail.append(sample(TimeInterval(i))) }
        let points = tail.points(id: "043")
        XCTAssertLessThanOrEqual(points.count, 601)
        XCTAssertGreaterThanOrEqual(points.first!.date, t0.addingTimeInterval(300))
    }

    func testMergeReplacesRecordedPointsOnlyWhereLiveCoversThem() {
        let persisted = (0..<10).map { point(TimeInterval($0 * 60), 5, "a") }                  // minutes 0...9
        let live = (0..<30).map { point(540 + TimeInterval($0), 9, "live:1") }                 // 540...569 s
        let merged = LiveChartMerge.merge(persisted: persisted, live: live)
        XCTAssertEqual(merged.filter { $0.value == 9 }.count, 30)
        XCTAssertFalse(merged.contains { $0.value == 5 && $0.date == t0.addingTimeInterval(540) }, "The recorded point under the live segment is replaced.")
        XCTAssertEqual(merged.filter { $0.value == 5 }.count, 9)
        XCTAssertEqual(merged.map(\.date), merged.map(\.date).sorted())
        XCTAssertEqual(Set(merged.map(\.series)).count, 1, "Recorded and live neighbours within 120 s are one continuous line.")
    }
    func testAHoleBetweenTwoLiveSegmentsKeepsTheRecordedPointsInIt() {
        let persisted = [point(0, 5, "a"), point(60, 5, "a"), point(120, 5, "a"), point(180, 5, "a")]
        let live = [point(0, 9, "live:1"), point(1, 9, "live:1"), point(170, 9, "live:2"), point(171, 9, "live:2")]
        let merged = LiveChartMerge.merge(persisted: persisted, live: live)
        XCTAssertTrue(merged.contains { $0.value == 5 && $0.date == t0.addingTimeInterval(120) }, "Recorded data between the segments is not thrown away.")
        XCTAssertFalse(merged.contains { $0.value == 5 && $0.date == t0.addingTimeInterval(0) })
    }
    func testRecordedGapsStayGapsAndTheLiveTailJoinsOnlyWhenNear() {
        let persisted = [point(0, 5, "a"), point(60, 5, "a"), point(600, 5, "b"), point(660, 5, "b")]   // a gap between 60 and 600
        let merged = LiveChartMerge.merge(persisted: persisted, live: [point(700, 9, "live:1"), point(701, 9, "live:1")])
        let ids = merged.map(\.series)
        XCTAssertNotEqual(ids[1], ids[2], "The recorded gap is preserved.")
        XCTAssertEqual(ids[3], ids[4], "Live joins the recorded point 40 s before it.")
    }
    func testMergeWithoutLivePointsIsIdentity() {
        let persisted = [point(0, 5, "a"), point(60, 6, "a")]
        XCTAssertEqual(LiveChartMerge.merge(persisted: persisted, live: []).map(\.value), [5, 6])
    }
}
