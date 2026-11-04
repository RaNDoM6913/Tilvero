import SwiftUI
import Charts
import Observation
import PowerCore
import PowerPersistence

/// Daily overview follows the owner-selected centered-device composition.
/// Technical metadata stays behind explicit info buttons, not in summary rails.
@MainActor struct OverviewDashboard: View {
    @Environment(\.studioPresentation) private var studioPresentation
    @ObservedObject var model: TilveroModel
    @State private var liveMetrics = OverviewLiveMetrics()
    private var level: Int? { EnergyVisualSnapshot(model.snapshot).level }
    private var chargeReading: CatalogReading? { reading("011") }
    private func reading(_ id: String) -> CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        VStack(spacing: studioPresentation.spacing(18)) {
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
                    Image(systemName: "battery.100percent").foregroundStyle(studioPresentation.accent).accessibilityHidden(true)
                    Text(L10n.text("macOS charge limit"))
                    StudioText(limitText, id: "overview.nativeLimit.value").monospacedDigit()
                }.font(.system(size: 12))
                    .help(L10n.text("macOS manages this setting independently of Tilvero."))
                Spacer(minLength: 8)
                StudioActionButton(L10n.text("Details"), id: "battery-summary.details") { model.selectedSection = .battery }
            }
        }
        .task { await refreshLiveMetrics() }
    }

    private func refreshLiveMetrics() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let start = clock.now
            let readings = await model.readOverviewMetrics()
            guard !Task.isCancelled else { return }
            liveMetrics.readings = readings ?? []
            let next = start.advanced(by: .seconds(2))
            // A slow read must not produce overlapping reads or a burst of catch-up samples.
            let deadline = next > clock.now ? next : clock.now.advanced(by: .seconds(2))
            do { try await clock.sleep(until: deadline) }
            catch { return }
        }
    }

    private var leftRail: some View {
        OverviewLiveMetricRail(live: liveMetrics, input: reading("054"), temperature: reading("039"),
                               fahrenheit: model.fahrenheit)
    }
    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            WeeklyCapacityMetric(publication: model.weeklyCapacity, historyEnabled: model.historyEnabled)
            OverviewDashboardMetric(reading: reading("027"), title: "Cycle count", fahrenheit: model.fahrenheit)
        }
    }
    private var chargeHeader: some View {
        VStack(spacing: 7) {
            StudioText(model.chargeText, id: "overview.charge.value").font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(level == nil || model.snapshot.chargePercent.freshness == .stale ? Color.secondary : studioPresentation.accent)
                .contentTransition(.numericText())
            StudioText(model.chargingStateText, id: "overview.charge.status").font(.system(size: 12)).foregroundStyle(.secondary)
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
        let now = Date()
        let window = now.addingTimeInterval(-86400)...now
        let observations = model.history.filter { window.contains($0.collectedAt) }
        let series = OverviewHistorySeries(observations.map {
            ChartObservation(id: $0.id, date: $0.collectedAt,
                             value: $0.isAggregate ? nil : $0.chargePercent,
                             continuityID: $0.segmentID.uuidString)
        })
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                StudioText(L10n.text("Charge over 24 hours"), id: "overview.history.title").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.selectedSection = .history } label: {
                    Label(L10n.text("Open history"), systemImage: "chevron.right")
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
            if series.points.isEmpty {
                Text(L10n.text(model.isDemo ? "Simulation data is never stored in live history." : "No recorded measurements yet"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
            } else {
                OverviewHistoryPlot(series: series, window: window)
            }
        }
    }
}

@MainActor private struct WeeklyCapacityMetric: View {
    let publication: WeeklyCapacity?
    let historyEnabled: Bool
    @State private var showsInfo = false
    @FocusState private var infoFocused: Bool

    private var value: String {
        guard let publication else { return "—" }
        return "≈ " + publication.percent.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)) + "%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StudioText(value, id: "overview.metric.026.value")
                .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                StudioText(L10n.text("Capacity retention"), id: "overview.metric.026.title")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { showsInfo = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 12))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .focusable().focused($infoFocused)
                .onKeyPress(.space) { showsInfo = true; return .handled }
                .onKeyPress(.return) { showsInfo = true; return .handled }
                .accessibilityLabel(L10n.text("Weekly capacity estimate"))
                .accessibilityIdentifier("reading-info-026")
                .studioElement("catalog.026.info", label: "Weekly capacity estimate")
                .help(L10n.text("Weekly capacity estimate"))
                .popover(isPresented: $showsInfo, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Weekly capacity estimate")).font(.headline)
                        Text(L10n.text("Each day with a recorded estimate contributes one median. The overview updates at most once every seven days."))
                        if let publication {
                            Text(String(format: L10n.text("Recorded days: %lld of 7"), locale: L10n.locale, Int64(publication.observedDays)))
                            Text(String(format: L10n.text("Recorded from %@ to %@"), locale: L10n.locale,
                                        date(publication.firstObservedAt), date(publication.lastObservedAt)))
                            Text(String(format: L10n.text("Next update no earlier than %@"), locale: L10n.locale,
                                        date(publication.nextEligibleAt)))
                        } else {
                            Text(L10n.text(historyEnabled
                                ? "A recognized battery and a usable estimate recorded within seven days are required."
                                : "Turn on local history to see a weekly estimate."))
                        }
                    }
                    .font(.callout).padding(14).frame(width: 270, alignment: .leading)
                }
                .onChange(of: showsInfo) { _, visible in if !visible { infoFocused = true } }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func date(_ value: Date) -> String {
        value.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale))
    }
}

