import SwiftUI
import PowerCore
import PowerTelemetry

/// Historical endpoints and current assertions are deliberately separate evidence.
@MainActor
struct SleepReportPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var selectedID: UUID?
    private var records: [SleepSessionRecord] { model.sleepSessions.sorted { ($0.observedAt ?? .distantPast) > ($1.observedAt ?? .distantPast) } }
    private var selected: SleepSessionRecord? { records.first { $0.id == selectedID } ?? records.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Sleep reports start with the next sleep observed while Tilvero is running. Previous nights are not reconstructed."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isDemo {
                Label(L10n.text("Sleep reports are not collected in Simulation."), systemImage: "testtube.2")
            } else {
                if !model.historyEnabled { Label(L10n.text("History is off. New sleep intervals are not recorded."), systemImage: "pause.circle") }
                if let error = model.sleepReportError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let record = selected {
                    Picker(L10n.text("Observed interval"), selection: Binding(get: { record.id }, set: { selectedID = $0 })) {
                        ForEach(records) { row in Text(date(row.observedAt)).tag(row.id) }
                    }.frame(maxWidth: 420)
                    interval(record)
                } else if model.sleepReportError == nil {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.text("No observed sleep intervals yet"), systemImage: "moon.zzz").font(.headline)
                            Text(L10n.text("After a normal sleep and wake, this section will show the available before/after readings. Keep history enabled."))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                currentAssertions
            }
            Text(L10n.text("Elapsed observation time is not measured time asleep. Internal wakes, wake reasons and per-app energy are not available from these observations."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task { await model.refreshSleepActivity() }
    }

    private func interval(_ record: SleepSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                metric("Charge change", record.chargeChangePercentagePoints.map(change) ?? "—")
                metric("Observed interval", record.notificationIntervalSeconds.map(duration) ?? "—")
                metric("Status", L10n.text(phase(record.phase)))
            }
            GroupBox(L10n.text("Battery observations")) {
                VStack(alignment: .leading, spacing: 8) {
                    endpoint("Before sleep", record.before, boundary: record.sleepBoundary, before: true)
                    endpoint("After wake", record.after, boundary: record.wakeBoundary, before: false)
                    Text(L10n.text(power(record.powerEvidence))).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Power changes between observations are unknown. A zero percentage change does not mean zero energy use."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if !record.issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(record.issues, id: \.self) { issue in
                        Label(L10n.text(issueText(issue)), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func endpoint(_ title: String, _ value: SleepBatteryEndpoint?, boundary: SleepObservationStamp?, before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text(title))
            Spacer()
            if let value {
                Text("\(value.chargePercent.formatted(.number.precision(.fractionLength(0...1))))% · \(date(value.collectedAt))")
                    .monospacedDigit().textSelection(.enabled)
            } else { Text(L10n.text("Unavailable")).foregroundStyle(.secondary) }
        }
        if let sampled = value?.sourceSampleAt {
            Text("\(L10n.text("Source measurement time")): \(date(sampled))").font(.caption).foregroundStyle(.secondary)
        }
        if let boundary {
            Text("\(L10n.text(before ? "Sleep notification" : "Wake notification")): \(date(boundary.wallDate))")
                .font(.caption).foregroundStyle(.secondary)
            if let value, let delay = SleepEndpointTiming.seconds(value, boundary: boundary, before: before) {
                Text("\(L10n.text(before ? "Reading before notification" : "Reading after notification")): \(delay.formatted(.number.precision(.fractionLength(0)))) \(L10n.text("seconds"))")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(L10n.text("Reading delay unavailable")).font(.caption).foregroundStyle(.secondary) }
        }
        }
    }
    private var currentAssertions: some View {
        GroupBox(L10n.text("Current sleep blockers")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("Current observations do not explain past sleep intervals.")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Refresh")) { Task { await model.refreshSleepActivity() } }
                        .disabled(model.isReadingSleepActivity)
                }
                if model.isReadingSleepActivity { ProgressView().controlSize(.small) }
                if let activity = model.sleepActivity {
                    if activity.aggregateAvailability == .available {
                        if activity.activeTypes.isEmpty { Text(L10n.text("No active sleep-prevention types observed.")) }
                        else {
                            ForEach(activity.activeTypes, id: \.self) { type in
                                Label(L10n.text(assertion(type)), systemImage: "info.circle")
                            }
                        }
                    } else { Text(L10n.text("Aggregate sleep-prevention status is unavailable.")).foregroundStyle(.secondary) }
                    Divider()
                    if activity.processAvailability == .available {
                        if activity.rows.isEmpty { Text(L10n.text("No active process assertions observed.")) }
                        ForEach(Array(activity.rows.prefix(20))) { row in
                            HStack {
                                Text(row.processName ?? row.processID.map { "\(L10n.text("Process")) \($0)" } ?? L10n.text("Process name unavailable"))
                                Spacer()
                                Text(L10n.text(assertion(row.type))).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        if activity.rows.count > 20 { Text(L10n.text("Showing the first 20 current assertions.")).font(.caption) }
                    } else { Text(L10n.text("Per-process sleep-prevention status is unavailable.")).foregroundStyle(.secondary) }
                    Text("\(L10n.text("Observed")): \(date(activity.collectedAt))").font(.caption2).foregroundStyle(.secondary)
                } else if !model.isReadingSleepActivity { Text(L10n.text("Not collected yet")).foregroundStyle(.secondary) }
                Text(L10n.text("Process observations stay in memory. Names, paths and assertion descriptions are not written to sleep history."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
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
