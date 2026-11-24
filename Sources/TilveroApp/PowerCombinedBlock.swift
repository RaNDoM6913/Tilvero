// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// Overview variant C: one card, one shared watt axis, two lines - battery power
/// ("038") and adapter input ("054"). The lines are named by a compact legend in the
/// card header (plug + adapter watts in blue, battery + battery watts in orange, then
/// the unit), so the plot keeps the full card width. There is no caption: an absent
/// adapter shows "—" in the legend and draws no line.
@MainActor struct PowerCombinedBlock: View {
    var model: TilveroModel

    /// Pure text and drawing decisions, so wording and which lines exist are testable without a view tree.
    struct Content: Equatable {
        let title: String
        /// Number of the shared presentation (no unit, no approximation prefix); nil without a reading: shown as "—", never as a zero.
        let batteryValue: String?
        /// Nil for an unplugged adapter and for a missing reading.
        let adapterValue: String?
        /// False when the adapter is known to be unplugged: no adapter series, no axis share.
        let drawsAdapter: Bool
        let isStale: Bool
        /// "Battery -10,0" ("Battery —" without a reading): the spoken name of the battery line (VoiceOver and tooltips; nothing visible prints it).
        let batteryLabel: String
        /// Nil while the adapter is known to be unplugged (no line).
        let adapterLabel: String?
        /// The whole legend in words: "Battery -10,0, Adapter 38,2"; a known-unplugged adapter says so once.
        let legendDescription: String
    }

    static let batteryColor = Color.orange
    static let adapterColor = Color.blue

    static func content(battery: CatalogReading?, adapter: CatalogReading?, adapterConnected: Bool, fahrenheit: Bool = false) -> Content {
        let batteryValue = plainValue(battery, fahrenheit: fahrenheit)
        let adapterValue = adapterConnected ? plainValue(adapter, fahrenheit: fahrenheit) : nil
        // A drawn line always has a spoken name; a missing value is spoken as the same dash the legend shows.
        let batteryLabel = L10n.text("Battery (short)") + " " + (batteryValue ?? "—")
        let adapterLabel = adapterConnected ? L10n.text("Adapter") + " " + (adapterValue ?? "—") : nil
        var spoken = [batteryLabel, adapterLabel].compactMap { $0 }
        if !adapterConnected { spoken.append(L10n.text(MetricCaption.adapterAbsentKey)) }
        return Content(
            title: L10n.text("Power"),
            batteryValue: batteryValue,
            adapterValue: adapterValue,
            drawsAdapter: adapterConnected,
            isStale: battery?.freshness == .stale,
            batteryLabel: batteryLabel,
            adapterLabel: adapterLabel,
            legendDescription: spoken.joined(separator: ", "))
    }

    /// The number of the shared presentation: the approximation prefix and the unit belong to the
    /// heading's unit and the tooltip, so the legend keeps only the digits (and the minus sign of a discharge).
    static func plainValue(_ reading: CatalogReading?, fahrenheit: Bool) -> String? {
        guard let reading else { return nil }
        var value = CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit)
        guard value != "—" else { return nil }
        if value.hasPrefix("≈ ") { value.removeFirst(2) }
        if let unit = reading.unit {
            let shown = CatalogDataPresentation.unit(unit)
            if value.hasSuffix(" " + shown) { value.removeLast(shown.count + 1) }
        }
        return value
    }

    /// The series that are drawn: always the battery, the adapter only when it is not known to be unplugged.
    static func specs(content: Content, battery: MetricChartSeries, adapter: MetricChartSeries?) -> [MetricChartSeriesSpec] {
        var result = [MetricChartSeriesSpec(id: "038", series: battery, color: batteryColor, accessibilityName: content.batteryLabel)]
        if content.drawsAdapter, let adapter {
            result.append(MetricChartSeriesSpec(id: "054", series: adapter, color: adapterColor, accessibilityName: content.adapterLabel))
        }
        return result
    }

    /// One scale for both lines: built from the union of the values that are drawn.
    static func combinedScale(battery: MetricChartSeries, adapter: MetricChartSeries?) -> MetricChartScale? {
        MetricChartScale.scale(forMetric: "038", values: (battery.points + (adapter?.points ?? [])).map(\.value))
    }

    private var batteryReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "038" } }
    private var adapterReading: CatalogReading? { model.snapshot.catalog.first { $0.id == "054" } }

    /// The newest minutes of the battery and adapter lines are live SMC readings.
    private var liveNote: String {
        guard model.wantsLiveCharts, !model.live.tail.points(id: "038").isEmpty || !model.live.tail.points(id: "054").isEmpty else { return "" }
        return L10n.text("Newest minutes: live SMC readings, about once a second.")
    }

    /// Plug + adapter watts, battery + battery watts, unit. A missing value is a muted "—"; the icons are
    /// hidden from VoiceOver because the whole legend is one element that reads the words.
    private static func legend(content: Content, unit: String) -> some View {
        HStack(spacing: 10) {
            legendGroup(symbol: "powerplug.fill", value: content.adapterValue, color: adapterColor)
            legendGroup(symbol: "battery.50percent", value: content.batteryValue, color: batteryColor)
            Text(unit).foregroundStyle(.secondary).lineLimit(1)
        }
        .monospacedDigit().fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel(content.legendDescription)
        .help(content.legendDescription)
    }

    /// The icon carries the series colour (it matches the chart line); the number stays in the primary text colour
    /// for readability, like the values of the other Overview blocks.
    private static func legendGroup(symbol: String, value: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 12)).accessibilityHidden(true)
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            Text(value ?? "—").lineLimit(1)
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    /// Title on the left, legend on the right; the legend is never truncated. A stale reading mutes the whole heading
    /// (the chart itself marks the stale tail).
    static func header(content: Content, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(content.title, systemImage: "bolt").font(.overviewBlockTitle).lineLimit(1)
            Spacer(minLength: 8)
            legend(content: content, unit: unit)
        }
        .font(.system(size: 13, weight: .medium))
        .opacity(content.isStale ? 0.6 : 1)
    }

    var body: some View {
        // Unknown external-power state is not reported as "not connected".
        let content = Self.content(battery: batteryReading, adapter: adapterReading,
                                   adapterConnected: model.snapshot.adapterIsConnected, fahrenheit: model.fahrenheit)
        let unit = PowerMetricCard.chartUnit(id: "038", readingUnit: batteryReading?.unit, fahrenheit: false)
        VStack(alignment: .leading, spacing: 6) {
            Self.header(content: content, unit: unit)
            LiveRefresh(store: model.live) {
                // Read inside the live wrapper: the series follow every live tick.
                let battery = model.metricSeries(id: "038")
                let adapter = content.drawsAdapter ? model.metricSeries(id: "054") : nil
                MetricChartView(
                    specs: Self.specs(content: content, battery: battery, adapter: adapter),
                    scale: Self.combinedScale(battery: battery, adapter: adapter),
                    window: model.overviewChartWindow,
                    unit: unit,
                    density: model.overviewPreferences.chartSize(for: .powerCombined).density,
                    emptyMessage: L10n.text("No recorded measurements yet"),
                    fillsSingleSeries: false)
            }.help(liveNote)
        }
        .metricCardChrome()
    }
}
// tlv-origin:d83f5a2c91e07b64
