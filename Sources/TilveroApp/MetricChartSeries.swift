// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Pure value layer for one chart series: points clipped to the visible window,
/// gaps between recorded series (never interpolated), and a stale tail when the
/// newest sample is older than `staleAfter`. No SwiftUI, no platform access.
struct MetricChartSeries {
    enum State: Equatable {
        /// No recorded point inside the window. Never rendered as zero.
        case empty
        /// Recorded points whose newest sample is current.
        case data
        /// Recorded points whose newest sample is older than `staleAfter`.
        case staleTail
    }

    let points: [HistoryChartPoint]
    let gaps: [OverviewHistorySeries.Gap]
    /// Points that have no neighbour in their own series (drawn as dots).
    let isolatedPoints: [HistoryChartPoint]
    /// Date of the newest recorded point when it is older than `staleAfter`.
    let staleSince: Date?
    let state: State

    /// Keeps points whose date lies inside `window` (inclusive), in the given
    /// order. A new `series` id between neighbours produces a gap. The tail is
    /// stale when `now` is more than `staleAfter` seconds past the last point.
    static func make(
        points: [HistoryChartPoint],
        window: ClosedRange<Date>,
        now: Date,
        staleAfter: TimeInterval = 120
    ) -> MetricChartSeries {
        let visible = points.filter { window.contains($0.date) }
        guard let last = visible.last else {
            return MetricChartSeries(points: [], gaps: [], isolatedPoints: [], staleSince: nil, state: .empty)
        }
        // Reuse the existing gap / isolated-point rules by replaying the points as
        // observations whose continuity id is the point's own series id.
        let layout = OverviewHistorySeries(visible.map {
            ChartObservation(id: $0.id, date: $0.date, value: $0.value, continuityID: $0.series)
        })
        let originals = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func original(_ point: HistoryChartPoint) -> HistoryChartPoint { originals[point.id] ?? point }
        let gaps = layout.gaps.map { OverviewHistorySeries.Gap(start: original($0.start), end: original($0.end)) }
        let isolated = layout.isolatedPoints.map(original)
        let isStale = now.timeIntervalSince(last.date) > staleAfter
        return MetricChartSeries(
            points: visible,
            gaps: gaps,
            isolatedPoints: isolated,
            staleSince: isStale ? last.date : nil,
            state: isStale ? .staleTail : .data
        )
    }
}
// tlv-origin:ec54fc4325994030
