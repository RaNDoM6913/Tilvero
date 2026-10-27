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
