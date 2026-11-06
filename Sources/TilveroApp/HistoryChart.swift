// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

struct ChartObservation {
    let id: UUID
    let date: Date
    let value: Double?
    let continuityID: String
}
struct HistoryChartPoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
    let series: String
}
enum HistoryChart {
    /// Every missing channel sample breaks that channel's line, independently of battery charge.
    static func points(_ observations: [ChartObservation]) -> [HistoryChartPoint] {
        var result: [HistoryChartPoint] = [], gap = 0
        for observation in observations {
            guard let value = observation.value, value.isFinite else { gap += 1; continue }
            result.append(.init(id: observation.id, date: observation.date, value: value, series: observation.continuityID + ":" + String(gap)))
        }
        return result
    }
}

/// Overview draws connectors between recorded endpoints without adding data points.
struct OverviewHistorySeries {
    struct Gap {
        let start: HistoryChartPoint
        let end: HistoryChartPoint
    }

    let points: [HistoryChartPoint]
    let gaps: [Gap]
    let isolatedPoints: [HistoryChartPoint]

    init(_ observations: [ChartObservation]) {
        let points = HistoryChart.points(observations)
        self.points = points
        gaps = zip(points, points.dropFirst()).compactMap { start, end in
            guard start.series != end.series, start.date < end.date else { return nil }
            return Gap(start: start, end: end)
        }
        isolatedPoints = points.indices.compactMap { index in
            let point = points[index]
            let followsSeries = index > 0 && points[index - 1].series == point.series
            let continuesSeries = index + 1 < points.count && points[index + 1].series == point.series
            return followsSeries || continuesSeries ? nil : point
        }
    }
}
