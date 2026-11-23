// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore
import PowerTelemetry

// MARK: Pill layout (shared with the quick menu's pill views)

/// How the quick menu's pill views size their pills. The quick menu (340 pt) lets them fill the row; the main window
/// gives them one fixed width so a row stays compact on a wide tile. The views, actions and confirmations are the same.
enum SleepPillsLayout: Equatable, Sendable {
    case quickMenu, window
    /// Fixed pill width, or nil to fill the row.
    var pillWidth: CGFloat? { self == .window ? 76 : nil }
    /// The selected pill: the window's green accent; the quick menu keeps the system accent.
    var selectedFill: Color { self == .window ? WindowTheme.accent : .accentColor }
}

private struct SleepPillsLayoutKey: EnvironmentKey {
    static let defaultValue = SleepPillsLayout.quickMenu
}

extension EnvironmentValues {
    var sleepPillsLayout: SleepPillsLayout {
        get { self[SleepPillsLayoutKey.self] }
        set { self[SleepPillsLayoutKey.self] = newValue }
    }
}

// MARK: Leads (pure, testable)

/// The lead of a Sleep & drain tab. The status colour is a role; the page maps `awake` to the user's Keep Awake colour.
struct SleepLeadDisplay: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case secondary, sleep, awake, attention }
    let value: String
    let status: String
    let tone: Tone
    let detail: String
}

struct SleepTimerLeadInputs: Equatable, Sendable {
    var available = true
    var phase: SleepTimerPhase = .idle
    var needsHoldRelease = false
    var remainingSeconds = 0
    var endDate: Date?
    /// Sleep at charge armed at this level.
    var chargeTarget: Int?
}

struct KeepAwakeLeadInputs: Equatable, Sendable {
    var available = true
    var hasOwnedAssertion = false
    var isActive = false
    var untilStopped = false
    var remainingSeconds = 0
    var endDate: Date?
    /// Keep awake until charge armed at this level.
    var chargeTarget: Int?
}

