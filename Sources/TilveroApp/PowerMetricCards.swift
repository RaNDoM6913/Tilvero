// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import Charts
import PowerCore
import PowerPersistence

enum PowerMetricHistory {
    struct Summary { let count: Int; let minimum: Double; let mean: Double; let maximum: Double }
    static func summary(_ points: [HistoryChartPoint]) -> Summary? {
        guard let last = points.last else { return nil }
        let values = points.filter { $0.series == last.series }.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        return .init(count: values.count, minimum: low, mean: values.reduce(0) { $0 + $1 / Double(values.count) }, maximum: high)
    }

    /// These are recorded observations, not proof of an independent hardware sample time.
    static func points(_ samples: [HistorySample], id: String, since: Date) -> [HistoryChartPoint] {
        var result: [HistoryChartPoint] = [], gap = 0
        var last: HistorySample?, source: String?
        for sample in samples.sorted(by: { $0.collectedAt < $1.collectedAt }) where sample.collectedAt >= since {
            guard !sample.isAggregate, let reading = sample.readings.first(where: { $0.id == id }),
                  reading.availability == .available, reading.freshness != .stale,
                  let value = reading.value?.doubleValue, value.isFinite else { gap += 1; last = nil; continue }
            let channel = reading.keyPath.hasPrefix("observed-v2/")
                ? reading.source + "|" + reading.keyPath + "|" + (reading.unit ?? "")
                : "unidentified:" + sample.id.uuidString
            if let last, sample.collectedAt.timeIntervalSince(last.collectedAt) > 120 || sample.isExternalPower != last.isExternalPower || source != channel { gap += 1 }
            result.append(.init(id: sample.id, date: sample.collectedAt, value: value, series: sample.segmentID.uuidString + ":\(gap)"))
            last = sample; source = channel
        }
        return result
    }
}

@MainActor struct PowerMetricCard: View {
    @ObservedObject var model: TilveroModel
    let title: String
    let symbol: String
    let id: String
    var color: Color = .orange
    /// The adapter card renders its own caption list so the absent message appears exactly once.
    var showsCaptions = true
    /// Replaces the default caption list (the adapter card adds its rated-capability line).
    var captionOverride: [String]?
    /// Sparkline (default, unchanged look) or the full chart with a value axis.
    var style: MetricChartStyle = .sparkline
    private var reading: CatalogReading? { model.snapshot.catalog.first { $0.id == id } }
    private var adapterConnected: Bool { model.snapshot.adapterIsConnected }
    /// `absentInChart`: the chart's dashed frame already carries the adapter-absent message, so the list must not repeat it.
    static func captionLines(id: String, reading: CatalogReading?, adapterConnected: Bool, absentInChart: Bool = false) -> [String] {
        [absentInChart ? nil : MetricCaption.absent(for: id, adapterConnected: adapterConnected),
         MetricCaption.boundary(for: id, reading: reading)].compactMap { $0 }
    }
    /// An adapter known to be unplugged has no input to draw: earlier history (including a measured 0 W) is not shown.
    static func drawsHistory(id: String, adapterConnected: Bool) -> Bool { id != "054" || adapterConnected }
    /// Message inside the dashed empty frame: the adapter-absent message for an unplugged adapter, otherwise the generic one.
    static func chartEmptyMessage(id: String, adapterConnected: Bool) -> String {
        MetricCaption.absent(for: id, adapterConnected: adapterConnected) ?? L10n.text("No recorded measurements yet")
    }
    /// Only battery power, system, adapter input and temperature can take the full chart.
    static func showsChart(id: String, style: MetricChartStyle) -> Bool {
        style == .chart && ["038", "043", "054", "039"].contains(id)
    }
    /// Temperature and capacity retention never had a sparkline on the quick page.
    /// The rounded card chrome frames chart-style cards only; sparkline cards stay bare.
    static func showsChrome(id: String, style: MetricChartStyle) -> Bool { showsChart(id: id, style: style) }
    static func showsSparkline(id: String, style: MetricChartStyle) -> Bool {
        id != "039" && id != "026" && !showsChart(id: id, style: style)
    }
    /// Axis unit: the reading's own unit (localised), the metric's natural unit when
    /// the reading is missing, and Fahrenheit for a converted temperature.
    static func chartUnit(id: String, readingUnit: String?, fahrenheit: Bool, language: String = L10n.language) -> String {
        if id == "039" && fahrenheit { return "°F" }
        return CatalogDataPresentation.unit(readingUnit ?? (id == "039" ? "°C" : "W"), language: language)
    }
    static func chartValue(_ value: Double, id: String, fahrenheit: Bool) -> Double {
        id == "039" && fahrenheit ? value * 9 / 5 + 32 : value
    }
    var body: some View {
        content.modifier(OptionalCardChrome(isOn: Self.showsChrome(id: id, style: style)))
    }
    private var content: some View {
        let captions = showsCaptions ? (captionOverride ?? Self.captionLines(id: id, reading: reading, adapterConnected: adapterConnected,
                                                                             absentInChart: Self.showsChart(id: id, style: style))) : []
        // A chart below regular height keeps its caption in the header line instead of a line of its own.
        let inlineCaption = Self.showsChart(id: id, style: style) && model.overviewPreferences.chartSize != .regular
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text(title), systemImage: symbol)
                if inlineCaption, !captions.isEmpty {
                    Text(captions.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                StudioText(reading.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: model.fahrenheit) } ?? "—", id: "powerMetric." + id + ".value").monospacedDigit()
                if reading?.freshness == .stale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange) }
            }.font(.subheadline)
            if !inlineCaption {
                ForEach(captions, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            if Self.showsChart(id: id, style: style) {
                chart
            } else if Self.showsSparkline(id: id, style: style), Self.drawsHistory(id: id, adapterConnected: adapterConnected) {
                MetricSparkline(model: model, id: id, color: color)
            }
        }.help(reading.map { L10n.text("Source") + ": " + $0.source + " · " + L10n.text("Freshness") + ": " + $0.freshness.rawValue + "\n" + L10n.text($0.reason ?? "Recorded observations during the last hour.") } ?? L10n.text("Unavailable"))
    }
}

