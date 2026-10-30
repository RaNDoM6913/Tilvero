import SwiftUI
import Charts
import PowerCore

/// Daily overview follows the owner-selected centered-device composition.
/// Technical metadata stays behind explicit info buttons, not in summary rails.
@MainActor struct OverviewDashboard: View {
    @ObservedObject var model: TilveroModel
    private var level: Int? { EnergyVisualSnapshot(model.snapshot).level }
    private var chargeReading: CatalogReading? { reading("011") }
    private func reading(_ id: String) -> CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 18) {
            chargeHeader
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    leftRail.frame(width: 145)
                    centerpiece.frame(width: 250)
                    rightRail.frame(width: 150)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    centerpiece.frame(maxWidth: .infinity)
                    HStack(alignment: .top, spacing: 28) {
                        leftRail.frame(maxWidth: .infinity)
                        rightRail.frame(maxWidth: .infinity)
                    }
                }
            }
            ProductChargeTrack(level: level, stale: model.snapshot.chargePercent.freshness == .stale)
                .frame(maxWidth: 390).frame(maxWidth: .infinity)
            historyStrip
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(spacing: 7) {
                    Image(systemName: "battery.100percent").foregroundStyle(.green).accessibilityHidden(true)
                    Text(L10n.text("macOS charge limit"))
                    Text(limitText).monospacedDigit()
                }.font(.system(size: 12))
                    .help(L10n.text("macOS manages this setting independently of Tilvero."))
                Spacer(minLength: 8)
                Button(L10n.text("Details")) { model.selectedSection = .battery }
            }
        }
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            OverviewDashboardMetric(reading: reading("054"), title: "Adapter input", fahrenheit: model.fahrenheit)
            OverviewDashboardMetric(reading: reading("039"), title: "Temperature", fahrenheit: model.fahrenheit)
        }
    }
    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            OverviewDashboardMetric(reading: reading("026"), title: "Capacity retention", fahrenheit: model.fahrenheit)
            OverviewDashboardMetric(reading: reading("027"), title: "Cycle count", fahrenheit: model.fahrenheit)
        }
    }
    private var chargeHeader: some View {
        VStack(spacing: 7) {
            Text(model.chargeText).font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(level == nil || model.snapshot.chargePercent.freshness == .stale ? Color.secondary : Color.green)
                .contentTransition(.numericText())
            Text(model.chargingStateText).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if model.snapshot.chargePercent.freshness == .stale {
                Text(L10n.text("Stale")).font(.callout).foregroundStyle(.orange)
            } else if level != nil, model.snapshot.chargePercent.freshness == .unknown {
                Text(L10n.text("Freshness unknown")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var centerpiece: some View {
        Group {
            if let artwork = EnergyArtwork.overviewMac {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(height: 175)
                    .accessibilityHidden(true).help(L10n.text("Device illustrations are schematic."))
            } else {
                Image(systemName: "laptopcomputer").font(.system(size: 80, weight: .ultraLight))
                    .frame(height: 175).accessibilityHidden(true)
            }
        }
    }
    private var limitText: String {
        if let setting = model.nativeCharge.nativeSetting, setting.isFresh {
            return setting.configuration.enabled ? "\(setting.configuration.target)%" : L10n.text("System managed")
        }
        if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits,
           !limits.manualLimitIsConflicting, let limit = limits.manualLimit { return "\(limit)%" }
        return "—"
    }
    private var historyStrip: some View {
        let observations = model.history.filter { $0.collectedAt >= Date().addingTimeInterval(-86400) }
        let points = HistoryChart.points(observations.map {
            ChartObservation(id: $0.id, date: $0.collectedAt, value: $0.chargePercent, continuityID: $0.segmentID.uuidString)
        })
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.text("Charge over 24 hours")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.selectedSection = .history } label: {
                    Label(L10n.text("Open history"), systemImage: "chevron.right")
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
            if points.isEmpty {
                Text(L10n.text(model.isDemo ? "Simulation data is never stored in live history." : "No recorded measurements yet"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.value), series: .value("Segment", point.series))
                        .foregroundStyle(Color.green).interpolationMethod(.linear)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 100]) { value in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.05))
                        AxisValueLabel { if let value = value.as(Int.self) { Text("\(value)%").font(.system(size: 12)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) }
                }
                .frame(height: 66)
                .accessibilityLabel(L10n.text("Recorded charge over the last 24 hours. Missing observations remain gaps."))
            }
        }
    }
}

@MainActor private struct OverviewDashboardMetric: View {
    let reading: CatalogReading?
    let title: String
    let fahrenheit: Bool
    private var value: String {
        guard let reading else { return "—" }
        if reading.id == "027", reading.availability == .available || reading.freshness == .stale,
           case .integer(let count) = reading.value { return count.formatted(.number.locale(L10n.locale)) }
        return CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            }
            if let reading {
                ForEach(CatalogDataPresentation.qualifications(reading), id: \.self) { qualification in
                    Text(qualification).font(.system(size: 11))
                        .foregroundStyle(qualification == L10n.text("Stale") ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
