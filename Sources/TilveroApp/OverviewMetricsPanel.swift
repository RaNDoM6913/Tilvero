// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import Charts
import PowerCore

@MainActor struct OverviewMetricsPanel: View {
    @Environment(\.studioPresentation) private var studioPresentation
    @Environment(\.overviewHighlightedBlock) private var highlighted
    var model: TilveroModel
    var allowsAwakeActions = false
    /// Opens the Sleep page from the Keep Awake block; `nil` in the passive preview.
    var openSleep: (@MainActor () -> Void)?
    var body: some View {
        let _ = RenderProbe.hit("OverviewMetricsPanel")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.visibleOverviewMetrics) { item in
                Group {
                switch item {
                case .forecast: OverviewForecastBlock(model: model)
                case .keepAwake: OverviewKeepAwake(model: model, openSleep: openSleep).id(model.language)
                case .power: PowerMetricCard(model: model, title: "Battery power", symbol: "bolt", id: "038", style: model.overviewPreferences.chartStyle(for: .power))
                case .temperature: PowerMetricCard(model: model, title: "Temperature", symbol: "thermometer.medium", id: "039", color: .red, style: model.overviewPreferences.chartStyle(for: .temperature))
                case .applications: ProcessActivityPanel(model: model, compact: true, allowsNavigation: allowsAwakeActions).id(model.language)
                case .systemPower: PowerMetricCard(model: model, title: "System", symbol: "desktopcomputer", id: "043", style: model.overviewPreferences.chartStyle(for: .systemPower))
                case .adapter: AdapterMetricCard(model: model, style: model.overviewPreferences.chartStyle(for: .adapter))
                case .batteryHealth: BatteryHealthMetricCard(model: model)
                case .keyboardBacklight: KeyboardBacklightQuickRow(service: model.keyboardBacklight)
                case .powerTiles: PowerTilesBlock(model: model)
                case .powerCombined: PowerCombinedBlock(model: model)
                case .history:
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("Last hour")).font(.caption).foregroundStyle(.secondary)
                        if !model.quickHistoryPoints.isEmpty {
                            Chart(model.quickHistoryPoints) { point in
                                LineMark(x: .value("Time", point.date), y: .value("Charge", point.value), series: .value("Segment", point.series))
                                    .foregroundStyle(studioPresentation.accent).interpolationMethod(.linear)
                                PointMark(x: .value("Time", point.date), y: .value("Charge", point.value)).foregroundStyle(studioPresentation.accent).symbolSize(8)
                            }.chartYScale(domain: 0...100)
                                .chartXScale(domain: model.snapshot.collectedAt.addingTimeInterval(-3600)...model.snapshot.collectedAt)
                                .chartYAxis { AxisMarks(values: [0,50,100]) }
                                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                                .frame(height: 62)
                                .accessibilityLabel(L10n.text("Recorded charge during the last hour"))
                        } else {
                            Text(L10n.text("No recorded measurements yet")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                }
                .overlay {
                    // The builder's preview outlines the block being edited or hovered (nil everywhere else).
                    if highlighted == item {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(WindowTheme.accent, lineWidth: 2).padding(-5)
                            .transition(.opacity).allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: highlighted)
            }
        }
    }
}

private struct OverviewHighlightedBlockKey: EnvironmentKey { static let defaultValue: OverviewMetric? = nil }
extension EnvironmentValues {
    /// The block the quick-menu builder is editing or hovering, outlined in its preview.
    var overviewHighlightedBlock: OverviewMetric? {
        get { self[OverviewHighlightedBlockKey.self] }
        set { self[OverviewHighlightedBlockKey.self] = newValue }
    }
}

/// «Time to 20%»: one line with the extrapolated time and the clock time it lands on, or (chosen in the builder) the
/// observed discharge with a dashed extrapolation to the 20 % line. Without a forecast the right side says why
/// (collecting data, on power, already at 20 %) instead of a bare dash; it is never a promise, always «≈».
@MainActor struct OverviewForecastBlock: View {
    var model: TilveroModel
    var body: some View {
        let forecast = model.dischargeForecast
        let percent = ReadingPresentation.validLevel(model.snapshot.chargePercent.value)
        let status = OverviewForecastText.status(forecast: forecast, onPower: model.snapshot.isExternalPower.value == true)
        Group {
            if model.overviewPreferences.forecastStyle == .chart, let forecast, forecast.seconds > 0, forecast.points.count >= 2 {
                chart(forecast, now: model.snapshot.collectedAt)
            } else {
                row(forecast: forecast, status: status, percent: percent, now: model.snapshot.collectedAt)
            }
        }
        .metricCardChrome()
        .help(L10n.text("Extrapolated from a recent continuous discharge. Changing the workload changes the forecast."))
    }

