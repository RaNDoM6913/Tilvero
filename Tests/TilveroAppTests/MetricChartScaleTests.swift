// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
@testable import TilveroApp

final class MetricChartScaleTests: XCTestCase {
    func testPowerRangeIncludesZeroWithNiceTicks() throws {
        let scale = try XCTUnwrap(MetricChartScale.make(values: [-14.2, -9.0, -6.1], includesZero: true, minimumSpan: 2))
        XCTAssertEqual(scale.ticks, [-15, -10, -5, 0])
        XCTAssertEqual(scale.domain, -15...0)
    }

    func testMinimumSpanIsTwoWatts() throws {
        let flat = try XCTUnwrap(MetricChartScale.make(values: [-10.0, -10.0], includesZero: false, minimumSpan: 2))
        XCTAssertGreaterThanOrEqual(flat.domain.upperBound - flat.domain.lowerBound, 2)
        XCTAssertTrue(flat.domain.contains(-10))
        XCTAssertEqual(flat.ticks, [-11, -10.5, -10, -9.5, -9])

        let withZero = try XCTUnwrap(MetricChartScale.make(values: [-10.0, -10.0], includesZero: true, minimumSpan: 2))
        XCTAssertGreaterThanOrEqual(withZero.domain.upperBound - withZero.domain.lowerBound, 2)
        XCTAssertEqual(withZero.ticks, [-10, -8, -6, -4, -2, 0])
    }

    func testTemperatureDoesNotForceZero() throws {
        let scale = try XCTUnwrap(MetricChartScale.make(values: [31.2, 35.0, 38.4], includesZero: false, minimumSpan: 1))
        XCTAssertEqual(scale.domain, 30...40)
        XCTAssertEqual(scale.ticks, [30, 32, 34, 36, 38, 40])
    }

    func testSpikeKeepsNiceTicks() throws {
        let values = [10.0, 11.0, 12.0, 10.5, 62.0, 11.5]
        let scale = try XCTUnwrap(MetricChartScale.make(values: values, includesZero: false, minimumSpan: 1))
        XCTAssertLessThanOrEqual(scale.ticks.count, 6)
        XCTAssertTrue(scale.ticks.allSatisfy { $0.truncatingRemainder(dividingBy: 10) == 0 })
        XCTAssertTrue(scale.domain.contains(62))
        XCTAssertTrue(scale.domain.contains(10))
    }

    func testEmptyAndNonFiniteGiveNil() {
        XCTAssertNil(MetricChartScale.make(values: [], includesZero: true, minimumSpan: 2))
        XCTAssertNil(MetricChartScale.make(values: [.nan, .infinity, -.infinity], includesZero: false, minimumSpan: 1))
        let mixed = MetricChartScale.make(values: [.nan, 31.2, .infinity, 38.4], includesZero: false, minimumSpan: 1)
        XCTAssertEqual(mixed?.domain, 30...40)
    }

    func testTimeTicksAreEvenlySpacedAndIncludeBothEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(3_600)
        let ticks = MetricChartScale.timeTicks(in: start...end, count: 5)
        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(ticks.first, start)
        XCTAssertEqual(ticks.last, end)
        let gaps = zip(ticks, ticks.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertTrue(gaps.allSatisfy { abs($0 - 900) < 0.001 })
    }

    func testMetricScaleForWattsIncludesZeroWithMinimumSpanTwo() throws {
        for id in ["038", "043", "054"] {
            let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: id, values: [-1.2, -1.0]), id)
            XCTAssertTrue(scale.domain.contains(0), id)
            XCTAssertGreaterThanOrEqual(scale.domain.upperBound - scale.domain.lowerBound, 2, id)
        }
    }

    func testMetricScaleForTemperatureDoesNotForceZero() throws {
        let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: "039", values: [31.2, 38.4]))
        XCTAssertEqual(scale.domain, 30...40)
        XCTAssertNil(MetricChartScale.scale(forMetric: "999", values: [1, 2]))
    }
}
