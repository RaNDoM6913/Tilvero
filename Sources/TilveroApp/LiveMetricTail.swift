// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerTelemetry

/// The newest minutes of the four power charts at about one point per second, held in memory only while the quick menu
/// is open on Overview (source: SMC sensors; nothing here is persisted or enters the history).
struct LiveMetricTail {
    /// Only the last ten minutes are kept; the older part of the hour comes from the recorded history.
    static let maximumAge: TimeInterval = 600
    /// A pause longer than this (the menu was closed) starts a new live segment instead of drawing a line across it.
    static let segmentGap: TimeInterval = 5

    private var storage: [String: [HistoryChartPoint]] = [:]
    private(set) var latest: Date?

    mutating func append(_ sample: LivePowerSample) {
        for id in LivePowerSample.metricIDs {
            guard let value = sample.value(metricID: id), value.isFinite else { continue }
            var list = storage[id, default: []]
            let series: String
            if let last = list.last, sample.collectedAt.timeIntervalSince(last.date) <= Self.segmentGap, sample.collectedAt >= last.date { series = last.series }
            else { series = "live:" + UUID().uuidString }
            list.append(HistoryChartPoint(id: UUID(), date: sample.collectedAt, value: value, series: series))
            let cutoff = sample.collectedAt.addingTimeInterval(-Self.maximumAge)
            if let first = list.firstIndex(where: { $0.date >= cutoff }), first > 0 { list.removeFirst(first) }
            storage[id] = list
        }
        latest = max(latest ?? sample.collectedAt, sample.collectedAt)
    }
    func points(id: String) -> [HistoryChartPoint] { storage[id] ?? [] }
    var isEmpty: Bool { storage.values.allSatisfy(\.isEmpty) }
    mutating func clear() { storage = [:]; latest = nil }
}

enum LiveChartMerge {
    /// Recorded points (about one a minute) followed by the live tail. A recorded point is replaced where a live
    /// segment covers it; elsewhere it stays. Continuity (what the chart draws as one line) is recomputed: two recorded
    /// neighbours keep their own relation, any other neighbours join when no more than 120 s apart.
    static func merge(persisted: [HistoryChartPoint], live: [HistoryChartPoint]) -> [HistoryChartPoint] {
        guard !live.isEmpty else { return persisted }
        var ranges: [(start: Date, end: Date)] = []
        var segment: String?
        for point in live {
            if point.series == segment, let last = ranges.indices.last { ranges[last].end = point.date }
            else { ranges.append((point.date, point.date)); segment = point.series }
        }
        let kept = persisted.filter { point in !ranges.contains { point.date >= $0.start && point.date <= $0.end } }
        let ordered = (kept.map { ($0, false) } + live.map { ($0, true) }).sorted { $0.0.date < $1.0.date }
        var result: [HistoryChartPoint] = []
        var previous: (point: HistoryChartPoint, isLive: Bool)?
        var counter = 0, current = ""
        for (point, isLive) in ordered {
            var contiguous = false
            if let previous {
                if previous.isLive == isLive { contiguous = previous.point.series == point.series }
                if !contiguous { contiguous = previous.isLive != isLive && point.date.timeIntervalSince(previous.point.date) <= 120 }
            }
            if !contiguous { counter += 1; current = "merged:\(counter)" }
            result.append(HistoryChartPoint(id: point.id, date: point.date, value: point.value, series: current))
            previous = (point, isLive)
        }
        return result
    }
}
