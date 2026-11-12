// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

enum OverviewMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case forecast, power, temperature, history, keepAwake, systemPower, adapter, batteryHealth, applications, keyboardBacklight, powerTiles, powerCombined
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forecast: "Time to 20%"
        case .power: "Battery power"
        case .temperature: "Temperature"
        case .history: "Last hour"
        case .keepAwake: "Keep Mac Awake"
        case .systemPower: "System"
        case .adapter: "Adapter"
        case .batteryHealth: "Battery health"
        case .applications: "Application activity"
        case .keyboardBacklight: "Keyboard backlight"
        case .powerTiles: "Power tiles"
        case .powerCombined: "Power: combined chart"
        }
    }
    var symbol: String {
        switch self {
        case .forecast: "clock"
        case .power: "bolt"
        case .temperature: "thermometer.medium"
        case .history: "chart.xyaxis.line"
        case .keepAwake: "cup.and.saucer"
        case .systemPower: "desktopcomputer"
        case .adapter: "powerplug"
        case .batteryHealth: "heart"
        case .applications: "app.badge"
        case .keyboardBacklight: "keyboard"
        case .powerTiles: "square.grid.2x2"
        case .powerCombined: "chart.line.uptrend.xyaxis"
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
/// How a metric card draws its last hour: the compact sparkline (non-chart metrics) or the
/// full zebra chart with a value axis.
enum MetricChartStyle: String, Codable, Sendable { case sparkline, chart }

/// How tall the zebra charts of the quick panel are: a thin strip, the moderate default (80 pt plot, three time
/// labels, caption in the card header) or the original regular height (120 pt).
enum MetricChartSize: String, Codable, CaseIterable, Sendable {
    case strip, moderate, regular
    static let standard = MetricChartSize.moderate
    var density: MetricChartView.Density {
        switch self { case .strip: .strip; case .moderate: .moderate; case .regular: .full }
    }
    var title: String {
        switch self { case .strip: "Strip"; case .moderate: "Compact"; case .regular: "Regular" }
    }
}

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
    var hidden: Set<OverviewMetric> = [.keepAwake, .systemPower, .adapter, .batteryHealth, .applications, .keyboardBacklight, .powerTiles, .powerCombined]
    /// One height for every chart on the page; the default stays unwritten so untouched preferences stay unchanged.
    var chartSize: MetricChartSize = .standard
    init() {}
    private enum CodingKeys: String, CodingKey { case order, hidden, chartSize }
    /// Metrics that can draw a chart always do (the sparkline option is gone); a saved `chartStyles` key is ignored.
    func chartStyle(for metric: OverviewMetric) -> MetricChartStyle { metric.supportsChartStyle ? .chart : .sparkline }
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
        chartSize = ((try? values.decodeIfPresent(String.self, forKey: .chartSize)) ?? nil).flatMap(MetricChartSize.init(rawValue:)) ?? .standard
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        if chartSize != .standard { try values.encode(chartSize.rawValue, forKey: .chartSize) }
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
