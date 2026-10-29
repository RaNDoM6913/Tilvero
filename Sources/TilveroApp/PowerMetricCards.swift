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
    private var reading: CatalogReading? { model.snapshot.catalog.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text(title), systemImage: symbol)
                Spacer(minLength: 8)
                Text(reading.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: model.fahrenheit) } ?? "—").monospacedDigit()
                if reading?.freshness == .stale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange) }
            }.font(.subheadline)
            if id != "039" && id != "026" {
                MetricSparkline(model: model, id: id, color: color)
            }
        }.help(reading.map { L10n.text("Source") + ": " + $0.source + " · " + L10n.text("Freshness") + ": " + $0.freshness.rawValue + "\n" + L10n.text($0.reason ?? "Recorded observations during the last hour.") } ?? L10n.text("Unavailable"))
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
    private var rating: String {
        model.snapshot.catalog.first { $0.id == "050" }.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: false) } ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PowerMetricCard(model: model, title: "Adapter input", symbol: "powerplug", id: "054", color: .blue)
            Text(L10n.text("Rated capability") + ": " + rating).font(.caption2).foregroundStyle(.secondary)
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
                ProductSurface {
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
