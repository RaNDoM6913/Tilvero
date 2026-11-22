// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import Charts
import PowerCore

// Building blocks of the main window (direction C). Tiles take value types, never the model, so a telemetry change
// re-renders only the tiles that show it.

/// Green-tinted gradient behind the detail column (opaque paint: unchanged under Reduce Transparency).
struct WindowCanvas: View {
    @Environment(\.windowTheme) private var theme
    var body: some View {
        LinearGradient(colors: [theme.canvasTop.color, theme.canvasBottom.color],
                       startPoint: .topLeading, endPoint: UnitPoint(x: 0.5, y: 0.75))
    }
}

/// A page with sub-page tabs (Battery, Sleep & drain, Settings). The tabs are a toolbar item in the title row, the same
/// control and place as the Overview range picker (owner 2026-11-23). The glass column leaves the toolbar the window's
/// full width, so the tabs no longer fall into the overflow menu as they did beside the system sidebar.
struct WindowTabbedPage<Tabs: View, Content: View>: View {
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxHeight: .infinity, alignment: .top)
            .toolbar { ToolbarItem(placement: .primaryAction) { tabs() } }
    }
}

/// Sub-page tabs: the system segmented picker exactly as the Overview range picker uses it in the toolbar.
struct WindowPageTabs<Value: Hashable & Identifiable>: View {
    let label: String
    @Binding var selection: Value
    let values: [Value]
    let title: (Value) -> String

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(values) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize().labelsHidden()
    }
}

/// Opaque rounded tile.
struct WindowTile<Content: View>: View {
    @Environment(\.windowTheme) private var theme
    var padding: CGFloat = WindowTheme.tilePadding
    @ViewBuilder var content: () -> Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowTheme.tileRadius, style: .continuous)
        content().padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(theme.tileFill.color))
            .overlay(shape.strokeBorder(theme.tileStroke.color, lineWidth: theme.tileStrokeWidth))
    }
}