@MainActor private struct OverviewDashboardMetric: View {
    let reading: CatalogReading?
    let title: String
    let fahrenheit: Bool

    private func qualifications(for reading: CatalogReading) -> [String] {
        CatalogDataPresentation.qualifications(reading).filter {
            reading.id != "027" || $0 != L10n.text("Stale")
        }
    }

    private var value: String {
        guard let reading else { return "—" }
        if reading.id == "027", reading.availability == .available || reading.freshness == .stale,
           case .integer(let count) = reading.value { return count.formatted(.number.locale(L10n.locale)) }
        return CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StudioText(value, id: "overview.metric." + (reading?.id ?? studioSemanticID(title)) + ".value").font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                StudioText(L10n.text(title), id: "overview.metric." + (reading?.id ?? studioSemanticID(title)) + ".title").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            }
            if let reading {
                ForEach(qualifications(for: reading), id: \.self) { qualification in
                    Text(qualification).font(.system(size: 11))
                        .foregroundStyle(qualification == L10n.text("Stale") ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private struct OverviewHistoryPlot: View {
    @Environment(\.studioPresentation) private var studioPresentation
    let series: OverviewHistorySeries
    let window: ClosedRange<Date>
    private let observedStroke = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
    private let gapStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 4])
    private let gapColor = Color.secondary

    var body: some View {
        let isolatedIDs = Set(series.isolatedPoints.map(\.id))
        VStack(alignment: .leading, spacing: 5) {
            Chart(series.points) { point in
                if isolatedIDs.contains(point.id) {
                    PointMark(x: .value("Time", point.date), y: .value("Charge", point.value))
                        .foregroundStyle(studioPresentation.accent).symbolSize(15)
                } else {
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.value),
                             series: .value("Segment", point.series))
                        .foregroundStyle(studioPresentation.accent).lineStyle(observedStroke)
                        .interpolationMethod(.linear)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    if let percent = value.as(Int.self), percent != 50 {
                        AxisValueLabel { Text("\(percent)%").font(.system(size: 11)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [6.0, 12.0, 18.0].map { window.lowerBound.addingTimeInterval($0 * 3600) }) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute().locale(L10n.locale))
                }
            }
            .chartBackground { proxy in
                if !series.gaps.isEmpty {
                    GeometryReader { geometry in
                        if let frame = proxy.plotFrame {
                            let plot = geometry[frame]
                            Canvas { context, _ in
                                var connectors = Path()
                                for gap in series.gaps {
                                    guard let start = proxy.position(for: (x: gap.start.date, y: gap.start.value)),
                                          let end = proxy.position(for: (x: gap.end.date, y: gap.end.value)) else { continue }
                                    connectors.move(to: start)
                                    connectors.addLine(to: end)
                                }
                                context.stroke(connectors, with: .color(gapColor), style: gapStroke)
                            }
                            .frame(width: plot.width, height: plot.height)
                            .position(x: plot.midX, y: plot.midY)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .frame(height: 70)
            .accessibilityLabel(L10n.text("Charge over 24 hours"))
            .accessibilityHint(series.gaps.isEmpty ? "" : L10n.text("Dashed lines mark intervals without recorded measurements."))

            HStack(spacing: 14) {
                legendItem("Recorded measurements", color: studioPresentation.accent, stroke: observedStroke)
                legendItem("No measurements", color: gapColor, stroke: gapStroke)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func legendItem(_ key: String, color: Color, stroke: StrokeStyle) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 3))
                path.addLine(to: CGPoint(x: 17, y: 3))
            }
            .stroke(color, style: stroke)
            .frame(width: 18, height: 6)
            Text(L10n.text(key))
        }
    }
}


/// Only the two metric views observe these faster samples.
@MainActor @Observable private final class OverviewLiveMetrics {
    var readings: [CatalogReading] = []
}

@MainActor private struct OverviewLiveMetricRail: View {
    let live: OverviewLiveMetrics
    let input: CatalogReading?
    let temperature: CatalogReading?
    let fahrenheit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            OverviewDashboardMetric(reading: newest("054", fallback: input), title: "Adapter input", fahrenheit: fahrenheit)
            OverviewDashboardMetric(reading: newest("039", fallback: temperature), title: "Temperature", fahrenheit: fahrenheit)
        }
    }

    private func newest(_ id: String, fallback: CatalogReading?) -> CatalogReading? {
        guard let sample = live.readings.first(where: { $0.id == id }),
              fallback.map({ $0.collectedAt <= sample.collectedAt }) ?? true else { return fallback }
        return sample
    }
}
