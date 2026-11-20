// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerPersistence

/// Day and week series of the window charts, built from recorded samples only. Pure and `Sendable`, so pages build
/// them off the main actor. Gaps stay gaps: nothing is interpolated across a missing interval, a segment change or
/// (for power) a power-source change. At most `maximumBuckets` min/max buckets per window keep extremes visible.
enum HistorySeries {
    enum Measurement: String, Sendable, CaseIterable {
        case charge, batteryPower, inputPower, temperature
    }

    static let maximumBuckets = 600
    /// Two recorded samples further apart than this are not joined.
    static let joinLimit: TimeInterval = 120

    /// Recorded points of `measurement` inside `window`, in time order. Adapter input exists only in the catalog of
    /// recent samples (older samples keep scalar fields only), so its line simply ends where the catalog ends.
    static func points(_ samples: [HistorySample], measurement: Measurement, window: ClosedRange<Date>) -> [HistoryChartPoint] {
        var result: [HistoryChartPoint] = []
        var gap = 0
        var previous: HistorySample?
        for sample in samples.sorted(by: { $0.collectedAt < $1.collectedAt }) where window.contains(sample.collectedAt) {
            guard let value = value(of: sample, measurement), value.isFinite else { gap += 1; previous = nil; continue }
            if let previous {
                let apart = sample.collectedAt.timeIntervalSince(previous.collectedAt) > joinLimit
                    && sample.observedFrom.timeIntervalSince(previous.collectedAt) > joinLimit
                let sourceChanged = measurement != .charge && measurement != .temperature
                    && sample.isExternalPower != previous.isExternalPower
                if apart || sourceChanged || sample.segmentID != previous.segmentID { gap += 1 }
            }
            result.append(HistoryChartPoint(id: sample.id, date: sample.collectedAt, value: value,
                                            series: measurement.rawValue + ":\(gap)"))
            previous = sample
        }
        return result
    }

    static func value(of sample: HistorySample, _ measurement: Measurement) -> Double? {
        switch measurement {
        case .charge: return sample.chargePercent.flatMap { (0...100).contains($0) ? $0 : nil }
        case .temperature: return sample.temperatureCelsius
        case .batteryPower: return sample.batteryPowerWatts
        case .inputPower:
            guard let reading = sample.readings.first(where: { $0.id == "054" }), reading.availability == .available,
                  reading.freshness != .stale else { return nil }
            return reading.value?.doubleValue
        }
    }

    /// Keeps the minimum and maximum of each bucket per line (in time order), so a spike survives the reduction. Lines
    /// with at most `maximumBuckets` points are returned unchanged.
    static func downsample(_ points: [HistoryChartPoint], window: ClosedRange<Date>, maximumBuckets: Int = maximumBuckets) -> [HistoryChartPoint] {
        guard points.count > maximumBuckets, maximumBuckets > 0 else { return points }
        let span = max(1, window.upperBound.timeIntervalSince(window.lowerBound))
        let width = span / Double(max(1, maximumBuckets / 2))
        struct Key: Hashable { let bucket: Int; let series: String }
        var order: [Key] = []
        var extremes: [Key: (low: HistoryChartPoint, high: HistoryChartPoint)] = [:]
        for point in points {
            let key = Key(bucket: Int(point.date.timeIntervalSince(window.lowerBound) / width), series: point.series)
            if let current = extremes[key] {
                extremes[key] = (point.value < current.low.value ? point : current.low,
                                 point.value > current.high.value ? point : current.high)
            } else {
                order.append(key)
                extremes[key] = (point, point)
            }
        }
        var result: [HistoryChartPoint] = []
        result.reserveCapacity(order.count * 2)
        for key in order {
            guard let pair = extremes[key] else { continue }
            if pair.low.id == pair.high.id { result.append(pair.low) }
            else { result.append(contentsOf: pair.low.date <= pair.high.date ? [pair.low, pair.high] : [pair.high, pair.low]) }
        }
        return result
    }

    /// Intervals without recorded points longer than `minimum` (shaded on the charge chart; never labelled as sleep,
    /// since the history does not say why it is empty).
    static func gaps(_ points: [HistoryChartPoint], minimum: TimeInterval) -> [ClosedRange<Date>] {
        var result: [ClosedRange<Date>] = []
        for (previous, next) in zip(points, points.dropFirst()) where next.series != previous.series {
            if next.date.timeIntervalSince(previous.date) >= minimum { result.append(previous.date...next.date) }
        }
        return result
    }

    /// A scale that starts at zero for positive data and covers negative data symmetrically enough to read both.
    static func yDomain(_ values: [Double], minimumTop: Double = 10) -> ClosedRange<Double> {
        let low = min(0, values.min() ?? 0), high = max(minimumTop, values.max() ?? 0)
        func nice(_ value: Double) -> Double {
            guard value > 0 else { return 0 }
            let step: Double = value <= 10 ? 5 : value <= 50 ? 10 : value <= 100 ? 20 : 50
            return (value / step).rounded(.up) * step
        }
        return -nice(-low)...nice(high)
    }
}