/// Number with a smaller secondary unit: «18,6» + « Вт».
struct WindowNumber: View {
    @Environment(\.windowTheme) private var theme
    let display: ReadingDisplay
    var size: CGFloat = WindowTheme.tileValueSize
    var tint: Color = .primary
    var body: some View {
        let secondary: Color = theme.secondaryIsPrimary ? .primary : .secondary
        if display.masked {
            Text(display.text).font(.system(size: size, weight: .semibold)).foregroundStyle(secondary)
        } else if let number = display.number {
            let valueTint: Color = display.state == .stale ? secondary : tint
            (Text(display.approximate ? "≈ " : "").foregroundStyle(secondary)
             + Text(number).foregroundStyle(valueTint)
             + Text(display.unit.isEmpty ? "" : " " + display.unit)
                .font(.system(size: size * 0.62, weight: .medium)).foregroundStyle(secondary))
                .font(.system(size: size, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        } else {
            Text("—").font(.system(size: size, weight: .semibold)).foregroundStyle(.tertiary)
        }
    }
}

/// Clock for stale, minus for unavailable: state is never colour alone.
struct ReadingStateBadge: View {
    let state: ReadingDisplay.State
    var body: some View {
        switch state {
        case .stale: Image(systemName: "clock").font(.caption).foregroundStyle(.secondary).accessibilityLabel(L10n.text("Stale"))
        case .unavailable: Image(systemName: "minus.circle").font(.caption).foregroundStyle(.tertiary).accessibilityLabel(L10n.text("Unavailable"))
        case .live, .freshnessUnknown: EmptyView()
        }
    }
}

/// One cell of a reading strip.
struct ReadingStripItem: Identifiable {
    let id: String
    let title: String
    let display: ReadingDisplay
    var tint: Color = .primary
    /// The reading behind the value, for the (i) (meaning, source, freshness).
    var reading: CatalogReading?
}

/// Several readings in one tile, separated by hairlines (avoids a wall of equal tiles).
struct ReadingStrip<Info: View>: View {
    @Environment(\.windowTheme) private var theme
    let items: [ReadingStripItem]
    @ViewBuilder var info: (ReadingStripItem) -> Info
    var body: some View {
        WindowTile(padding: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 14) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(item.title).foregroundStyle(theme.secondaryIsPrimary ? .primary : .secondary).lineLimit(1)
                            info(item)
                            Spacer(minLength: 0)
                            ReadingStateBadge(state: item.display.state)
                        }
                        WindowNumber(display: item.display, tint: item.tint)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Label left, value right, hairline separators; an optional destination makes the row a button with a chevron.
struct WindowRow: Identifiable {
    let id: String
    let label: String
    let value: String
    var dim = false
    var action: (@MainActor () -> Void)?
}

struct WindowRowsTile: View {
    @Environment(\.windowTheme) private var theme
    let rows: [WindowRow]
    var body: some View {
        WindowTile(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row).padding(.horizontal, 16)
                    if index < rows.count - 1 { Divider().padding(.leading, 16) }
                }
            }.padding(.vertical, 4)
        }
    }
    @ViewBuilder private func rowView(_ row: WindowRow) -> some View {
        let content = HStack(spacing: 4) {
            Text(row.label)
            Spacer(minLength: 12)
            Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
                .foregroundStyle(row.dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            if row.action != nil {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }.padding(.vertical, WindowTheme.rowVerticalPadding).contentShape(Rectangle())
        if let action = row.action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// Big lead without a card: 56 pt value, coloured status, one detail line.
struct LeadLine<Info: View>: View {
    @Environment(\.windowTheme) private var theme
    let lead: LeadDisplay
    @ViewBuilder var info: () -> Info
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(lead.value).font(.system(size: WindowTheme.leadValueSize, weight: .semibold)).monospacedDigit()
                .foregroundStyle(lead.stale || lead.value == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if lead.stale { Image(systemName: "clock").foregroundStyle(.orange).accessibilityHidden(true) }
                    Text(lead.status).font(.system(size: 15, weight: .semibold)).foregroundStyle(Self.color(lead.tone))
                    info()
                }
                if !lead.detail.isEmpty {
                    Text(lead.detail).foregroundStyle(theme.secondaryIsPrimary ? .primary : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
    static func color(_ tone: LeadDisplay.Tone) -> Color {
        switch tone {
        case .accent: WindowTheme.accent
        case .input: WindowTheme.inputPower
        case .battery: WindowTheme.batteryPower
        case .attention: .orange
        case .neutral: .primary
        case .secondary: .secondary
        }
    }
}

/// Title (with its unit) and the range word, trailing content (legend or link).
struct TileHeading<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// Empty / unavailable frame inside a chart tile (fixed height, no "empty" claim while loading).
struct EmptyFrame: View {
    let symbol: String
    let title: String
    var detail: String?
    var loading = false
    var height: CGFloat = 110
    var body: some View {
        VStack(spacing: 6) {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary).accessibilityHidden(true) }
            if !loading {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                if let detail { Text(detail).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
            }
        }.frame(maxWidth: .infinity, minHeight: height)
    }
}

/// One notice under the lead: icon, text, at most one button.
struct NoticeTile: View {
    let symbol: String
    let text: String
    var tint: Color = .orange
    var button: (title: String, action: @MainActor () -> Void)?
    var body: some View {
        WindowTile(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let button { Button(button.title, action: button.action) }
            }
        }
    }
}

/// Legend dot + word.
struct ChartLegendItem: View {
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
        }
    }
}

/// One line of a window chart.
struct WindowChartSeries: Identifiable {
    let id: String
    let points: [HistoryChartPoint]
    let color: Color
}

/// A stretch without recorded points between two drawn segments of one line (drawn dashed).
struct WindowChartGap: Identifiable {
    let id: String
    let start: HistoryChartPoint
    let end: HistoryChartPoint

    /// Connectors between consecutive segments of each line. Nothing is invented: the dash joins two recorded points
    /// and only marks that the time between them has no measurements.
    static func connectors(_ series: [WindowChartSeries]) -> [WindowChartGap] {
        var result: [WindowChartGap] = []
        for line in series {
            for (index, pair) in zip(line.points, line.points.dropFirst()).enumerated() where pair.1.series != pair.0.series {
                result.append(WindowChartGap(id: line.id + "|gap\(index)", start: pair.0, end: pair.1))
            }
        }
        return result
    }
}

/// Swift Charts line chart of the window: trailing Y axis, coordinate grid (horizontal at the value marks, vertical at
/// quarters of the window), no area fill. Gaps stay gaps: a new `series` id breaks the solid line and the empty time
/// is drawn as a grey dashed connector. X labels under the plot (start, middle, end of the window).
struct WindowLineChart: View {
    let series: [WindowChartSeries]
    let window: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    var yValues: [Double]?
    var xLabels: [String]
    static let gridStyle = Color.secondary.opacity(0.22)
    static let gapStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4])

    private var verticalGrid: [Date] {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        return (0...4).map { window.lowerBound.addingTimeInterval(span * Double($0) / 4) }
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(WindowChartGap.connectors(series)) { gap in
                    LineMark(x: .value("Time", gap.start.date), y: .value("Value", gap.start.value), series: .value("Series", gap.id))
                        .foregroundStyle(Color.secondary).lineStyle(Self.gapStroke)
                    LineMark(x: .value("Time", gap.end.date), y: .value("Value", gap.end.value), series: .value("Series", gap.id))
                        .foregroundStyle(Color.secondary).lineStyle(Self.gapStroke)
                }
                ForEach(series) { line in
                    ForEach(line.points) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Value", point.value),
                                 series: .value("Series", line.id + "|" + point.series))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                }
            }
            .chartXScale(domain: window)
            .chartXAxis {
                AxisMarks(values: verticalGrid) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6)).foregroundStyle(Self.gridStyle)
                }
            }
            .chartYScale(domain: yDomain)
            .chartLegend(.hidden)
            .chartYAxis {
                if let yValues {
                    AxisMarks(position: .trailing, values: yValues) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6)).foregroundStyle(Self.gridStyle)
                        AxisValueLabel().font(.system(size: 10))
                    }
                } else {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6)).foregroundStyle(Self.gridStyle)
                        AxisValueLabel().font(.system(size: 10))
                    }
                }
            }
            if !xLabels.isEmpty {
                HStack {
                    ForEach(Array(xLabels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer(minLength: 4) }
                        Text(label)
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.trailing, 26)
                .accessibilityHidden(true)
            }
        }
    }
}
