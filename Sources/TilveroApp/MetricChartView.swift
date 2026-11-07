// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

/// One line of a chart: the pure series, its colour and an optional end label
/// (drawn next to the newest point instead of a legend).
struct MetricChartSeriesSpec: Identifiable {
    let id: String
    let series: MetricChartSeries
    let color: Color
    let endLabel: String?
}

/// Shared zebra chart: horizontal bands between value ticks, a unit-labelled
/// value axis, time labels, hatched gaps, a muted stale tail and a dashed empty
/// frame. All layout decisions come from `layout(specs:scale:density:)`.
@MainActor
struct MetricChartView: View {
    enum Density { case full, compact }

    struct Layout: Equatable {
        var bandCount: Int
        var hasLegend: Bool
        var hatchedGapCount: Int
        var isDashedEmpty: Bool
        var staleMuted: Bool
        var valueTickCount: Int
        var timeTickCount: Int
    }

    let specs: [MetricChartSeriesSpec]
    let scale: MetricChartScale?
    let window: ClosedRange<Date>
    let unit: String
    let density: Density
    let emptyMessage: String?

    init(
        specs: [MetricChartSeriesSpec], scale: MetricChartScale?, window: ClosedRange<Date>,
        unit: String, density: Density, emptyMessage: String? = nil
    ) {
        self.specs = specs
        self.scale = scale
        self.window = window
        self.unit = unit
        self.density = density
        self.emptyMessage = emptyMessage
    }

    // MARK: Pure layout decisions

    /// With no recorded point (or no scale) the chart is a dashed empty frame
    /// without axes. Otherwise there is one band per tick interval and never a
    /// legend. Compact density labels at most every second tick (from the top)
    /// once the scale has more than four ticks.
    nonisolated static func layout(specs: [MetricChartSeriesSpec], scale: MetricChartScale?, density: Density) -> Layout {
        guard specs.contains(where: { $0.series.state != .empty }), let scale, scale.ticks.count > 1 else {
            return Layout(bandCount: 0, hasLegend: false, hatchedGapCount: 0, isDashedEmpty: true,
                          staleMuted: false, valueTickCount: 0, timeTickCount: 0)
        }
        let gapRanges = Set(specs.flatMap { $0.series.gaps.map { [$0.start.date, $0.end.date] } })
        return Layout(
            bandCount: scale.ticks.count - 1,
            hasLegend: false,
            hatchedGapCount: gapRanges.count,
            isDashedEmpty: false,
            staleMuted: specs.contains { $0.series.state == .staleTail },
            valueTickCount: labelledTickIndices(count: scale.ticks.count, density: density).count,
            timeTickCount: density == .full ? 5 : 2
        )
    }

    nonisolated static func labelledTickIndices(count: Int, density: Density) -> [Int] {
        guard density == .compact, count > 4 else { return Array(0..<count) }
        return (0..<count).filter { (count - 1 - $0) % 2 == 0 }
    }

    /// Spreads end-label centres so neighbours keep `minGap` apart inside `height`.
    nonisolated static func spreadLabels(_ ys: [CGFloat], minGap: CGFloat, height: CGFloat) -> [CGFloat] {
        let order = ys.indices.sorted { ys[$0] < ys[$1] }
        var placed = ys
        for (n, index) in order.enumerated() {
            let floor = n == 0 ? minGap / 2 : placed[order[n - 1]] + minGap
            placed[index] = max(ys[index], floor)
        }
        if let last = order.last, placed[last] > height - minGap / 2 {
            let shift = placed[last] - (height - minGap / 2)
            for index in order { placed[index] = max(minGap / 2, placed[index] - shift) }
        }
        return placed
    }

    // MARK: View

    private var plotHeight: CGFloat { density == .full ? 120 : 70 }
    private let axisWidth: CGFloat = 30
    private let gutter: CGFloat = 6
    private var endLabelWidth: CGFloat { specs.contains { $0.endLabel != nil } ? 84 : 0 }

