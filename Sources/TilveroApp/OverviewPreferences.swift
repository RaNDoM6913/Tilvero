import Foundation

enum OverviewMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case forecast, power, temperature, history, chargeLimit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forecast: "Time to 20%"
        case .power: "Power"
        case .temperature: "Temperature"
        case .history: "Last hour"
        case .chargeLimit: "Charge limit"
        }
    }
    var symbol: String {
        switch self {
        case .forecast: "clock"
        case .power: "bolt"
        case .temperature: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .chargeLimit: "battery.100percent"
        }
    }
}
struct OverviewDragSession: Sendable {
    let source: OverviewMetric
    private let token = UUID()
    var payload: String { "tilvero-overview:\(token.uuidString):\(source.rawValue)" }
    init(source: OverviewMetric) { self.source = source }
}
struct OverviewPreferences: Codable, Equatable {
    var order = OverviewMetric.allCases
    var hidden: Set<OverviewMetric> = [.chargeLimit]
    init() {}
    private enum CodingKeys: String, CodingKey { case order, hidden }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawOrder = try values.decodeIfPresent([String].self, forKey: .order) ?? OverviewMetric.allCases.map(\.rawValue)
        var known: [OverviewMetric] = []
        for id in rawOrder {
            if let metric = OverviewMetric(rawValue: id), !known.contains(metric) { known.append(metric) }
        }
        let additions = OverviewMetric.allCases.filter { !known.contains($0) }
        order = known + additions
        hidden = Set(try values.decodeIfPresent([String].self, forKey: .hidden)?.compactMap(OverviewMetric.init(rawValue:)) ?? Array(Self().hidden))
        hidden.formUnion(additions.filter { $0 == .chargeLimit })
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    mutating func move(_ metric: OverviewMetric, by amount: Int) {
        guard let current = order.firstIndex(of: metric), order.indices.contains(current + amount) else { return }
        order.swapAt(current, current + amount)
    }
    @discardableResult mutating func acceptDrop(_ payload: String, session: OverviewDragSession, onto target: OverviewMetric) -> Bool {
        guard payload == session.payload, session.source != target,
              let sourceIndex = order.firstIndex(of: session.source), let targetIndex = order.firstIndex(of: target) else { return false }
        order.remove(at: sourceIndex)
        order.insert(session.source, at: min(targetIndex, order.count))
        return true
    }
}