    private func row(forecast: DischargeForecast.Estimate?, status: String?, percent: Int?, now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 30, height: 30).background(Circle().fill(Color.primary.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Until 20%")).font(.overviewBlockTitle).lineLimit(1)
                if let percent { Text(L10n.text("now") + " \(percent) %").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let forecast, forecast.seconds > 0 {
                    Text(OverviewForecastText.duration(forecast.seconds)).font(.system(size: 17, weight: .semibold))
                        .monospacedDigit().lineLimit(1).fixedSize()
                    Text(OverviewForecastText.arrival(now.addingTimeInterval(forecast.seconds))).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                } else if let status {
                    Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ forecast: DischargeForecast.Estimate, now: Date) -> some View {
        let end = now.addingTimeInterval(forecast.seconds)
        let last = forecast.points.last!
        let top = (forecast.points.map(\.percent).max() ?? 50) + 3
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("Time to 20%"), systemImage: "clock").font(.overviewBlockTitle).lineLimit(1)
                Spacer(minLength: 8)
                Text(OverviewForecastText.duration(forecast.seconds)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            Chart {
                ForEach(Array(forecast.points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.percent), series: .value("Line", "observed"))
                        .foregroundStyle(WindowTheme.accent).lineStyle(.init(lineWidth: 2))
                }
                LineMark(x: .value("Time", last.date), y: .value("Charge", last.percent), series: .value("Line", "forecast"))
                    .foregroundStyle(WindowTheme.accent.opacity(0.7)).lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
                LineMark(x: .value("Time", end), y: .value("Charge", 20.0), series: .value("Line", "forecast"))
                    .foregroundStyle(WindowTheme.accent.opacity(0.7)).lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
                RuleMark(y: .value("Limit", 20)).foregroundStyle(Color.orange.opacity(0.7)).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                PointMark(x: .value("Time", last.date), y: .value("Charge", last.percent)).foregroundStyle(WindowTheme.accent).symbolSize(28)
                PointMark(x: .value("Time", end), y: .value("Charge", 20.0)).foregroundStyle(.orange).symbolSize(28)
            }
            .chartYScale(domain: 15...max(top, 30))
            .chartXScale(domain: forecast.points.first!.date...end.addingTimeInterval(max(forecast.seconds, 600) * 0.16))
            .chartXAxis {
                AxisMarks(values: [forecast.points.first!.date, last.date, end]) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(abs(date.timeIntervalSince(last.date)) < 1 ? L10n.text("now") : date.formatted(.dateTime.hour().minute().locale(L10n.locale)))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [20, Int(last.percent.rounded())]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .frame(height: 80)
            .accessibilityLabel(L10n.text("Time to 20%") + ": " + OverviewForecastText.duration(forecast.seconds))
        }
    }
}

/// Texts of the forecast block (pure, testable).
enum OverviewForecastText {
    /// «≈ 1 ч 25 мин»: five-minute steps, at least 5 min.
    static func duration(_ seconds: Double) -> String {
        let minutes = max(5, Int((seconds / 300).rounded()) * 5)
        let text = minutes >= 60 ? "\(minutes / 60) \(L10n.text("h")) \(minutes % 60) \(L10n.text("min"))" : "\(minutes) \(L10n.text("min"))"
        return "≈ " + text
    }
    /// «к ≈ 05:05».
    static func arrival(_ date: Date) -> String {
        L10n.text("by (time)") + " ≈ " + date.formatted(.dateTime.hour().minute().locale(L10n.locale))
    }
    /// Why there is no time: at or below 20 %, on power, or not enough discharge observed yet; nil with a time.
    static func status(forecast: DischargeForecast.Estimate?, onPower: Bool) -> String? {
        if let forecast { return forecast.seconds > 0 ? nil : L10n.text("20% already reached") }
        return L10n.text(onPower ? "On power" : "Collecting data")
    }
}