    var body: some View {
        let layout = Self.layout(specs: specs, scale: scale, density: density)
        if layout.isDashedEmpty {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: plotHeight)
                .overlay(Text(emptyMessage ?? "—").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 8))
        } else if let scale {
            VStack(alignment: .leading, spacing: 3) {
                Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                plot(layout: layout, scale: scale).frame(height: plotHeight)
                timeLabels(layout: layout)
            }
        }
    }

    private func plot(layout: Layout, scale: MetricChartScale) -> some View {
        GeometryReader { proxy in
            let rect = CGRect(x: axisWidth + gutter, y: 0,
                              width: max(proxy.size.width - axisWidth - gutter - endLabelWidth, 1), height: plotHeight)
            let domain = scale.domain
            let ys = specs.map { spec in spec.series.points.last.map { yValue($0.value, domain) } ?? -1 }
            let spread = Self.spreadLabels(ys, minGap: 14, height: plotHeight)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(&context, rect: rect, scale: scale) }
                ForEach(Self.labelledTickIndices(count: scale.ticks.count, density: density), id: \.self) { index in
                    Text(scale.ticks[index].formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: axisWidth, alignment: .trailing)
                        .position(x: axisWidth / 2, y: yValue(scale.ticks[index], domain))
                }
                ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                    if let label = spec.endLabel, spec.series.state != .empty {
                        Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .frame(width: endLabelWidth - 8, alignment: .leading)
                            .position(x: rect.maxX + 8 + (endLabelWidth - 8) / 2, y: spread[index])
                    }
                }
                ForEach(gapRanges(), id: \.0) { start, end in
                    if xValue(end, rect) - xValue(start, rect) > 44 {
                        regionLabel(L10n.text("No recording"), x: (xValue(start, rect) + xValue(end, rect)) / 2, rect: rect)
                    }
                }
                if layout.staleMuted, let since = staleSince(), rect.maxX - xValue(since, rect) > 36 {
                    regionLabel(L10n.text("Stale").lowercased(), x: (xValue(since, rect) + rect.maxX) / 2, rect: rect)
                }
            }
        }
    }

    private func regionLabel(_ text: String, x: CGFloat, rect: CGRect) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.secondary).position(x: x, y: rect.minY + 8)
    }

    private func timeLabels(layout: Layout) -> some View {
        let ticks = MetricChartScale.timeTicks(in: window, count: layout.timeTickCount)
        return HStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, date in
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                if index < ticks.count - 1 { Spacer(minLength: 4) }
            }
        }
        .padding(.leading, axisWidth + gutter).padding(.trailing, endLabelWidth)
    }

    // MARK: Drawing

    private func yValue(_ value: Double, _ domain: ClosedRange<Double>) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return plotHeight / 2 }
        return plotHeight * CGFloat(1 - min(max((value - domain.lowerBound) / span, 0), 1))
    }

    private func xValue(_ date: Date, _ rect: CGRect) -> CGFloat {
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        guard length > 0 else { return rect.minX }
        return rect.minX + rect.width * CGFloat(min(max(date.timeIntervalSince(window.lowerBound) / length, 0), 1))
    }

    private func gapRanges() -> [(Date, Date)] {
        var seen = Set<[Date]>()
        return specs.flatMap { $0.series.gaps }.compactMap { gap in
            seen.insert([gap.start.date, gap.end.date]).inserted ? (gap.start.date, gap.end.date) : nil
        }
    }

    private func staleSince() -> Date? { specs.compactMap { $0.series.staleSince }.min() }

    private func hatch(_ context: inout GraphicsContext, _ region: CGRect) {
        context.fill(Path(region), with: .color(Color.primary.opacity(0.05)))
        var inner = context
        inner.clip(to: Path(region))
        var lines = Path()
        var x = region.minX - region.height
        while x < region.maxX {
            lines.move(to: CGPoint(x: x, y: region.maxY))
            lines.addLine(to: CGPoint(x: x + region.height, y: region.minY))
            x += 5
        }
        inner.stroke(lines, with: .color(Color.primary.opacity(0.16)), lineWidth: 0.7)
    }

    private func draw(_ context: inout GraphicsContext, rect: CGRect, scale: MetricChartScale) {
        let domain = scale.domain
        for band in 0..<(scale.ticks.count - 1) {
            let top = yValue(scale.ticks[band + 1], domain), bottom = yValue(scale.ticks[band], domain)
            context.fill(Path(CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)),
                         with: .color(Color.primary.opacity(band % 2 == 0 ? 0.08 : 0.04)))
        }
        if domain.contains(0) {
            var zero = Path()
            zero.move(to: CGPoint(x: rect.minX, y: yValue(0, domain)))
            zero.addLine(to: CGPoint(x: rect.maxX, y: yValue(0, domain)))
            context.stroke(zero, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
        }
        for (start, end) in gapRanges() {
            hatch(&context, CGRect(x: xValue(start, rect), y: 0, width: max(xValue(end, rect) - xValue(start, rect), 0), height: plotHeight))
        }
        if let since = staleSince() {
            hatch(&context, CGRect(x: xValue(since, rect), y: 0, width: rect.maxX - xValue(since, rect), height: plotHeight))
        }
        let baseline = yValue(domain.contains(0) ? 0 : domain.lowerBound, domain)
        for spec in specs where spec.series.state != .empty {
            let color = spec.color.opacity(spec.series.state == .staleTail ? 0.55 : 1)
            var runs: [[HistoryChartPoint]] = []
            for point in spec.series.points {
                if runs.last?.last?.series == point.series { runs[runs.count - 1].append(point) } else { runs.append([point]) }
            }
            for run in runs where run.count > 1 {
                let pts = run.map { CGPoint(x: xValue($0.date, rect), y: yValue($0.value, domain)) }
                var line = Path()
                line.move(to: pts[0])
                pts.dropFirst().forEach { line.addLine(to: $0) }
                if specs.count == 1 {
                    var area = line
                    area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: baseline))
                    area.addLine(to: CGPoint(x: pts[0].x, y: baseline))
                    area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.14)))
                }
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            for point in spec.series.isolatedPoints { dot(&context, point, color, 2, rect, domain) }
            if let last = spec.series.points.last { dot(&context, last, color, 3, rect, domain) }
        }
    }

    private func dot(_ context: inout GraphicsContext, _ point: HistoryChartPoint, _ color: Color, _ radius: CGFloat, _ rect: CGRect, _ domain: ClosedRange<Double>) {
        let center = CGPoint(x: xValue(point.date, rect), y: yValue(point.value, domain))
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
    }
}
// tlv-origin:a3c81d5e0b97f246
