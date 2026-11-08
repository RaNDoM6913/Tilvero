// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Pure value layer for chart axes: "nice" value ticks and evenly spaced time
/// ticks. No SwiftUI, no platform access.
struct MetricChartScale: Equatable {
    /// Ascending tick values; the first and last tick are the domain bounds.
    let ticks: [Double]

    var domain: ClosedRange<Double> {
        (ticks.first ?? 0)...(ticks.last ?? 0)
    }

    /// Fewest fraction digits that render every tick exactly (0 for integer scales, 2 for 0.25 steps).
    var labelFractionDigits: Int {
        (0...6).first { digits in
            let factor = pow(10, Double(digits))
            return ticks.allSatisfy { abs($0 * factor - ($0 * factor).rounded()) < 1e-6 }
        } ?? 6
    }

    /// One label per tick, all with the same precision, so a gridline never carries a rounded-off number.
    func tickLabels(locale: Locale = .autoupdatingCurrent) -> [String] {
        let digits = labelFractionDigits
        return ticks.map { $0.formatted(.number.locale(locale).precision(.fractionLength(0...digits))) }
    }

    private static let maximumIntervals = 5
    private static let stepMultipliers: [Double] = [1, 2, 2.5, 5]

    /// Builds a scale over the finite `values`. Returns nil when none are finite.
    /// The step is the smallest of {1, 2, 2.5, 5} x 10^n that needs at most five
    /// intervals, and the domain snaps outward to multiples of that step. When zero
    /// is included and every value is on one side of it, a too-narrow range grows
    /// away from zero only (no impossible sign); mixed-sign data is re-centred.
    static func make(values: [Double], includesZero: Bool, minimumSpan: Double) -> MetricChartScale? {
        let finite = values.filter(\.isFinite)
        guard var low = finite.min(), var high = finite.max() else { return nil }
        if includesZero {
            low = Swift.min(low, 0)
            high = Swift.max(high, 0)
        }
        let required = Swift.max(minimumSpan, 0)
        if high - low < required || high == low {
            let span = high == low && required == 0 ? 1 : required
            if includesZero && low == 0 {
                // Positive-only data: the axis starts at zero and grows upwards, so it never shows negative values.
                high = low + span
            } else if includesZero && high == 0 {
                // Negative-only data: the axis ends at zero and grows downwards.
                low = high - span
            } else {
                let center = (low + high) / 2
                low = center - span / 2
                high = center + span / 2
            }
        }

        let span = high - low
        var exponent = Int(floor(log10(span / Double(maximumIntervals)))) - 1
        while exponent < 308 {
            let scaleFactor = pow(10, Double(exponent))
            for multiplier in stepMultipliers {
                let step = multiplier * scaleFactor
                let first = Int((low / step + 1e-9).rounded(.down))
                let last = Int((high / step - 1e-9).rounded(.up))
                guard last > first, last - first <= maximumIntervals else { continue }
                let ticks = (first...last).map { rounded(Double($0) * step) }
                return MetricChartScale(ticks: ticks)
            }
            exponent += 1
        }
        return nil
    }

    /// Evenly spaced dates from the start to the end of `window`, both included.
    static func timeTicks(in window: ClosedRange<Date>, count: Int) -> [Date] {
        guard count > 1, window.upperBound > window.lowerBound else { return [window.lowerBound] }
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        return (0..<count).map { index in
            index == count - 1
                ? window.upperBound
                : window.lowerBound.addingTimeInterval(length * Double(index) / Double(count - 1))
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1e9).rounded() / 1e9
    }
}

extension MetricChartScale {
    /// Axis rules per data-catalog metric id: power in watts (038, 043, 054) is
    /// anchored at zero with a two-watt minimum span; temperatures (039) and 026
    /// float with a one-unit minimum span. Unknown ids have no chart scale.
    static func scale(forMetric id: String, values: [Double]) -> MetricChartScale? {
        switch id {
        case "038", "043", "054":
            return make(values: values, includesZero: true, minimumSpan: 2)
        case "039", "026":
            return make(values: values, includesZero: false, minimumSpan: 1)
        default:
            return nil
        }
    }
}
// tlv-origin:7b2f94c1a05de386