private struct OptionalCardChrome: ViewModifier {
    let isOn: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isOn { content.metricCardChrome() } else { content }
    }
}

extension PowerMetricCard {
    @ViewBuilder fileprivate var chart: some View {
        let fahrenheit = model.fahrenheit
        let series = model.chartSeries(id: id).convertingValues { Self.chartValue($0, id: id, fahrenheit: fahrenheit) }
        MetricChartView(
            specs: [MetricChartSeriesSpec(id: id, series: series, color: color, endLabel: nil)],
            scale: MetricChartScale.scale(forMetric: id, values: series.points.map(\.value)),
            window: model.overviewChartWindow,
            unit: Self.chartUnit(id: id, readingUnit: reading?.unit, fahrenheit: fahrenheit),
            density: model.overviewPreferences.chartSize.density,
            emptyMessage: Self.chartEmptyMessage(id: id, adapterConnected: adapterConnected))
    }
}

extension TilveroModel {
    /// Series the single-metric charts (variants A and B) draw. An adapter known to be unplugged gets an
    /// empty series (dashed frame), not whatever 054 history the last hour holds; unknown external power draws it.
    func chartSeries(id: String) -> MetricChartSeries {
        guard PowerMetricCard.drawsHistory(id: id, adapterConnected: snapshot.adapterIsConnected) else {
            return MetricChartSeries.make(points: [], window: overviewChartWindow, now: snapshot.collectedAt)
        }
        return metricSeries(id: id)
    }
}

extension MetricChartSeries {
    /// The same series with every value mapped (unit conversion); dates, gaps and state are untouched.
    func convertingValues(_ transform: (Double) -> Double) -> MetricChartSeries {
        func map(_ point: HistoryChartPoint) -> HistoryChartPoint {
            HistoryChartPoint(id: point.id, date: point.date, value: transform(point.value), series: point.series)
        }
        return MetricChartSeries(points: points.map(map), gaps: gaps.map { .init(start: map($0.start), end: map($0.end)) },
                                 isolatedPoints: isolatedPoints.map(map), staleSince: staleSince, state: state)
    }
}