enum SleepDrainLead {
    private static func percent(_ value: Int, language: String) -> String { language == "ru" ? "\(value) %" : "\(value)%" }
    private static func clock(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func timer(_ input: SleepTimerLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> SleepLeadDisplay {
        func t(_ key: String) -> String { L10n.text(key) }
        guard input.available else {
            return SleepLeadDisplay(value: "—", status: t("Unavailable"), tone: .secondary,
                                    detail: t("Sleep timer is unavailable in this build or simulation."))
        }
        if input.needsHoldRelease {
            return SleepLeadDisplay(value: "—", status: t("Check session"), tone: .attention,
                                    detail: t("The timer’s awake hold still needs to be released."))
        }
        switch input.phase {
        case .armed, .warning:
            let status = input.endDate.map { t("Sleeps at (time)") + " " + clock($0, locale: locale) } ?? t("Sleep timer")
            return SleepLeadDisplay(value: KeepAwakePresentation.countdown(input.remainingSeconds), status: status, tone: .sleep,
                                    detail: t("one-minute warning before sleep"))
        case .preparing, .requesting, .accepted:
            let key = input.phase == .preparing ? "Preparing for sleep…" : input.phase == .requesting ? "Requesting sleep…"
                : "Sleep requested; waiting for the system…"
            return SleepLeadDisplay(value: KeepAwakePresentation.countdown(0), status: t(key), tone: .sleep, detail: "")
        default:
            if let target = input.chargeTarget {
                return SleepLeadDisplay(value: percent(target, language: language), status: t("Sleep at charge"), tone: .sleep, detail: "")
            }
            return SleepLeadDisplay(value: t("Off (short)"), status: t("Sleep timer"), tone: .secondary,
                                    detail: t("pick a time — the timer starts at once"))
        }
    }

    static func awake(_ input: KeepAwakeLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> SleepLeadDisplay {
        func t(_ key: String) -> String { L10n.text(key) }
        guard input.available else {
            return SleepLeadDisplay(value: "—", status: t("Unavailable"), tone: .secondary,
                                    detail: t("Keep Awake is unavailable in this build or simulation."))
        }
        if input.hasOwnedAssertion && !input.isActive {
            return SleepLeadDisplay(value: "—", status: t("Check session"), tone: .attention, detail: "")
        }
        let noIdle = t("the Mac won’t idle-sleep")
        if input.isActive {
            if input.untilStopped { return SleepLeadDisplay(value: "∞", status: t("Keep Awake"), tone: .awake, detail: noIdle) }
            let end = input.endDate.map { t("until (lead)") + " " + clock($0, locale: locale) }
            return SleepLeadDisplay(value: KeepAwakePresentation.countdown(input.remainingSeconds), status: t("Keep Awake"), tone: .awake,
                                    detail: [end, noIdle].compactMap { $0 }.joined(separator: " · "))
        }
        if let target = input.chargeTarget {
            return SleepLeadDisplay(value: percent(target, language: language), status: t("Keep awake until charge"), tone: .awake, detail: noIdle)
        }
        return SleepLeadDisplay(value: t("Off (short)"), status: t("Keep Awake"), tone: .secondary,
                                detail: t("pick a time — it starts at once"))
    }
}

// MARK: Reports (pure, testable)

/// What the Reports tab shows of one observed sleep interval. Only values the record holds; a missing one is «—».
enum SleepReportDisplay {
    /// «−3 %» (a loss), «+1 %» (a gain), «0 %»; nil when the change is not calculated.
    static func change(_ record: SleepSessionRecord, language: String = L10n.language, locale: Locale = L10n.locale) -> String? {
        guard let loss = record.chargeChangePercentagePoints, loss.isFinite else { return nil }
        let prefix = loss > 0 ? "−" : loss < 0 ? "+" : ""
        let number = abs(loss).formatted(.number.locale(locale).precision(.fractionLength(0...1)))
        return prefix + number + (language == "ru" ? " %" : "%")
    }

    /// Charge change per hour over the observed interval: an estimate (the interval connects observations, it is not
    /// measured time asleep), so only for intervals of at least half an hour.
    static func drainPerHour(_ record: SleepSessionRecord) -> Double? {
        guard let loss = record.chargeChangePercentagePoints, let seconds = record.notificationIntervalSeconds,
              loss.isFinite, seconds.isFinite, seconds >= 1800 else { return nil }
        return loss / (seconds / 3600)
    }

    /// «сегодня 01:12 – 08:30» (lead, lowercase) or «Сегодня 01:12 – 08:30» (row).
    static func interval(_ record: SleepSessionRecord, lead: Bool, now: Date = Date(), calendar: Calendar = .current,
                         locale: Locale = L10n.locale) -> String {
        guard let start = record.sleepBoundary?.wallDate ?? record.wakeBoundary?.wallDate else { return "—" }
        let time = DateFormatter(); time.locale = locale; time.timeStyle = .short
        let day: String
        if calendar.isDate(start, inSameDayAs: now) { day = L10n.text(lead ? "today (lead)" : "Today") }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            day = L10n.text(lead ? "yesterday (lead)" : "Yesterday")
        } else {
            day = start.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        var text = day + " " + time.string(from: start)
        if record.sleepBoundary != nil, let end = record.wakeBoundary?.wallDate, end >= start {
            text += " – " + time.string(from: end)
        }
        return text
    }

    /// «61 → 58 %»; nil when the wake reading is missing (the row says so instead).
    static func endpoints(_ record: SleepSessionRecord, language: String = L10n.language, locale: Locale = L10n.locale) -> String? {
        guard let after = record.after else { return nil }
        func number(_ value: Double) -> String { value.formatted(.number.locale(locale).precision(.fractionLength(0...1))) }
        let before = record.before.map { number($0.chargePercent) } ?? "—"
        return before + " → " + number(after.chargePercent) + (language == "ru" ? " %" : "%")
    }

    static func percentDisplay(_ endpoint: SleepBatteryEndpoint?, locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let endpoint, endpoint.chargePercent.isFinite else { return .unavailable }
        return ReadingDisplay(number: endpoint.chargePercent.formatted(.number.locale(locale).precision(.fractionLength(0...1))),
                              unit: "%", approximate: false, state: .live, masked: false)
    }

    static func drainDisplay(_ record: SleepSessionRecord?, locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let record, var rate = drainPerHour(record) else { return .unavailable }
        if (rate * 10).rounded() == 0 { rate = 0 }
        let prefix = rate > 0 ? "−" : rate < 0 ? "+" : ""
        return ReadingDisplay(number: prefix + abs(rate).formatted(.number.locale(locale).precision(.fractionLength(1))),
                              unit: L10n.text("pp/h"), approximate: true, state: .live, masked: false)
    }
}

/// Words of the observation details (the same keys as the old reports panel).
enum SleepReportWords {
    static func phase(_ value: SleepSessionPhase) -> String {
        switch value {
        case .awaitingWake: "Awaiting wake"
        case .awaitingReading: "Awaiting fresh reading"
        case .closed: "Recorded"
        case .incomplete: "Incomplete"
        }
    }
    static func power(_ value: SleepPowerEvidence) -> String {
        switch value {
        case .batteryAtBothObservations: "Battery power at both observations."
        case .externalPowerObserved: "External power was observed. This is a mixed-power interval."
        case .unavailable: "Power-source evidence is unavailable."
        }
    }
    static func assertion(_ value: SleepAssertionType) -> String {
        switch value {
        case .displayIdle: "Prevents idle display sleep"
        case .systemIdle: "Prevents idle system sleep"
        case .systemSleep: "System-sleep assertion active"
        case .unknown: "Unknown assertion type"
        }
    }
    static func issue(_ value: SleepSessionIssue) -> String {
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

// MARK: Page

/// Sleep & drain page of the main window (direction C): page tabs «Таймер сна · Не засыпать · Отчёты» bound to
/// `navigation.sleepPage`. The two control tabs host the quick menu's own pill panels, Sleep at charge panels and lid
/// switches (same views, actions and confirmations); Reports shows the recorded intervals and the current blockers.
@MainActor struct SleepDrainPage: View {
    var model: TilveroModel
    private var page: SleepPage { model.navigation.sleepPage }

    var body: some View {
        let _ = RenderProbe.hit("SleepDrainPage")
        WindowTabbedPage {
            WindowPageTabs(label: L10n.text("Sleep & drain"),
                           selection: Binding(get: { model.navigation.sleepPage }, set: { model.navigation.navigate(to: .sleep($0)) }),
                           values: SleepPage.allCases) { $0.title }
                .accessibilityIdentifier("sleep-page")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                    switch page {
                    case .timer: SleepTimerTab(model: model)
                    case .awake: KeepAwakeTab(model: model)
                    case .reports: SleepReportsTab(model: model)
                    }
                }
                .padding(WindowTheme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .environment(\.sleepPillsLayout, .window)
        .navigationTitle(WindowSection.entry(.sleep).title)
        .toolbar {
            if page == .reports {
                ToolbarItem(placement: .primaryAction) {
                    SleepReportsRefreshButton(model: model)
                }
            }
        }
    }
}

@MainActor private struct SleepReportsRefreshButton: View {
    var model: TilveroModel
    var body: some View {
        // The same call as the old reports panel's Refresh.
        Button { Task { await model.refreshSleepActivity() } } label: {
            Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(model.isDemo || model.isReadingSleepActivity)
        .help(L10n.text("Refresh"))
        .accessibilityIdentifier("sleep-reports-refresh")
    }
}

// MARK: Lead view

/// The window lead (`LeadLine` layout) with a free status colour: Keep Awake uses the user's chosen colour.
@MainActor private struct SleepLeadLine: View {
    @Environment(\.windowTheme) private var theme
    let lead: SleepLeadDisplay
    let awakeColor: Color
    private var statusColor: Color {
        switch lead.tone {
        case .secondary: .secondary
        case .sleep: WindowTheme.sleep
        case .awake: awakeColor
        case .attention: .orange
        }
    }
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(lead.value).font(.system(size: WindowTheme.leadValueSize, weight: .semibold)).monospacedDigit()
                .foregroundStyle(lead.value == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text(lead.status).font(.system(size: 15, weight: .semibold)).foregroundStyle(statusColor)
                if !lead.detail.isEmpty {
                    Text(lead.detail).foregroundStyle(theme.secondaryIsPrimary ? .primary : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sleep-lead")
    }
}

// MARK: Timer tab

@MainActor private struct SleepTimerTab: View {
    var model: TilveroModel
    var body: some View {
        SleepTimerLead(model: model)
        WindowNoticeView(model: model)
        WindowTile { SleepTimerPillsPanel(model: model, showsCompanions: false) }
        WindowTile { SleepAtChargePanel(model: model) }
        if model.lidSleep.isAvailable {
            WindowTile { LidSleepOverrideRow(model: model, mode: .scheduledSleep) }
        }
    }
}

@MainActor private struct SleepTimerLead: View {
    var model: TilveroModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
            let timer = model.sleepTimer
            let input = SleepTimerLeadInputs(available: timer.isAvailable, phase: timer.phase, needsHoldRelease: timer.needsHoldRelease,
                                             remainingSeconds: timer.remainingSeconds, endDate: timer.endDate,
                                             chargeTarget: model.sleepAtCharge.target)
            SleepLeadLine(lead: SleepDrainLead.timer(input), awakeColor: .secondary)
        }
    }
}

// MARK: Keep Awake tab

@MainActor private struct KeepAwakeTab: View {
    var model: TilveroModel
    var body: some View {
        KeepAwakeLead(model: model)
        WindowNoticeView(model: model)
        WindowTile { KeepAwakePillsPanel(model: model, showsCompanions: false) }
        WindowTile { SleepAtChargePanel(model: model, mode: .keepAwake) }
        WindowTile { ClosedLidExplanationView(model: model) }
    }
}

@MainActor private struct KeepAwakeLead: View {
    var model: TilveroModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
            let awake = model.keepAwake
            let input = KeepAwakeLeadInputs(available: awake.isAvailable, hasOwnedAssertion: awake.hasOwnedAssertion,
                                            isActive: awake.isActive, untilStopped: awake.expiry == .untilStopped,
                                            remainingSeconds: awake.remainingSeconds, endDate: awake.endDate,
                                            chargeTarget: model.keepAwakeUntilCharge.target)
            SleepLeadLine(lead: SleepDrainLead.awake(input), awakeColor: Color(nsColor: model.awakeIndicatorColor.nsColor))
        }
    }
}

// MARK: Reports tab

@MainActor private struct SleepReportsTab: View {
    var model: TilveroModel
    @State private var details: SleepSessionRecord?
    private var records: [SleepSessionRecord] {
        model.sleepSessions.sorted { ($0.observedAt ?? .distantPast) > ($1.observedAt ?? .distantPast) }
    }

    var body: some View {
        let records = model.isDemo ? [] : records
        let latest = records.first
        SleepLeadLine(lead: lead(latest), awakeColor: .secondary)
        WindowNoticeView(model: model)
        if model.isDemo {
            NoticeTile(symbol: "testtube.2", text: L10n.text("Sleep reports are not collected in Simulation."), tint: .secondary)
        } else {
            if !model.historyEnabled {
                NoticeTile(symbol: "pause.circle", text: L10n.text("History is off. New sleep intervals are not recorded."), tint: .secondary)
            }
            if let error = model.sleepReportError {
                NoticeTile(symbol: "exclamationmark.triangle", text: error)
            }
        }
        ReadingStrip(items: strip(latest)) { item in
            switch item.id {
            case "before": endpointInfo(title: L10n.text("Before sleep (tile)"), latest?.before)
            case "after": endpointInfo(title: L10n.text("After wake"), latest?.after)
            default:
                SectionInfoButton(title: L10n.text("Drain per hour"), paragraphs: [
                    L10n.text("Charge change over the observed interval, per hour."),
                    L10n.text("The interval connects observations, not measured time asleep."),
                ], id: "sleep-drain-info")
            }
        }
        SleepSectionHeading(title: L10n.text("Sleep intervals"))
        if records.isEmpty {
            WindowTile {
                EmptyFrame(symbol: "moon.zzz", title: L10n.text("No observed sleep intervals yet"),
                           detail: model.isDemo ? nil : L10n.text("Sleep reports start with the next sleep observed while Tilvero is running. Previous nights are not reconstructed."),
                           height: 90)
            }
        } else {
            WindowRowsTile(rows: records.prefix(10).map { record in
                let value = SleepReportDisplay.endpoints(record)
                return WindowRow(id: record.id.uuidString, label: SleepReportDisplay.interval(record, lead: false),
                                 value: value ?? L10n.text("no wake reading"), dim: value == nil,
                                 action: { details = record })
            })
        }
        SleepBlockers(model: model)
            .sheet(item: $details) { record in
                SleepObservationDetails(record: record) { details = nil }
            }
            .task { await model.refreshSleepActivity() }
    }

    private func lead(_ record: SleepSessionRecord?) -> SleepLeadDisplay {
        guard let record else {
            return SleepLeadDisplay(value: "—", status: L10n.text("No data"), tone: .secondary,
                                    detail: model.isDemo ? L10n.text("Sleep reports are not collected in Simulation.")
                                                         : L10n.text("No observed sleep intervals yet"))
        }
        var detail = SleepReportDisplay.interval(record, lead: true)
        if let seconds = record.notificationIntervalSeconds { detail += " · " + WindowDuration.text(minutes: Int(seconds / 60)) }
        return SleepLeadDisplay(value: SleepReportDisplay.change(record) ?? "—", status: L10n.text("Last sleep"), tone: .sleep, detail: detail)
    }

    private func strip(_ record: SleepSessionRecord?) -> [ReadingStripItem] {
        [ReadingStripItem(id: "before", title: L10n.text("Before sleep (tile)"), display: SleepReportDisplay.percentDisplay(record?.before)),
         ReadingStripItem(id: "after", title: L10n.text("After wake"), display: SleepReportDisplay.percentDisplay(record?.after)),
         ReadingStripItem(id: "drain", title: L10n.text("Drain per hour"), display: SleepReportDisplay.drainDisplay(record))]
    }

    @ViewBuilder private func endpointInfo(title: String, _ endpoint: SleepBatteryEndpoint?) -> some View {
        if let endpoint {
            SectionInfoButton(title: title, paragraphs: [
                L10n.text("Collected") + ": " + endpoint.collectedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().locale(L10n.locale)),
                L10n.text("Source") + ": " + endpoint.source,
            ], id: "sleep-endpoint-info-" + title)
        }
    }
}

@MainActor private struct SleepSectionHeading<Trailing: View>: View {
    let title: String
    var info: (title: String, paragraphs: [String])?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let info { SectionInfoButton(title: info.title, paragraphs: info.paragraphs, id: "sleep-heading-info") }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 4).padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

extension SleepSectionHeading where Trailing == EmptyView {
    init(title: String) { self.init(title: title, info: nil) { EmptyView() } }
}

/// «Что мешает сну» (i) with the read time, then one row per current process assertion.
@MainActor private struct SleepBlockers: View {
    var model: TilveroModel
    var body: some View {
        let activity = model.sleepActivity
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            SleepSectionHeading(title: L10n.text("Sleep blockers"), info: (L10n.text("Sleep blockers"), [
                L10n.text("Current observations do not explain past sleep intervals."),
                L10n.text("Process observations stay in memory. Names, paths and assertion descriptions are not written to sleep history."),
            ])) {
                if model.isReadingSleepActivity { ProgressView().controlSize(.small) }
                if let activity {
                    Text(activity.collectedAt.formatted(.dateTime.hour().minute().locale(L10n.locale)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            WindowRowsTile(rows: rows(activity))
        }
    }

    private func rows(_ activity: SleepAssertionSnapshot?) -> [WindowRow] {
        if model.isDemo { return [WindowRow(id: "demo", label: L10n.text("Sleep reports are not collected in Simulation."), value: "", dim: true)] }
        guard let activity else { return [WindowRow(id: "none", label: L10n.text("Not collected yet"), value: "", dim: true)] }
        if activity.processAvailability == .available {
            if activity.rows.isEmpty { return [WindowRow(id: "empty", label: L10n.text("No active process assertions observed."), value: "")] }
            return activity.rows.prefix(20).map { row in
                let name = row.processName ?? row.processID.map { L10n.text("Process") + " \($0)" } ?? L10n.text("Process name unavailable")
                return WindowRow(id: row.id, label: name, value: L10n.text(SleepReportWords.assertion(row.type)))
            }
        }
        if activity.aggregateAvailability == .available {
            if activity.activeTypes.isEmpty { return [WindowRow(id: "empty", label: L10n.text("No active sleep-prevention types observed."), value: "")] }
            return activity.activeTypes.map { WindowRow(id: $0.rawValue, label: L10n.text(SleepReportWords.assertion($0)), value: "") }
        }
        return [WindowRow(id: "unavailable", label: L10n.text("Per-process sleep-prevention status is unavailable."), value: "", dim: true)]
    }
}

/// Observation details of one interval (what the old panel's disclosure showed), in a sheet.
@MainActor private struct SleepObservationDetails: View {
    let record: SleepSessionRecord
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("Observation details")).font(.headline)
                Spacer()
                Button(L10n.text("Done"), action: onClose).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(SleepReportDisplay.interval(record, lead: false)).font(.system(size: 13, weight: .semibold))
                    Label(L10n.text(SleepReportWords.phase(record.phase)), systemImage: record.phase == .closed ? "checkmark.circle" : "clock")
                        .foregroundStyle(.secondary)
                    endpoint("Before sleep (tile)", record.before, boundary: record.sleepBoundary, before: true)
                    Divider()
                    endpoint("After wake", record.after, boundary: record.wakeBoundary, before: false)
                    Divider()
                    Text(L10n.text(SleepReportWords.power(record.powerEvidence))).foregroundStyle(.secondary)
                    ForEach(record.issues, id: \.self) { issue in
                        Label(L10n.text(SleepReportWords.issue(issue)), systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                    Text(L10n.text("Power changes between observations are unknown. A zero percentage change does not mean zero energy use."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Elapsed observation time is not measured time asleep. Internal wakes, wake reasons and per-app energy are not available from these observations."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
    }

    private func endpoint(_ titleKey: String, _ value: SleepBatteryEndpoint?, boundary: SleepObservationStamp?, before: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(titleKey)).font(.system(size: 13, weight: .semibold))
            Group {
                if let value {
                    Text(L10n.text("Collected") + ": " + date(value.collectedAt))
                    Text(L10n.text("Source") + ": " + value.source)
                    Text(L10n.text("Source measurement time") + ": " + (value.sourceSampleAt.map(date) ?? L10n.text("Unavailable")))
                } else {
                    Text(L10n.text("No reading"))
                }
                if let boundary {
                    Text(L10n.text(before ? "Sleep notification" : "Wake notification") + ": " + date(boundary.wallDate))
                    if let value, let delay = SleepEndpointTiming.seconds(value, boundary: boundary, before: before) {
                        Text(L10n.text(before ? "Reading before notification" : "Reading after notification") + ": "
                             + delay.formatted(.number.precision(.fractionLength(0))) + " " + L10n.text("seconds"))
                    } else {
                        Text(L10n.text("Reading delay unavailable"))
                    }
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func date(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().locale(L10n.locale))
    }
}
