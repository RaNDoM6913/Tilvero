import SwiftUI
import Charts
import PowerCore

@MainActor struct OverviewMetricsPanel: View {
    @ObservedObject var model: TilveroModel
    var allowsAwakeActions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.visibleOverviewMetrics) { item in
                switch item {
                case .forecast:
                    HStack(alignment: .firstTextBaseline) {
                        Label(L10n.text("Time to 20%"), systemImage: "clock")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(estimateText).monospacedDigit()
                            Text(L10n.text(model.dischargeForecast == nil ? "Insufficient discharge observations" : "Estimate"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.font(.subheadline)
                        .help(L10n.text("Extrapolated from a recent continuous discharge. Changing the workload changes the forecast."))
                case .keepAwake:
                    // Owned sessions have a separate Overview row, independent of hidden widgets.
                    if !model.keepAwake.hasOwnedAssertion {
                        if allowsAwakeActions { KeepAwakePanel(model: model, compact: true).id(model.language) }
                        else { KeepAwakeSummary(service: model.keepAwake).id(model.language) }
                    }
                case .power: PowerMetricCard(model: model, title: "Battery power", symbol: "bolt", id: "038")
                case .temperature: PowerMetricCard(model: model, title: "Temperature", symbol: "thermometer.medium", id: "039", color: .red)
                case .applications: ProcessActivityPanel(model: model, compact: true, allowsNavigation: allowsAwakeActions).id(model.language)
                case .systemPower: PowerMetricCard(model: model, title: "System", symbol: "desktopcomputer", id: "043")
                case .adapter: AdapterMetricCard(model: model)
                case .batteryHealth: BatteryHealthMetricCard(model: model)
                case .chargeLimit:
                    HStack {
                        Label(L10n.text("Charge limit"), systemImage: "battery.100percent")
                        Spacer()
                        Text(model.nativeCharge.observed.flatMap { $0.isFresh && $0.policyMatches && $0.configuration.enabled ? "\($0.configuration.target)%" : nil } ?? "—")
                            .monospacedDigit()
                    }.font(.subheadline)
                case .history:
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("Last hour")).font(.caption).foregroundStyle(.secondary)
                        if !model.quickHistoryPoints.isEmpty {
                            Chart(model.quickHistoryPoints) { point in
                                LineMark(x: .value("Time", point.date), y: .value("Charge", point.value), series: .value("Segment", point.series))
                                    .foregroundStyle(Color.green).interpolationMethod(.linear)
                                PointMark(x: .value("Time", point.date), y: .value("Charge", point.value)).foregroundStyle(Color.green).symbolSize(8)
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
        }
    }
    private var estimateText: String {
        guard let value = model.dischargeForecast else { return "—" }
        if value.upperSeconds == 0 { return L10n.text("20% already reached") }
        func text(_ seconds: Double) -> String {
            let minutes = max(5, Int((seconds / 300).rounded()) * 5)
            return minutes >= 60 ? "\(minutes / 60) \(L10n.text("h")) \(minutes % 60) \(L10n.text("min"))" : "\(minutes) \(L10n.text("min"))"
        }
        return "≈ " + text(value.lowerSeconds) + "–" + text(value.upperSeconds)
    }
}
