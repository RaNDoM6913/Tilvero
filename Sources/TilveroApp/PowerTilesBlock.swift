// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// Overview variant B: two equal compact tiles, battery power ("038") and adapter
/// input ("054"). Each tile is a title, the value and a compact chart (no caption);
/// no data gives a dashed frame, never a zero.
@MainActor struct PowerTilesBlock: View {
    @ObservedObject var model: TilveroModel

    /// Pure text decisions of one tile, so fitting and wording are testable without a view tree.
    struct TileContent: Equatable {
        let title: String
        let value: String
        /// The adapter-absent message of a known-unplugged adapter. It is drawn once, inside the dashed chart frame, never as a caption.
        let absentMessage: String?
        let isStale: Bool
    }

    static let tileIDs = ["038", "054"]
    static let spacing: CGFloat = 8

    static func tileLines(id: String, reading: CatalogReading?, adapterConnected: Bool, fahrenheit: Bool = false) -> TileContent {
        let title = L10n.text(id == "054" ? "Adapter" : "Battery (short)")
        let value = reading.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: fahrenheit) } ?? "—"
        let absent = MetricCaption.absent(for: id, adapterConnected: adapterConnected)
        return TileContent(title: title, value: value, absentMessage: absent, isStale: reading?.freshness == .stale)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(Self.tileIDs, id: \.self) { id in
                PowerTile(model: model, id: id, color: id == "054" ? .blue : .orange)
            }
        }
        // The tiles stretch to the taller one (maxHeight below) but never to the height a container offers.
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private struct PowerTile: View {
    @ObservedObject var model: TilveroModel
    let id: String
    let color: Color
    private var reading: CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        let content = PowerTilesBlock.tileLines(id: id, reading: reading, adapterConnected: model.snapshot.adapterIsConnected, fahrenheit: model.fahrenheit)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(content.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if content.isStale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
            }
            StudioText(content.value, id: "powerTile." + id + ".value")
                .font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            chart(absentMessage: content.absentMessage)
        }
        // Equal tiles: the shorter one stretches to the taller one before the card chrome draws its background.
        .frame(maxHeight: .infinity, alignment: .top)
        .metricCardChrome(padding: 10)
    }

    /// Only adapter input (054) has live points among the tiles; battery power stays recorded once a minute.
    private var liveNote: String {
        guard model.wantsLiveCharts, !model.live.tail.points(id: id).isEmpty else { return "" }
        return L10n.text("Newest minutes: live SMC readings, about once a second.")
    }
    @ViewBuilder private func chart(absentMessage: String?) -> some View {
        LiveRefresh(store: model.live) {
            let series = model.chartSeries(id: id)
            MetricChartView(
                specs: [MetricChartSeriesSpec(id: id, series: series, color: color, endLabel: nil)],
                scale: MetricChartScale.scale(forMetric: id, values: series.points.map(\.value)),
                window: model.overviewChartWindow,
                unit: PowerMetricCard.chartUnit(id: id, readingUnit: reading?.unit, fahrenheit: false),
                density: .compact,
                emptyMessage: absentMessage ?? L10n.text("Chart: no data"))
        }.help(liveNote)
    }
}
// tlv-origin:b4e07a19d3c258f6
