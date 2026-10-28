import SwiftUI
import Charts
import PowerCore

@MainActor struct OverviewMetricsPanel: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.overviewPreferences.order.filter { !model.overviewPreferences.hidden.contains($0) }) { item in
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
                case .power: metric("Power", symbol: "bolt", id: "038")
                case .temperature: metric("Temperature", symbol: "thermometer.medium", id: "039")
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
                                .frame(height: 88)
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
    @ViewBuilder private func metric(_ title: String, symbol: String, id: String) -> some View {
        if let reading = model.snapshot.catalog.first(where: { $0.id == id }) {
            HStack {
                Label(L10n.text(title), systemImage: symbol)
                Spacer()
                Text(ReadingPresentation.display(reading, reveal: false, fahrenheit: model.fahrenheit)).monospacedDigit()
                if reading.freshness == .stale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange) }
            }.font(.subheadline).help(L10n.text("Source") + ": " + reading.source)
        }
    }
}
