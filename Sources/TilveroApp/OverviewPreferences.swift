import Foundation

enum OverviewMetric: String, CaseIterable, Codable, Identifiable {
    case forecast, power, temperature, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forecast: "Time to 20%"
        case .power: "Power"
        case .temperature: "Temperature"
        case .history: "Last hour"
        }
    }
}
struct OverviewPreferences: Codable, Equatable {
    var order = OverviewMetric.allCases
    var hidden = Set<OverviewMetric>()
    static func load(_ data: Data?) -> Self {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data),
              Set(value.order).count == value.order.count else { return .init() }
        value.order += OverviewMetric.allCases.filter { !value.order.contains($0) }
        return value
    }
    mutating func move(_ metric: OverviewMetric, by amount: Int) {
        guard let current = order.firstIndex(of: metric), order.indices.contains(current + amount) else { return }
        order.swapAt(current, current + amount)
    }
}
