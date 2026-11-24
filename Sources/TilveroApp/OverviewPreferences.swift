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
/// In-place reordering of the Overview block list: the dragged row follows the pointer, its slot moves by whole rows
/// and the rows it passes shift one row the other way (pure, so the motion is testable without a view tree).
enum OverviewBlockReorder {
    /// The slot under the dragged row: the start plus whole rows of travel (half a row rounds), clamped to the list.
    static func target(from: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return from }
        return min(max(from + Int((translation / pitch).rounded()), 0), count - 1)
    }
    /// How far a resting row moves aside while another row is dragged from `from` to `to`.
    static func shift(index: Int, from: Int?, to: Int?, pitch: CGFloat) -> CGFloat {
        guard let from, let to, index != from else { return 0 }
        if from < to, index > from, index <= to { return -pitch }
        if from > to, index >= to, index < from { return pitch }
        return 0
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
    /// The page a brand-new install starts with: keep awake, the combined power chart, a temperature strip and battery
    /// health on top, everything else hidden, strip-height charts. It is written once by the first run (never by
    /// `init()`: untouched preferences of existing users must keep their page across updates).
    static let firstRunDefault: OverviewPreferences = {
        let visible: [OverviewMetric] = [.keepAwake, .powerCombined, .temperature, .batteryHealth]
        var value = OverviewPreferences()
        value.order = visible + OverviewMetric.allCases.filter { !visible.contains($0) }
        value.hidden = Set(OverviewMetric.allCases).subtracting(visible)
        value.chartSize = .strip
        return value
    }()
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
    /// Moves a block to a slot in one step (a finished drag); visibility is untouched, the index is clamped.
    mutating func move(_ metric: OverviewMetric, to index: Int) {
        guard let current = order.firstIndex(of: metric) else { return }
        let target = min(max(index, 0), order.count - 1)
        guard target != current else { return }
        order.remove(at: current)
        order.insert(metric, at: target)
    }
}
