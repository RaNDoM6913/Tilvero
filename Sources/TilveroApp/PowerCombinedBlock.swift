// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// Overview variant C: one card, one shared watt axis, two lines - battery power
/// ("038") and adapter input ("054"). Lines are named by end labels next to the
/// newest points, never by a legend (and there is no caption). An absent
/// adapter draws no line, only one message under the plot.
@MainActor struct PowerCombinedBlock: View {
    @ObservedObject var model: TilveroModel

    /// Pure text and drawing decisions, so wording and which lines exist are testable without a view tree.
    struct Content: Equatable {
        let title: String
        /// "Battery −10,0": title and the number of the shared presentation; nil without a reading.
        let batteryLabel: String?
        let adapterLabel: String?
        /// False when the adapter is known to be unplugged: no adapter series, no axis share.
        let drawsAdapter: Bool
        /// The single "no adapter line" message, shown only for a known-absent adapter.
        let absentMessage: String?
        let isStale: Bool
    }

    static let batteryColor = Color.orange
    static let adapterColor = Color.blue

    static func content(battery: CatalogReading?, adapter: CatalogReading?, adapterConnected: Bool, fahrenheit: Bool = false) -> Content {
        Content(
            title: L10n.text("Power"),
            batteryLabel: endLabel(titleKey: "Battery (short)", reading: battery, fahrenheit: fahrenheit),
            adapterLabel: adapterConnected ? endLabel(titleKey: "Adapter", reading: adapter, fahrenheit: fahrenheit) : nil,
            drawsAdapter: adapterConnected,
            absentMessage: adapterConnected ? nil : L10n.text(MetricCaption.combinedAdapterNoLineKey),
            isStale: battery?.freshness == .stale)
    }

    /// "Title value" built from the shared presentation: the approximation prefix and the unit
    /// belong to the axis and the caption, so the label keeps only the title and the number.
    static func endLabel(titleKey: String, reading: CatalogReading?, fahrenheit: Bool) -> String? {
        guard let reading else { return nil }
        var value = CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit)
        guard value != "—" else { return nil }
        if value.hasPrefix("≈ ") { value.removeFirst(2) }
        if let unit = reading.unit {
            let shown = CatalogDataPresentation.unit(unit)
            if value.hasSuffix(" " + shown) { value.removeLast(shown.count + 1) }
        }
        return L10n.text(titleKey) + " " + value
    }

    /// The series that are drawn: always the battery, the adapter only when it is not known to be unplugged.
    static func specs(content: Content, battery: MetricChartSeries, adapter: MetricChartSeries?) -> [MetricChartSeriesSpec] {
        var result = [MetricChartSeriesSpec(id: "038", series: battery, color: batteryColor, endLabel: content.batteryLabel)]
        if content.drawsAdapter, let adapter {
            result.append(MetricChartSeriesSpec(id: "054", series: adapter, color: adapterColor, endLabel: content.adapterLabel))
        }
        return result
    }

    /// One scale for both lines: built from the union of the values that are drawn.
    static func combinedScale(battery: MetricChartSeries, adapter: MetricChartSeries?) -> MetricChartScale? {
        MetricChartScale.scale(forMetric: "038", values: (battery.points + (adapter?.points ?? [])).map(\.value))
    }

    private var batteryReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "038" } }
    private var adapterReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "054" } }

    var body: some View {
        // Unknown external-power state is not reported as "not connected".
        let content = Self.content(battery: batteryReading, adapter: adapterReading,
                                   adapterConnected: model.snapshot.adapterIsConnected, fahrenheit: model.fahrenheit)
        let battery = model.metricSeries(id: "038")
        let adapter = content.drawsAdapter ? model.metricSeries(id: "054") : nil
        VStack(alignment: .leading, spacing: 6) {
            Label(content.title, systemImage: "bolt").font(.subheadline).lineLimit(1)
            // A stale reading mutes the heading; the chart itself marks the stale tail.
            .opacity(content.isStale ? 0.6 : 1)
            MetricChartView(
                specs: Self.specs(content: content, battery: battery, adapter: adapter),
                scale: Self.combinedScale(battery: battery, adapter: adapter),
                window: model.overviewChartWindow,
                unit: PowerMetricCard.chartUnit(id: "038", readingUnit: batteryReading?.unit, fahrenheit: false),
                density: model.overviewPreferences.chartSize.density,
                emptyMessage: L10n.text("No recorded measurements yet"),
                fillsSingleSeries: false)
            if let message = content.absentMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .metricCardChrome()
    }
}
// tlv-origin:d83f5a2c91e07b64
