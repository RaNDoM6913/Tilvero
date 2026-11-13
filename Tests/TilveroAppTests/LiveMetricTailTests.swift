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
    private func append(_ tail: inout LiveMetricTail, _ s: LivePowerSample, boundary: String = "a", adapter: Bool? = true, joins: Bool = true) {
        tail.append(s, boundary: boundary, adapterConnected: adapter, joinsRecorded: joins)
    }

    func testTailFeedsTheThreeLiveMetricsFromOneSampleAndNeverBatteryPower() {
        var tail = LiveMetricTail()
        append(&tail, sample(0))
        XCTAssertEqual(tail.points(id: "043").first?.value, 7)
        XCTAssertEqual(tail.points(id: "054").first?.value, 7.5)
        XCTAssertEqual(tail.points(id: "039").first?.value, 33)
        XCTAssertTrue(tail.points(id: "038").isEmpty, "Battery power keeps its recorded readings.")
    }
    func testMissingChannelsLeaveNoPointNeverAZero() {
        var tail = LiveMetricTail()
        append(&tail, sample(0, system: nil, adapter: nil))
        XCTAssertTrue(tail.points(id: "043").isEmpty); XCTAssertTrue(tail.points(id: "054").isEmpty)
        XCTAssertEqual(tail.points(id: "039").count, 1)
    }
    func testAnUnpluggedAdapterRecordsNoAdapterInput() {
        var tail = LiveMetricTail()
        append(&tail, sample(0), adapter: false)
        XCTAssertTrue(tail.points(id: "054").isEmpty, "Nothing to draw for an adapter that is not there.")
        XCTAssertEqual(tail.points(id: "043").count, 1)
        append(&tail, sample(1), adapter: nil)
        XCTAssertEqual(tail.points(id: "054").count, 1, "An unknown state is not reported as unplugged.")
    }
    func testConsecutiveSecondsShareASegmentAndAPauseOrABoundaryStartsANewOne() {
        var tail = LiveMetricTail()
        for i in 0..<5 { append(&tail, sample(TimeInterval(i))) }
        append(&tail, sample(60))                                  // pause
        append(&tail, sample(61), boundary: "b")                    // power source or sleep changed
        let series = tail.points(id: "043").map(\.series)
        XCTAssertEqual(Set(series.prefix(5)).count, 1)
        XCTAssertNotEqual(series[4], series[5]); XCTAssertNotEqual(series[5], series[6])
    }
    func testOnlySegmentsThatContinueTheRecordedLineAreJoinable() {
        var tail = LiveMetricTail()
        append(&tail, sample(0), joins: true)
        append(&tail, sample(60), joins: false)
        let ids = tail.points(id: "043").map(\.series)
        XCTAssertTrue(tail.joinable.contains(ids[0])); XCTAssertFalse(tail.joinable.contains(ids[1]))
    }
    func testOnlyTheLastTenMinutesAreKept() {
        var tail = LiveMetricTail()
        for i in stride(from: 0, through: 900, by: 1) { append(&tail, sample(TimeInterval(i))) }
        let points = tail.points(id: "043")
        XCTAssertLessThanOrEqual(points.count, 601)
        XCTAssertGreaterThanOrEqual(points.first!.date, t0.addingTimeInterval(300))
    }
    func testAStaleTailIsDroppedWhenALiveSessionStartsAndAFutureOneToo() {
        var tail = LiveMetricTail()
        append(&tail, sample(0))
        tail.clearIfStale(now: t0.addingTimeInterval(60)); XCTAssertFalse(tail.isEmpty, "A minute-old tail is still contiguous enough.")
        tail.clearIfStale(now: t0.addingTimeInterval(300)); XCTAssertTrue(tail.isEmpty)
        append(&tail, sample(1000))
        tail.clearIfStale(now: t0.addingTimeInterval(500)); XCTAssertTrue(tail.isEmpty, "The clock moved backwards: nothing may stay in the future.")
    }

    // MARK: Merge

    func testMergeReplacesRecordedPointsOnlyWhereLiveCoversThem() {
        let persisted = (0..<10).map { point(TimeInterval($0 * 60), 5, "a") }
        let live = (0..<30).map { point(540 + TimeInterval($0), 9, "live:1") }
        let merged = LiveChartMerge.merge(persisted: persisted, live: live, joinable: ["live:1"])
        XCTAssertEqual(merged.filter { $0.value == 9 }.count, 30)
        XCTAssertFalse(merged.contains { $0.value == 5 && $0.date == t0.addingTimeInterval(540) })
        XCTAssertEqual(merged.filter { $0.value == 5 }.count, 9)
        XCTAssertEqual(merged.map(\.date), merged.map(\.date).sorted())
        XCTAssertEqual(Set(merged.map(\.series)).count, 1, "A joinable live segment continues the recorded line.")
    }
    func testANonJoinableLiveSegmentIsNotConnectedToTheRecordedLine() {
        let persisted = [point(0, 5, "a"), point(60, 5, "a")]
        let live = [point(100, 9, "live:1"), point(101, 9, "live:1")]
        let merged = LiveChartMerge.merge(persisted: persisted, live: live, joinable: [])
        XCTAssertNotEqual(merged[1].series, merged[2].series, "A power change or sleep between them: no line across it.")
        let joined = LiveChartMerge.merge(persisted: persisted, live: live, joinable: ["live:1"])
        XCTAssertEqual(joined[1].series, joined[2].series)
    }
    func testAHoleBetweenTwoLiveSegmentsKeepsTheRecordedPointsInIt() {
        let persisted = [point(0, 5, "a"), point(60, 5, "a"), point(120, 5, "a"), point(180, 5, "a")]
        let live = [point(0, 9, "live:1"), point(1, 9, "live:1"), point(170, 9, "live:2"), point(171, 9, "live:2")]
        let merged = LiveChartMerge.merge(persisted: persisted, live: live, joinable: [])
        XCTAssertTrue(merged.contains { $0.value == 5 && $0.date == t0.addingTimeInterval(120) })
        XCTAssertFalse(merged.contains { $0.value == 5 && $0.date == t0 })
    }
    func testRecordedGapsStayGaps() {
        let persisted = [point(0, 5, "a"), point(60, 5, "a"), point(600, 5, "b"), point(660, 5, "b")]
        let merged = LiveChartMerge.merge(persisted: persisted, live: [point(700, 9, "live:1"), point(701, 9, "live:1")], joinable: ["live:1"])
        XCTAssertNotEqual(merged[1].series, merged[2].series)
        XCTAssertEqual(merged[3].series, merged[4].series)
    }
    func testMergeWithoutLivePointsIsIdentity() {
        let persisted = [point(0, 5, "a"), point(60, 6, "a")]
        XCTAssertEqual(LiveChartMerge.merge(persisted: persisted, live: [], joinable: []).map(\.value), [5, 6])
    }
}
