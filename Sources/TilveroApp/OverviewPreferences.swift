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
    /// Blocks whose chart height can be set per block in the builder.
    var hasChartSize: Bool {
        switch self {
        case .power, .temperature, .systemPower, .adapter, .powerCombined: true
        default: false
        }
    }
    /// Blocks with their own settings in the builder (chart height, or the forecast's look).
    var hasSettings: Bool { hasChartSize || self == .forecast }
    /// The block that shows a catalog metric's chart (`PowerMetricCard` knows only its catalog id).
    static func block(forChartID id: String) -> OverviewMetric? {
        switch id {
        case "038": .power
        case "039": .temperature
        case "043": .systemPower
        case "054": .adapter
        default: nil
        }
    }
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
    /// The chart height of every block without its own size; the default stays unwritten so untouched preferences stay unchanged.
    var chartSize: MetricChartSize = .standard
    /// A block's own chart height (the builder's expanded row); blocks not listed use `chartSize`.
    var chartSizes: [OverviewMetric: MetricChartSize] = [:]
    /// The user's own layout, kept when a ready-made layout replaced it, so «Своё» brings it back.
    var customLayout: OverviewLayoutSnapshot?
    /// How the «Time to 20%» block looks: one line (default) or the discharge with its extrapolation.
    var forecastStyle: OverviewForecastStyle = .row
    init() {}
    func chartSize(for metric: OverviewMetric) -> MetricChartSize { chartSizes[metric] ?? chartSize }
    /// The blocks shown in the quick menu, in order.
    var visible: [OverviewMetric] { order.filter { !hidden.contains($0) } }
    /// The blocks not shown, in their order.
    var available: [OverviewMetric] { order.filter { hidden.contains($0) } }
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
    private enum CodingKeys: String, CodingKey { case order, hidden, chartSize, chartSizes, customLayout, forecastStyle }
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
        let rawSizes = ((try? values.decodeIfPresent([String: String].self, forKey: .chartSizes)) ?? nil) ?? [:]
        for (key, value) in rawSizes {
            if let metric = OverviewMetric(rawValue: key), metric.hasChartSize, let size = MetricChartSize(rawValue: value) { chartSizes[metric] = size }
        }
        customLayout = (try? values.decodeIfPresent(OverviewLayoutSnapshot.self, forKey: .customLayout)) ?? nil
        forecastStyle = ((try? values.decodeIfPresent(String.self, forKey: .forecastStyle)) ?? nil).flatMap(OverviewForecastStyle.init(rawValue:)) ?? .row
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        if chartSize != .standard { try values.encode(chartSize.rawValue, forKey: .chartSize) }
        if !chartSizes.isEmpty {
            try values.encode(Dictionary(uniqueKeysWithValues: chartSizes.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .chartSizes)
        }
        try values.encodeIfPresent(customLayout, forKey: .customLayout)
        if forecastStyle != .row { try values.encode(forecastStyle.rawValue, forKey: .forecastStyle) }
    }
    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    mutating func move(_ metric: OverviewMetric, by amount: Int) {
        guard let current = order.firstIndex(of: metric), order.indices.contains(current + amount) else { return }
        order.swapAt(current, current + amount)
    }
    /// Shows a block, at the end of the shown ones.
    mutating func add(_ metric: OverviewMetric) {
        guard hidden.contains(metric) else { return }
        hidden.remove(metric)
        order = visible.filter { $0 != metric } + [metric] + available
    }
    /// Hides a block.
    mutating func remove(_ metric: OverviewMetric) { hidden.insert(metric) }
    /// Moves a shown block to a slot among the shown ones (a finished drag in «В меню»).
    mutating func moveVisible(_ metric: OverviewMetric, to index: Int) {
        var shown = visible
        guard let current = shown.firstIndex(of: metric) else { return }
        shown.remove(at: current)
        shown.insert(metric, at: min(max(index, 0), shown.count))
        order = shown + available
    }
    /// Sets one block's chart height; the shared size clears the override.
    mutating func setChartSize(_ size: MetricChartSize, for metric: OverviewMetric) {
        guard metric.hasChartSize else { return }
        chartSizes[metric] = size == chartSize ? nil : size
    }
    /// The ready-made layout the shown blocks match, or nil for the user's own.
    var layoutPreset: OverviewLayoutPreset? { OverviewLayoutPreset.allCases.first { $0.matches(visible) } }
    /// Applies a ready-made layout. Leaving the user's own layout keeps it for «Своё».
    mutating func apply(_ preset: OverviewLayoutPreset) {
        if layoutPreset == nil { customLayout = OverviewLayoutSnapshot(order: order, hidden: hidden) }
        let shown = preset.blocks
        order = shown + order.filter { !shown.contains($0) }
        hidden = Set(OverviewMetric.allCases).subtracting(shown)
    }
    /// Brings back the user's own layout kept by `apply(_:)`.
    mutating func restoreCustomLayout() {
        // Already the user's own layout: nothing to bring back (it would replace the current one with an older snapshot).
        guard layoutPreset != nil, let customLayout else { return }
        order = customLayout.order; hidden = customLayout.hidden
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

/// The shown blocks and their order, kept for «Своё».
struct OverviewLayoutSnapshot: Codable, Equatable {
    var order: [OverviewMetric]
    var hidden: Set<OverviewMetric>
    init(order: [OverviewMetric], hidden: Set<OverviewMetric>) { self.order = order; self.hidden = hidden }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var known: [OverviewMetric] = []
        for id in try values.decode([String].self, forKey: .order) {
            if let metric = OverviewMetric(rawValue: id), !known.contains(metric) { known.append(metric) }
        }
        let additions = OverviewMetric.allCases.filter { !known.contains($0) }
        order = known + additions
        hidden = Set(try values.decode([String].self, forKey: .hidden).compactMap(OverviewMetric.init(rawValue:))).union(additions)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(order.map(\.rawValue), forKey: .order)
        try values.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
    private enum CodingKeys: String, CodingKey { case order, hidden }
}

/// Ready-made Overview layouts in the builder: one tap sets which blocks are shown and in what order.
enum OverviewLayoutPreset: String, CaseIterable, Identifiable {
    case minimum, energy, everything
    var id: String { rawValue }
    var title: String {
        switch self { case .minimum: "Minimum (layout)"; case .energy: "Energy (layout)"; case .everything: "Everything (layout)" }
    }
    var symbol: String {
        switch self { case .minimum: "circle.dashed"; case .energy: "bolt"; case .everything: "square.grid.2x2" }
    }
    /// The shown blocks, in order.
    var blocks: [OverviewMetric] {
        switch self {
        case .minimum: [.forecast, .batteryHealth]
        case .energy: [.powerCombined, .systemPower, .adapter, .temperature]
        case .everything: OverviewMetric.allCases
        }
    }
    /// The exact list, order included: every block in the user's own order is the user's own layout, so applying a
    /// ready-made one keeps it for «Своё».
    func matches(_ shown: [OverviewMetric]) -> Bool { shown == blocks }
}

/// The look of the «Time to 20%» block.
enum OverviewForecastStyle: String, CaseIterable, Codable, Sendable {
    case row, chart
    var title: String { self == .row ? "Line (forecast)" : "Chart (forecast)" }
}