@MainActor struct MetricSparkline: View {
    @ObservedObject var model: TilveroModel
    let id: String
    var color: Color
    private var points: [HistoryChartPoint] { PowerMetricHistory.points(model.history, id: id, since: model.snapshot.collectedAt.addingTimeInterval(-3600)) }
    var body: some View {
        if !points.isEmpty {
            Chart(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value), series: .value("Segment", point.series))
                    .foregroundStyle(color).interpolationMethod(.linear)
                PointMark(x: .value("Time", point.date), y: .value("Value", point.value)).foregroundStyle(color).symbolSize(3)
            }.chartXScale(domain: model.snapshot.collectedAt.addingTimeInterval(-3600)...model.snapshot.collectedAt)
                .chartYScale(domain: .automatic(includesZero: true)).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 28)
                .accessibilityLabel(L10n.text("Recorded observations during the last hour."))
                .help(L10n.text("Recorded observations during the last hour."))
        } else {
            Text(L10n.text("No recorded measurements yet")).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct AdapterMetricCard: View {
    @ObservedObject var model: TilveroModel
    var style: MetricChartStyle = .sparkline
    private var inputReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "054" } }
    private var ratingReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "050" } }
    /// Unknown external-power state is not reported as "not connected".
    private var adapterConnected: Bool { model.snapshot.adapterIsConnected }
    /// Every caption line of the card body below the metric row, in display order. `absentInChart`: the chart frame carries the absent message.
    static func captionLines(input: CatalogReading?, rating: CatalogReading?, adapterConnected: Bool, absentInChart: Bool = false) -> [String] {
        let value = rating.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: false) } ?? "—"
        return PowerMetricCard.captionLines(id: "054", reading: input, adapterConnected: adapterConnected, absentInChart: absentInChart)
            + [L10n.text("Rated capability") + ": " + value]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if style == .chart {
                // The captions sit under the title, above the chart, as in the sparkline-free layout.
                PowerMetricCard(model: model, title: "Adapter input", symbol: "powerplug", id: "054", color: .blue,
                                captionOverride: Self.captionLines(input: inputReading, rating: ratingReading, adapterConnected: adapterConnected, absentInChart: true), style: style)
            } else {
                PowerMetricCard(model: model, title: "Adapter input", symbol: "powerplug", id: "054", color: .blue, showsCaptions: false, style: style)
                ForEach(Self.captionLines(input: inputReading, rating: ratingReading, adapterConnected: adapterConnected), id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.help(L10n.text("Adapter input and battery power measure different electrical boundaries. Rated capability is not current consumption."))
    }
}

@MainActor struct BatteryHealthMetricCard: View {
    @ObservedObject var model: TilveroModel
    private func value(_ id: String) -> String {
        model.snapshot.catalog.first { $0.id == id }.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: false) } ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PowerMetricCard(model: model, title: "Capacity retention", symbol: "heart", id: "026", color: .pink)
            HStack { Text(L10n.text("Cycle count") + ": " + value("027")); Spacer(); Text(value("030") + " / " + value("029")) }
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.help(L10n.text("Calculated full-charge / design capacity. This is distinct from the macOS maximum-capacity estimate."))
    }
}

@MainActor struct PowerObservationsPanel: View {
    @ObservedObject var model: TilveroModel
    private let fields = ["043", "054", "038", "039", "026"]
    private var availableSummaries: [(CatalogReading, PowerMetricHistory.Summary)] {
        fields.compactMap { id in
            guard let reading = model.snapshot.catalog.first(where: { $0.id == id }),
                  let summary = PowerMetricHistory.summary(PowerMetricHistory.points(model.history, id: id, since: model.snapshot.collectedAt.addingTimeInterval(-3600))) else { return nil }
            return (reading, summary)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if availableSummaries.isEmpty {
                ProductSurface(title: "Recorded observations", symbol: "chart.xyaxis.line") {
                    Label(L10n.text("No recorded measurements yet"), systemImage: "chart.xyaxis.line")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(availableSummaries, id: \.0.id) { reading, summary in
                ProductSurface(studioID: "power.observations." + reading.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(L10n.language == "ru" ? reading.titleRussian : reading.titleEnglish).font(.headline)
                        Spacer(minLength: 8)
                        Text(L10n.text("Observations") + ": \(summary.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .topLeading)], alignment: .leading, spacing: 14) {
                        statistic("Minimum", summary.minimum, reading)
                        statistic("Observation mean", summary.mean, reading)
                        statistic("Maximum", summary.maximum, reading)
                    }
                    if reading.id != "039" && reading.id != "026" {
                        MetricSparkline(model: model, id: reading.id, color: .accentColor)
                    }
                }
            }
            Text(L10n.text("Statistics use the latest comparable continuous segment within the last hour. Means describe recorded observations; unknown sensor timing is not upgraded to measured energy."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func statistic(_ title: String, _ value: Double, _ reading: CatalogReading) -> some View {
        ProductMetric(title: title, value: format(value, reading))
    }
    private func format(_ value: Double, _ reading: CatalogReading) -> String {
        let fahrenheit = model.fahrenheit && reading.unit == "°C"
        let number = fahrenheit ? value * 9 / 5 + 32 : value
        return number.formatted(.number.locale(L10n.locale).precision(.fractionLength(0...2))) + " " + (fahrenheit ? "°F" : CatalogDataPresentation.unit(reading.unit ?? ""))
    }
}
