// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine
import PowerTelemetry

/// The newest minutes of the live power charts (temperature, system power, adapter input) at about one point per second,
/// held in memory only while the quick menu is open on Overview (source: SMC sensors; nothing here is persisted or
/// enters the history, exports or diagnostics).
struct LiveMetricTail {
    /// Only the last ten minutes are kept; the older part of the hour comes from the recorded history.
    static let maximumAge: TimeInterval = 600
    /// A pause longer than this (the menu was closed) starts a new live segment instead of drawing a line across it.
    static let segmentGap: TimeInterval = 5
    /// A tail older than this when a live session starts is dropped: the recorded history covers that time.
    static let staleAfter: TimeInterval = 120

    private var storage: [String: [HistoryChartPoint]] = [:]
    private var boundaries: [String: String] = [:]
    /// Live segments that continue the recorded line (no power-source change or sleep since the last recorded point).
    private(set) var joinable: Set<String> = []
    private(set) var latest: Date?

    /// `boundary` changes whenever the power source or the sleep state changed: that starts a new segment.
    /// An adapter known to be unplugged records no adapter input (054): there is nothing to draw.
    mutating func append(_ sample: LivePowerSample, boundary: String, adapterConnected: Bool?, joinsRecorded: Bool) {
        for id in LivePowerSample.metricIDs {
            if id == "054", adapterConnected == false { continue }
            guard let value = sample.value(metricID: id), value.isFinite else { continue }
            var list = storage[id, default: []]
            var series = "live:" + UUID().uuidString
            if let last = list.last, boundaries[id] == boundary, sample.collectedAt >= last.date,
               sample.collectedAt.timeIntervalSince(last.date) <= Self.segmentGap { series = last.series }
            else if joinsRecorded { joinable.insert(series) }
            boundaries[id] = boundary
            list.append(HistoryChartPoint(id: UUID(), date: sample.collectedAt, value: value, series: series))
            let cutoff = sample.collectedAt.addingTimeInterval(-Self.maximumAge)
            if let first = list.firstIndex(where: { $0.date >= cutoff }), first > 0 { list.removeFirst(first) }
            storage[id] = list
        }
        if joinable.count > 64 {
            let alive = Set(storage.values.flatMap { $0.map(\.series) })
            joinable = joinable.intersection(alive)
        }
        latest = max(latest ?? sample.collectedAt, sample.collectedAt)
    }
    func points(id: String) -> [HistoryChartPoint] { storage[id] ?? [] }
    var isEmpty: Bool { storage.values.allSatisfy(\.isEmpty) }
    mutating func clear() { storage = [:]; boundaries = [:]; joinable = []; latest = nil }
    /// Drops an old tail when a live session starts (or the clock moved backwards).
    mutating func clearIfStale(now: Date) {
        guard let latest else { return }
        if now.timeIntervalSince(latest) > Self.staleAfter || latest > now.addingTimeInterval(5) { clear() }
    }
}

/// Observed only by the chart views, so a live tick re-renders them and nothing else (not the whole model, not the
/// popover host).
@MainActor final class LiveMetricStore: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var tail = LiveMetricTail()
    func append(_ sample: LivePowerSample, boundary: String, adapterConnected: Bool?, joinsRecorded: Bool) {
        tail.append(sample, boundary: boundary, adapterConnected: adapterConnected, joinsRecorded: joinsRecorded)
        revision &+= 1
    }
    func clearIfStale(now: Date) { guard tail.latest != nil else { return }; tail.clearIfStale(now: now); revision &+= 1 }
    func clear() { guard tail.latest != nil else { return }; tail.clear(); revision &+= 1 }
}

import SwiftUI
/// Re-evaluates its content on every live tick; wrap only the chart.
@MainActor struct LiveRefresh<Content: View>: View {
    @ObservedObject var store: LiveMetricStore
    @ViewBuilder var content: () -> Content
    var body: some View { _ = store.revision; return content() }
}

enum LiveChartMerge {
    /// Recorded points (about one a minute) plus the live tail. A recorded point is replaced where a live segment
    /// covers it; elsewhere it stays. Continuity (what the chart draws as one line) is recomputed: two recorded
    /// neighbours keep their own relation, live neighbours keep the tail's segments, a live segment joins the recorded
    /// point before it only when it is `joinable` and at most 120 s apart, and a recorded point after live data is
    /// never joined to it.
    static func merge(persisted: [HistoryChartPoint], live: [HistoryChartPoint], joinable: Set<String>) -> [HistoryChartPoint] {
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
                switch (previous.isLive, isLive) {
                case (false, false), (true, true): contiguous = previous.point.series == point.series
                case (false, true): contiguous = joinable.contains(point.series) && point.date.timeIntervalSince(previous.point.date) <= 120
                case (true, false): contiguous = false
                }
            }
            if !contiguous { counter += 1; current = "merged:\(counter)" }
            result.append(HistoryChartPoint(id: point.id, date: point.date, value: point.value, series: current))
            previous = (point, isLive)
        }
        return result
    }
}
