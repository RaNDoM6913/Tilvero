// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

enum OverviewMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case forecast, power, temperature, history, chargeLimit, keepAwake, systemPower, adapter, batteryHealth, applications, keyboardBacklight, powerTiles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forecast: "Time to 20%"
        case .power: "Battery power"
        case .temperature: "Temperature"
        case .history: "Last hour"
        case .chargeLimit: "Charge limit"
        case .keepAwake: "Keep Mac Awake"
        case .systemPower: "System"
        case .adapter: "Adapter"
        case .batteryHealth: "Battery health"
        case .applications: "Application activity"
        case .keyboardBacklight: "Keyboard backlight"
        case .powerTiles: "Power tiles"
        }
    }
    var symbol: String {
        switch self {
        case .forecast: "clock"
        case .power: "bolt"
        case .temperature: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .chargeLimit: "battery.100percent"
        case .keepAwake: "cup.and.saucer"
        case .systemPower: "desktopcomputer"
        case .adapter: "powerplug"
        case .batteryHealth: "heart"
        case .applications: "app.badge"
        case .keyboardBacklight: "keyboard"
        case .powerTiles: "square.grid.2x2"
        }
    }
}
struct OverviewDragSession: Sendable {
    let source: OverviewMetric
    private let token = UUID()
    var payload: String { "tilvero-overview:\(token.uuidString):\(source.rawValue)" }
    init(source: OverviewMetric) { self.source = source }
}
/// Native source-end invalidates active authorization; an already accepted drop
/// may finish its provider read asynchronously, once, until a new drag begins.
struct OverviewDragState {
    private(set) var active: OverviewDragSession?
    private var pending: OverviewDragSession?
    mutating func begin(_ source: OverviewMetric) -> OverviewDragSession {
        let session = OverviewDragSession(source: source)
        active = session; pending = nil
        return session
    }
    mutating func end() { active = nil }
    mutating func prepareDrop() -> OverviewDragSession? {
        guard let session = active else { return nil }
        pending = session; active = nil
        return session
    }
    mutating func completeDrop(_ payload: String, session: OverviewDragSession, onto target: OverviewMetric, preferences: inout OverviewPreferences) -> Bool {
        guard pending?.payload == session.payload else { return false }
        pending = nil
        return preferences.acceptDrop(payload, session: session, onto: target)
    }
}
/// How a metric card draws its last hour: the compact sparkline (default) or the
/// full zebra chart with a value axis.
enum MetricChartStyle: String, Codable, Sendable { case sparkline, chart }

extension OverviewMetric {
    /// Blocks that take a chart style (battery power, system, adapter input, temperature).
    var supportsChartStyle: Bool {
        switch self {
        case .power, .systemPower, .adapter, .temperature: true
        default: false
        }
    }
}

struct OverviewPreferences: Codable, Equatable {
    var order = OverviewMetric.allCases
    var hidden: Set<OverviewMetric> = [.chargeLimit, .keepAwake, .systemPower, .adapter, .batteryHealth, .applications, .keyboardBacklight, .powerTiles]
    /// Per-metric overrides; a metric without an entry uses `.sparkline`.
    var chartStyles: [OverviewMetric: MetricChartStyle] = [:]
    init() {}
    private enum CodingKeys: String, CodingKey { case order, hidden, chartStyles }
    func chartStyle(for metric: OverviewMetric) -> MetricChartStyle { chartStyles[metric] ?? .sparkline }
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
        hidden.formUnion(additions.filter { Self().hidden.contains($0) })
        // Tolerant on purpose: a missing, mistyped or partly unknown map never costs the saved composition.
        let rawStyles = (try? values.decodeIfPresent([String: String].self, forKey: .chartStyles)) ?? nil
        chartStyles = (rawStyles ?? [:]).reduce(into: [:]) { result, entry in
            if let metric = OverviewMetric(rawValue: entry.key), let style = MetricChartStyle(rawValue: entry.value) {
                result[metric] = style
            }
        }
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        if !chartStyles.isEmpty {
            try values.encode(Dictionary(uniqueKeysWithValues: chartStyles.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .chartStyles)
        }
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
