import SwiftUI
import PowerCore
import PowerTelemetry

/// Historical endpoints and current assertions are deliberately separate evidence.
@MainActor
struct SleepReportPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var selectedID: UUID?
    @State private var observationDetailsExpanded = false
    @State private var observationInfoShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var records: [SleepSessionRecord] { model.sleepSessions.sorted { ($0.observedAt ?? .distantPast) > ($1.observedAt ?? .distantPast) } }
    private var selected: SleepSessionRecord? { records.first { $0.id == selectedID } ?? records.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.isDemo {
                introduction
                ProductSurface {
                    Label(L10n.text("Sleep reports are not collected in Simulation."), systemImage: "testtube.2")
                }
            } else {
                if !model.historyEnabled {
                    Label(L10n.text("History is off. New sleep intervals are not recorded."), systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.sleepReportError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let record = selected {
                    VStack(alignment: .leading, spacing: 20) {
                        intervalHeading(record)
                        interval(record)
                            .id(record.id).transition(.opacity)
                    }
                } else if model.sleepReportError == nil {
                    introduction
                    ProductSurface(title: "No observed sleep intervals yet", symbol: "moon.zzz") {
                        Text(L10n.text("After a normal sleep and wake, this section will show the available before/after readings. Keep history enabled."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                currentAssertions
            }
            Text(L10n.text("Elapsed observation time is not measured time asleep. Internal wakes, wake reasons and per-app energy are not available from these observations."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task { await model.refreshSleepActivity() }
            .transaction { if reduceMotion { $0.animation = nil } }
    }

    private var introduction: some View {
        VStack(spacing: 8) {
            moon
            if records.isEmpty && !model.isDemo {
                Text(L10n.text("Sleep reports start with the next sleep observed while Tilvero is running. Previous nights are not reconstructed."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity)
    }

    private var moon: some View {
        Image(systemName: "moon.fill").font(.system(size: 30, weight: .light))
            .foregroundStyle(.green).accessibilityHidden(true)
    }

    private func intervalHeading(_ record: SleepSessionRecord) -> some View {
        VStack(spacing: 8) {
            moon
            Text(L10n.text(record.id == records.first?.id ? "Last observed interval" : "Observed interval"))
                .font(.headline)
            Menu {
                Picker(L10n.text("Observed interval"), selection: Binding(get: { record.id }, set: { value in
                    withAnimation(ProductMotion.animation(reduceMotion: reduceMotion)) { selectedID = value }
                })) {
                    ForEach(records) { row in Text(date(row.observedAt)).tag(row.id) }
                }
            } label: { Text(intervalDate(record)).font(.caption).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(L10n.text("Observed interval"))
            .accessibilityIdentifier("sleep-observed-interval")
        }.frame(maxWidth: .infinity)
    }

    private func interval(_ record: SleepSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                endpoint("Before sleep", record.before)
                HStack(spacing: 0) {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                    Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }.accessibilityHidden(true)
                endpoint("After wake", record.after)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                ProductMetric(title: "Charge change", value: record.chargeChangePercentagePoints.map(change) ?? L10n.text("Unavailable"))
                Rectangle().fill(.primary.opacity(0.09)).frame(width: 1, height: 55)
                ProductMetric(title: "Observed interval", value: record.notificationIntervalSeconds.map(duration) ?? L10n.text("Unavailable"))
            }
            HStack(alignment: .top, spacing: 5) {
                Text(L10n.text("The interval connects observations, not measured time asleep."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                observationInfo
            }.frame(maxWidth: .infinity)
            DisclosureGroup(isExpanded: Binding(get: { observationDetailsExpanded }, set: { value in
                withAnimation(ProductMotion.animation(reduceMotion: reduceMotion)) { observationDetailsExpanded = value }
            })) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.text(phase(record.phase)), systemImage: record.phase == .closed ? "checkmark.circle" : "clock")
                        .font(.callout).foregroundStyle(.secondary)
                    endpointDetails("Before sleep", record.before, boundary: record.sleepBoundary, before: true)
                    Divider()
                    endpointDetails("After wake", record.after, boundary: record.wakeBoundary, before: false)
                    Divider()
                    Text(L10n.text(power(record.powerEvidence)))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("Power changes between observations are unknown. A zero percentage change does not mean zero energy use."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12).padding(.bottom, 4)
            } label: {
                Text(L10n.text("Observation details")).font(.callout.weight(.medium)).foregroundStyle(.primary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: observationDetailsExpanded)
            // Keep qualification visible while technical details are collapsed.
            if record.phase != .closed || !record.issues.isEmpty {
                Label(L10n.text(phase(record.phase)), systemImage: record.phase == .closed ? "info.circle" : "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(record.issues, id: \.self) { issue in
                Label(L10n.text(issueText(issue)), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if record.powerEvidence != .batteryAtBothObservations {
                Text(L10n.text(power(record.powerEvidence)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var observationInfo: some View {
        Button { observationInfoShown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(L10n.text("Observation details"))
        .popover(isPresented: $observationInfoShown, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Observed interval")).font(.headline)
                Text(L10n.text("Elapsed observation time is not measured time asleep. Internal wakes, wake reasons and per-app energy are not available from these observations."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Observation details")) {
                    observationInfoShown = false
                    withAnimation(ProductMotion.animation(reduceMotion: reduceMotion)) { observationDetailsExpanded = true }
                }
            }.padding(18).frame(width: 290, alignment: .leading)
        }
    }

    private func endpoint(_ title: String, _ value: SleepBatteryEndpoint?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value.map { $0.collectedAt.formatted(.dateTime.hour().minute().locale(L10n.locale)) } ?? "—")
                .font(.title3.weight(.semibold)).monospacedDigit().textSelection(.enabled)
            HStack(spacing: 7) {
                Text(value.map { $0.chargePercent.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                    .font(.headline).monospacedDigit().textSelection(.enabled)
                Image(systemName: value.map { batterySymbol($0.chargePercent) } ?? "battery.0percent")
                    .foregroundStyle(value == nil ? Color.secondary : Color.green).accessibilityHidden(true)
            }
            if value == nil { Text(L10n.text("No reading")).font(.caption).foregroundStyle(.secondary) }
        }.frame(minWidth: 112, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func batterySymbol(_ charge: Double) -> String {
        switch charge {
        case ..<12.5: "battery.0percent"
        case ..<37.5: "battery.25percent"
        case ..<62.5: "battery.50percent"
        case ..<87.5: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func endpointDetails(_ title: String, _ value: SleepBatteryEndpoint?, boundary: SleepObservationStamp?, before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
            if let value {
                Text("\(L10n.text("Collected")): \(date(value.collectedAt))")
                Text("\(L10n.text("Source")): \(value.source)")
                Text("\(L10n.text("Source measurement time")): \(value.sourceSampleAt.map { date($0) } ?? L10n.text("Unavailable"))")
            } else { Text(L10n.text("No reading")) }
            if let boundary {
                Text("\(L10n.text(before ? "Sleep notification" : "Wake notification")): \(date(boundary.wallDate))")
                if let value, let delay = SleepEndpointTiming.seconds(value, boundary: boundary, before: before) {
                    Text("\(L10n.text(before ? "Reading before notification" : "Reading after notification")): \(delay.formatted(.number.precision(.fractionLength(0)))) \(L10n.text("seconds"))")
                } else { Text(L10n.text("Reading delay unavailable")) }
            } else {
                Text(L10n.text("Unavailable"))
            }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var currentAssertions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                ProductSectionHeading(title: "Current sleep blockers")
                Spacer(minLength: 0)
                Button(L10n.text("Refresh")) { Task { await model.refreshSleepActivity() } }
                    .disabled(model.isReadingSleepActivity)
            }
            Text(L10n.text("Current observations do not explain past sleep intervals."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isReadingSleepActivity { ProgressView().controlSize(.small) }
            if let activity = model.sleepActivity {
                if activity.aggregateAvailability == .available {
                    if activity.activeTypes.isEmpty { Text(L10n.text("No active sleep-prevention types observed.")) }
                    else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(activity.activeTypes, id: \.self) { type in
                                Label(L10n.text(assertion(type)), systemImage: "info.circle")
                                    .font(.system(size: 12)).padding(.vertical, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else { Text(L10n.text("Aggregate sleep-prevention status is unavailable.")).foregroundStyle(.secondary) }
                Divider()
                if activity.processAvailability == .available {
                    if activity.rows.isEmpty { Text(L10n.text("No active process assertions observed.")) }
                    else {
                        DisclosureGroup(L10n.text("Process assertions")) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(activity.rows.prefix(20))) { row in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.processName ?? row.processID.map { "\(L10n.text("Process")) \($0)" } ?? L10n.text("Process name unavailable"))
                                            .font(.system(size: 12))
                                        Text(L10n.text(assertion(row.type))).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                                }
                                if activity.rows.count > 20 { Text(L10n.text("Showing the first 20 current assertions.")).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else { Text(L10n.text("Per-process sleep-prevention status is unavailable.")).foregroundStyle(.secondary) }
                Text("\(L10n.text("Observed")): \(date(activity.collectedAt))").font(.caption).foregroundStyle(.secondary)
            } else if !model.isReadingSleepActivity { Text(L10n.text("Not collected yet")).foregroundStyle(.secondary) }
            Text(L10n.text("Process observations stay in memory. Names, paths and assertion descriptions are not written to sleep history."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func intervalDate(_ record: SleepSessionRecord) -> String {
        if let start = record.sleepBoundary?.wallDate, let end = record.wakeBoundary?.wallDate, end >= start {
            let formatter = DateIntervalFormatter()
            formatter.locale = L10n.locale; formatter.dateStyle = .medium; formatter.timeStyle = .none
            return formatter.string(from: start, to: end)
        }
        return date(record.observedAt)
    }
    private func date(_ value: Date?) -> String {
        value.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().locale(L10n.locale)) } ?? "—"
    }
    private func duration(_ value: Double) -> String {
        let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute]; formatter.unitsStyle = .abbreviated
        formatter.calendar = Calendar(identifier: .gregorian); formatter.calendar?.locale = L10n.locale
        return formatter.string(from: value) ?? "—"
    }
    private func change(_ loss: Double) -> String {
        let prefix = loss > 0 ? "−" : loss < 0 ? "+" : ""
        return prefix + abs(loss).formatted(.number.precision(.fractionLength(0...1))) + " " + L10n.text("pp")
    }
    private func phase(_ value: SleepSessionPhase) -> String {
        switch value {
        case .awaitingWake: "Awaiting wake"
        case .awaitingReading: "Awaiting fresh reading"
        case .closed: "Recorded"
        case .incomplete: "Incomplete"
        }
    }
    private func power(_ value: SleepPowerEvidence) -> String {
        switch value {
        case .batteryAtBothObservations: "Battery power at both observations."
        case .externalPowerObserved: "External power was observed. This is a mixed-power interval."
        case .unavailable: "Power-source evidence is unavailable."
        }
    }
    private func assertion(_ value: SleepAssertionType) -> String {
        switch value {
        case .displayIdle: "Prevents idle display sleep"
        case .systemIdle: "Prevents idle system sleep"
        case .systemSleep: "System-sleep assertion active"
        case .unknown: "Unknown assertion type"
        }
    }
    private func issueText(_ value: SleepSessionIssue) -> String {
        switch value {
        case .preReadingMissing: "Fresh pre-sleep charge is missing."
        case .postReadingMissing: "Fresh post-wake charge is missing."
        case .sleepBoundaryMissing: "The app did not observe the sleep boundary."
        case .batteryIdentityMissing: "Battery identity is unavailable; charge change is not calculated."
        case .batteryIdentityChanged: "Battery identity changed; charge change is not calculated."
        case .clockChanged: "Clock continuity could not be confirmed."
        case .applicationRestarted: "The application restarted during this observation."
        case .applicationStopped: "The application stopped during this observation."
        case .historyDisabled: "History was disabled during this observation."
        case .historyErased: "History was erased during this observation."
        case .supersededBySleep: "A new sleep began before this observation completed."
        }
    }
}

/// The UI exposes the measurement offset instead of implying readings were instantaneous.
enum SleepEndpointTiming {
    static func seconds(_ endpoint: SleepBatteryEndpoint, boundary: SleepObservationStamp, before: Bool) -> Double? {
        guard endpoint.isValid, boundary.isValid, endpoint.stamp.runID == boundary.runID else { return nil }
        let continuous = endpoint.measurementContinuousSeconds - boundary.continuousSeconds
        let wall = endpoint.collectedAt.timeIntervalSince(boundary.wallDate)
        guard continuous.isFinite, abs(continuous - wall) <= 5, abs(continuous) <= 60 else { return nil }
        if before { return continuous <= 1 ? max(0, -continuous) : nil }
        return continuous >= -1 ? max(0, continuous) : nil
    }
}
