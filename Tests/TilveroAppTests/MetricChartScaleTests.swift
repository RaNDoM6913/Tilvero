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
        XCTAssertEqual(scale.ticks, [0, 20, 40, 60, 80])
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

    // MARK: Positive-only and negative-only power never show impossible signs

    func testFlatPositivePowerExtendsUpwardOnly() throws {
        let adapter = try XCTUnwrap(MetricChartScale.scale(forMetric: "054", values: [0.5, 0.5, 0.5]))
        XCTAssertEqual(adapter.domain.lowerBound, 0, "Adapter input is never negative.")
        XCTAssertTrue(adapter.ticks.allSatisfy { $0 >= 0 }, "\(adapter.ticks)")
        XCTAssertGreaterThanOrEqual(adapter.domain.upperBound - adapter.domain.lowerBound, 2)
        XCTAssertTrue(adapter.domain.contains(0.5))
        let zero = try XCTUnwrap(MetricChartScale.scale(forMetric: "054", values: [0, 0]))
        XCTAssertEqual(zero.domain.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(zero.domain.upperBound, 2)
    }

    func testFlatNegativePowerExtendsDownwardOnly() throws {
        let battery = try XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: [-10, -10]))
        XCTAssertEqual(battery.domain.upperBound, 0, "Battery discharge is not drawn above zero.")
        XCTAssertTrue(battery.ticks.allSatisfy { $0 <= 0 }, "\(battery.ticks)")
        let small = try XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: [-0.5, -0.5]))
        XCTAssertEqual(small.domain.upperBound, 0)
        XCTAssertGreaterThanOrEqual(small.domain.upperBound - small.domain.lowerBound, 2)
        XCTAssertTrue(small.domain.contains(-0.5))
    }

    func testMixedSignPowerKeepsTheCentredMinimumSpan() throws {
        let mixed = try XCTUnwrap(MetricChartScale.make(values: [-0.2, 0.2], includesZero: true, minimumSpan: 2))
        XCTAssertEqual(mixed.domain, -1...1, "Mixed-sign data is re-centred as before.")
        XCTAssertTrue(mixed.ticks.contains(0))
    }

    // MARK: Review Focus: power sign flip inside the hour

    func testSignFlipKeepsBothSignsAndAZeroTick() throws {
        let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: [-8, -3, 2, 6]))
        XCTAssertEqual(scale.ticks, [-10, -5, 0, 5, 10])
        XCTAssertTrue(scale.domain.contains(-8) && scale.domain.contains(6))
        XCTAssertTrue(scale.ticks.contains(0), "Zero is a tick, so the zero rule lies on a band edge.")
    }

    func testSignFlipLabelsZeroAsZero() throws {
        let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: [-8, -3, 2, 6]))
        let labels = scale.tickLabels(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(labels[try XCTUnwrap(scale.ticks.firstIndex(of: 0))], "0")
        XCTAssertEqual(labels, ["-10", "-5", "0", "5", "10"])
    }

    // MARK: Tick labels are exact for their scale

    private func parsed(_ label: String, _ locale: Locale) -> Double? {
        try? Double(label, format: .number.locale(locale))
    }

    func testFlatTemperatureTickLabelsAreExactAndUnique() throws {
        let en = Locale(identifier: "en_US"), ru = Locale(identifier: "ru_RU")
        for value in [35.0, 95.0] {
            let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: "039", values: [value]))
            XCTAssertEqual(scale.ticks, [value - 0.5, value - 0.25, value, value + 0.25, value + 0.5])
            for locale in [en, ru] {
                let labels = scale.tickLabels(locale: locale)
                XCTAssertEqual(labels.count, scale.ticks.count)
                XCTAssertEqual(Set(labels).count, labels.count, "Every gridline has its own label: \(labels)")
                for (label, tick) in zip(labels, scale.ticks) {
                    XCTAssertEqual(try XCTUnwrap(parsed(label, locale)), tick, accuracy: 1e-9, "\(label) must say \(tick)")
                }
            }
        }
        XCTAssertEqual(try XCTUnwrap(MetricChartScale.scale(forMetric: "039", values: [35.0])).tickLabels(locale: ru),
                       ["34,5", "34,75", "35", "35,25", "35,5"])
    }

    func testNarrowTemperatureRangeLabelsEveryQuarterStepExactly() throws {
        let en = Locale(identifier: "en_US")
        let scale = try XCTUnwrap(MetricChartScale.scale(forMetric: "039", values: [30.1, 31.1]))
        XCTAssertEqual(scale.ticks, [30, 30.25, 30.5, 30.75, 31, 31.25])
        let labels = scale.tickLabels(locale: en)
        XCTAssertEqual(Set(labels).count, labels.count)
        for (label, tick) in zip(labels, scale.ticks) {
            XCTAssertEqual(try XCTUnwrap(parsed(label, en)), tick, accuracy: 1e-9, "\(label) must say \(tick)")
        }
    }

    func testIntegerAndHalfScalesStayQuiet() throws {
        let en = Locale(identifier: "en_US")
        let power = try XCTUnwrap(MetricChartScale.scale(forMetric: "054", values: [3.2, 4.1, 28.0]))
        XCTAssertTrue(power.tickLabels(locale: en).allSatisfy { !$0.contains(".") }, "\(power.tickLabels(locale: en))")
        let half = try XCTUnwrap(MetricChartScale.make(values: [-10, -10], includesZero: false, minimumSpan: 2))
        XCTAssertEqual(half.tickLabels(locale: en), ["-11", "-10.5", "-10", "-9.5", "-9"])
        let tenths = MetricChartScale(ticks: [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(tenths.tickLabels(locale: en), ["0", "0.1", "0.2", "0.3"])
    }
}
