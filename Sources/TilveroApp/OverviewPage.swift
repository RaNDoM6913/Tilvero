// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore
import PowerPersistence

/// Range of the Overview power chart (toolbar picker). Hour is live (about 1 Hz); Day and Week are recorded history.
enum OverviewRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .hour: "Hour (range)"
        case .day: "Day (range)"
        case .week: "Week (range)"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        }
    }
}

/// Overview page of the main window (direction C): lead, notice, running session, one reading strip, power chart for
/// the chosen range, charge chart, rows to Charging and Cooling. Reads only what it draws; every missing number is «—».
@MainActor struct OverviewPage: View {
    var model: TilveroModel
    @State private var range: OverviewRange = .hour

    var body: some View {
        let _ = RenderProbe.hit("OverviewPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                OverviewLeadView(model: model)
                OverviewNoticeView(model: model)
                OverviewSessionTile(model: model)
                OverviewReadingStrip(model: model)
                OverviewPowerChartTile(model: model, range: range)
                OverviewChargeChartTile(model: model, range: range)
                OverviewRows(model: model)
                if model.isDemo { SimulationPanel(model: model) }
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.overview).title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L10n.text("Range"), selection: $range) {
                    ForEach(OverviewRange.allCases) { Text(L10n.text($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityIdentifier("overview-range")
            }
            ToolbarItem(placement: .primaryAction) {
                OverviewAwakeMenu(model: model)
            }
        }
    }
}

// MARK: Lead

@MainActor private struct OverviewLeadView: View {
    var model: TilveroModel
    private func reading(_ id: String) -> CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        let snapshot = model.snapshot
        let levelUsable = snapshot.chargePercent.availability == .available || snapshot.chargePercent.freshness == .stale
        var input = OverviewLeadInputs()
        input.level = levelUsable ? ReadingPresentation.validLevel(snapshot.chargePercent.value) : nil
        input.stale = snapshot.chargePercent.freshness == .stale
        input.lastRead = reading("011").map { $0.sourceSampleAt ?? $0.collectedAt }
        switch ReadingPresentation.chargingStateKey(snapshot) {
        case "Charging": input.power = .charging
        case "On battery": input.power = .onBattery
        case "Connected, not charging": input.power = .connectedNotCharging
        default: input.power = .unknown
        }
        if !model.isDemo, let setting = model.nativeCharge.nativeSetting, setting.isFresh, setting.configuration.enabled {
            input.limit = setting.configuration.target
        }
        for id in ["070", "069"] {
            if let reading = reading(id), reading.availability == .available, reading.freshness != .stale,
               let seconds = reading.value?.doubleValue, seconds > 0 { input.secondsToTarget = seconds; break }
        }
        let adapter = ReadingDisplay.make(reading("050"), fahrenheit: false, fractionDigits: 0...0)
        if adapter.number != nil, adapter.state != .stale { input.adapter = adapter.text }
        if input.power == .onBattery, let forecast = model.dischargeForecast { input.forecastSeconds = forecast.lowerSeconds }
        let lead = OverviewLead.make(input)
        return LeadLine(lead: lead) {
            if let charge = reading("011") { ReadingInfoButton(reading: charge, fahrenheit: model.fahrenheit) }
        }
    }
}

// MARK: Notice

@MainActor private struct OverviewNoticeView: View {
    var model: TilveroModel
    var body: some View {
        let attention = model.isDemo ? nil : model.nativeCharge.presentation()
        let input = NoticeDisplay.Inputs(
            recoveryRequired: model.liveControl.recoveryRequired,
            ownsSettings: model.liveControl.hasOwnedSettings,
            attentionKey: attention.flatMap { $0.showsAttentionBanner ? $0.attention.titleKey : nil },
            storeError: model.storeError,
            notice: model.notices.current(excluding: model.isDemo ? [.chargeStatus, .simulation] : [.chargeStatus])?.text)
        if let notice = NoticeDisplay.choose(input) {
            NoticeTile(symbol: notice.symbol, text: notice.text, button: button(notice.action))
        }
    }
    private func button(_ action: NoticeDisplay.Action?) -> (title: String, action: @MainActor () -> Void)? {
        switch action {
        case .restore: (L10n.text("Restore original settings"), { model.restoreAll() })
        case .diagnostics: (L10n.text("Details"), { model.navigation.navigate(to: .section(.diagnostics)) })
        case nil: nil
        }
    }
}

// MARK: Session tile (only while Keep Awake or the sleep timer runs)

@MainActor private struct OverviewSessionTile: View {
    var model: TilveroModel
    @State private var error: String?
    var body: some View {
        let awake = model.keepAwake
        let timer = model.sleepTimer
        if awake.hasOwnedAssertion {
            WindowTile {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(Color(nsColor: model.awakeIndicatorColor.nsColor)).accessibilityHidden(true)
                    Text(L10n.text("Keep Awake")).font(.system(size: 13, weight: .semibold))
                    if let end = OverviewKeepAwake.endText(expiry: awake.expiry, endDate: awake.isActive ? awake.endDate : nil) {
                        Text(end).foregroundStyle(.secondary).monospacedDigit()
                    } else if awake.expiry == .untilStopped {
                        Text("∞").foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                    Spacer(minLength: 8)
                    if awake.isActive, awake.expiry != .untilStopped {
                        Button(L10n.text("+15 min")) { run { try awake.extend(by: 900) } }
                    }
                    Button(L10n.text("Stop")) {
                        run { try SleepPillActions.setAwakeEnabled(model, enabled: false, token: awake.ownedAssertionID.map(SleepControlToken.awake)) }
                    }
                }
            }
        } else if timer.isActive {
            WindowTile {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(WindowTheme.sleep).accessibilityHidden(true)
                    Text(L10n.text("Sleep timer")).font(.system(size: 13, weight: .semibold))
                    if let end = timer.endDate {
                        Text(OverviewKeepAwake.untilText(end)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                    Spacer(minLength: 8)
                    Button(L10n.text("Cancel")) {
                        run { try SleepPillActions.setTimerEnabled(model, enabled: false, token: timer.sessionID.map(SleepControlToken.timer)) }
                    }
                }
            }
        }
    }
    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

// MARK: Reading strip (re-renders on live ticks, nothing else does)

@MainActor private struct OverviewReadingStrip: View {
    var model: TilveroModel
    private func reading(_ id: String) -> CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        LiveRefresh(store: model.live) {
            let fahrenheit = model.fahrenheit
            let adapterAbsent = model.snapshot.adapterIsConnected == false
            let battery = live("038")
            let batteryValue = battery.flatMap { $0.value?.doubleValue }
            let batteryTitle = batteryValue.map { $0 > 0.05 ? "Into battery" : $0 < -0.05 ? "From battery" : "Battery (short)" } ?? "Battery (short)"
            ReadingStrip(items: [
                ReadingStripItem(id: "054", title: L10n.text("Input"),
                                 display: adapterAbsent ? .unavailable : ReadingDisplay.make(live("054"), fahrenheit: fahrenheit),
                                 tint: WindowTheme.inputPower, reading: reading("054")),
                ReadingStripItem(id: "038", title: L10n.text(batteryTitle),
                                 display: ReadingDisplay.make(battery, fahrenheit: fahrenheit, magnitude: true),
                                 tint: WindowTheme.batteryPower, reading: reading("038")),
                ReadingStripItem(id: "039", title: L10n.text("Temperature"),
                                 display: ReadingDisplay.make(live("039"), fahrenheit: fahrenheit), reading: reading("039")),
                ReadingStripItem(id: "026", title: L10n.text("Capacity"),
                                 display: ReadingDisplay.make(reading("026"), fahrenheit: fahrenheit), reading: reading("026")),
            ]) { item in
                if item.id == "026", let reading = item.reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            }
        }
    }

    /// The newest live point (about 1 Hz while the Hour chart is on screen) when it is newer than the snapshot,
    /// otherwise the snapshot's own reading. Live points keep the snapshot reading's unit and provenance.
    private func live(_ id: String) -> CatalogReading? {
        guard let base = reading(id) else { return nil }
        guard model.wantsLiveCharts, let point = model.live.tail.points(id: id).last,
              point.date > base.collectedAt, Date().timeIntervalSince(point.date) < 5 else { return base }
        return CatalogReading(definition: base.definition, value: .decimal(point.value), unit: base.unit,
                              source: base.source, keyPath: base.keyPath, collectedAt: point.date,
                              provenance: base.provenance, availability: .available, freshness: .fresh)
    }
}

// MARK: Power chart

/// Day and week series, built off the main actor and kept until the history changes.
private struct RecordedSeries: Sendable {
    var input: [HistoryChartPoint] = []
    var battery: [HistoryChartPoint] = []
    var charge: [HistoryChartPoint] = []
    var window: ClosedRange<Date> = Date.distantPast...Date.distantPast

    static func build(_ samples: [HistorySample], range: OverviewRange, now: Date) -> RecordedSeries {
        let window = now.addingTimeInterval(-range.seconds)...now
        func series(_ measurement: HistorySeries.Measurement) -> [HistoryChartPoint] {
            HistorySeries.downsample(HistorySeries.points(samples, measurement: measurement, window: window), window: window)
        }
        return RecordedSeries(input: range == .hour ? [] : series(.inputPower),
                              battery: range == .hour ? [] : series(.batteryPower),
                              charge: series(.charge), window: window)
    }
}

private struct RecordedKey: Hashable { let range: OverviewRange; let count: Int; let last: UUID? }

@MainActor private struct OverviewPowerChartTile: View {
    var model: TilveroModel
    let range: OverviewRange
    @State private var recorded = RecordedSeries()

    var body: some View {
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text("Power, W"), detail: L10n.text(rangeWordKey)) {
                    HStack(spacing: 10) {
                        if model.snapshot.adapterIsConnected != false {
                            ChartLegendItem(title: L10n.text("input (legend)"), color: WindowTheme.inputPower)
                        }
                        ChartLegendItem(title: L10n.text("battery (legend)"), color: WindowTheme.batteryPower)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                if range == .hour {
                    LiveRefresh(store: model.live) { hourChart }
                        .liveCharts(model, surface: .windowOverview)
                } else {
                    recordedChart
                }
            }
        }
        .task(id: RecordedKey(range: range, count: model.history.count, last: model.history.last?.id)) {
            guard range != .hour else { return }
            let samples = model.history, range = range, now = Date()
            let built = await Task.detached(priority: .userInitiated) { RecordedSeries.build(samples, range: range, now: now) }.value
            guard !Task.isCancelled else { return }
            recorded = built
        }
    }

    private var rangeWordKey: String {
        switch range {
        case .hour: "hour (chart)"
        case .day: "24 hours (chart)"
        case .week: "7 days (chart)"
        }
    }

    @ViewBuilder private var hourChart: some View {
        let window = model.overviewChartWindow
        let adapter = model.snapshot.adapterIsConnected == false ? nil : model.metricSeries(id: "054")
        let battery = model.metricSeries(id: "038")
        let stale = battery.state == .staleTail
        if battery.points.isEmpty && (adapter?.points.isEmpty ?? true) {
            EmptyFrame(symbol: "waveform.path.ecg", title: L10n.text("No measurements (chart)"),
                       detail: model.isDemo ? L10n.text("Simulation is never stored in history") : L10n.text("They appear within seconds"),
                       loading: model.historyLoading)
        } else {
            chart(input: adapter?.points ?? [], battery: battery.points, window: window, stale: stale)
        }
    }

    @ViewBuilder private var recordedChart: some View {
        if recorded.battery.isEmpty && recorded.input.isEmpty {
            EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                       detail: model.isDemo ? L10n.text("Simulation is never stored in history") : nil,
                       loading: model.historyLoading)
        } else {
            chart(input: recorded.input, battery: recorded.battery, window: recorded.window, stale: false)
        }
    }

    private func chart(input: [HistoryChartPoint], battery: [HistoryChartPoint], window: ClosedRange<Date>, stale: Bool) -> some View {
        WindowLineChart(
            series: [WindowChartSeries(id: "054", points: input, color: stale ? .gray : WindowTheme.inputPower),
                     WindowChartSeries(id: "038", points: battery, color: stale ? .gray.opacity(0.6) : WindowTheme.batteryPower)],
            window: window,
            yDomain: HistorySeries.yDomain((input + battery).map(\.value)),
            xLabels: WindowChartLabels.labels(window: window, range: range))
            .frame(height: 120)
            .accessibilityLabel(L10n.text("Power, W"))
    }
}

// MARK: Charge chart (24 h, 7 days in Week)

@MainActor private struct OverviewChargeChartTile: View {
    var model: TilveroModel
    let range: OverviewRange
    @State private var recorded = RecordedSeries()
    private var chartRange: OverviewRange { range == .week ? .week : .day }

    var body: some View {
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text("Charge, %"), detail: L10n.text(chartRange == .week ? "7 days (chart)" : "24 hours (chart)")) {
                    Button(L10n.text("History")) { model.navigation.navigate(to: .section(.history)) }
                        .buttonStyle(.link)
                }
                if model.isDemo {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                               detail: L10n.text("Simulation is never stored in history"))
                } else if recorded.charge.isEmpty {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                               detail: L10n.text("History starts recording now"), loading: model.historyLoading)
                } else {
                    WindowLineChart(
                        series: [WindowChartSeries(id: "charge", points: recorded.charge, color: WindowTheme.accent)],
                        window: recorded.window, yDomain: 0...100, yValues: [0, 50, 100],
                        xLabels: WindowChartLabels.labels(window: recorded.window, range: chartRange),
                        gapShading: HistorySeries.gaps(recorded.charge, minimum: 1800))
                        .frame(height: 110)
                        .accessibilityLabel(L10n.text("Charge, %"))
                }
            }
        }
        .task(id: RecordedKey(range: chartRange, count: model.history.count, last: model.history.last?.id)) {
            let samples = model.history, range = chartRange, now = Date()
            let built = await Task.detached(priority: .userInitiated) { RecordedSeries.build(samples, range: range, now: now) }.value
            guard !Task.isCancelled else { return }
            recorded = built
        }
    }
}

/// Start, middle and end of a chart window in the app's language.
enum WindowChartLabels {
    static func labels(window: ClosedRange<Date>, range: OverviewRange, locale: Locale = L10n.locale,
                       language: String = L10n.language) -> [String] {
        let middle = window.lowerBound.addingTimeInterval(window.upperBound.timeIntervalSince(window.lowerBound) / 2)
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        switch range {
        case .hour:
            return [window.lowerBound, middle, window.upperBound].map { $0.formatted(time) }
        case .day:
            let yesterday = language == "ru" ? "Вчера " : "Yesterday "
            return [yesterday + window.lowerBound.formatted(time), middle.formatted(time), language == "ru" ? "Сейчас" : "Now"]
        case .week:
            let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().locale(locale)
            return [window.lowerBound.formatted(day), middle.formatted(day), language == "ru" ? "Сейчас" : "Now"]
        }
    }
}

// MARK: Rows

@MainActor private struct OverviewRows: View {
    var model: TilveroModel
    var body: some View {
        WindowRowsTile(rows: [
            WindowRow(id: "limit", label: L10n.text("macOS charge limit"), value: limitText, dim: limitText == "—",
                      action: { model.navigation.navigate(to: .section(.charging)) }),
            WindowRow(id: "cooling", label: L10n.text("Cooling"), value: coolingText, dim: coolingText == "—",
                      action: { model.navigation.navigate(to: .section(.cooling)) }),
        ])
    }
    private var limitText: String {
        let percent: (Int) -> String = { L10n.language == "ru" ? "\($0) %" : "\($0)%" }
        if let setting = model.nativeCharge.nativeSetting, setting.isFresh {
            return setting.configuration.enabled ? percent(setting.configuration.target) : L10n.text("System managed")
        }
        if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits,
           !limits.manualLimitIsConflicting, let limit = limits.manualLimit { return percent(limit) }
        return "—"
    }
    private var coolingText: String {
        let thermal = model.snapshot.catalog.first { $0.id == "044" }
        let state = thermal.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: false) }.flatMap { $0 == "—" ? nil : $0 }
        let parts = [model.fanless ? L10n.text("Fanless (cooling)") : nil, state?.lowercasedFirst(if: model.fanless)].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

private extension String {
    func lowercasedFirst(if condition: Bool) -> String {
        guard condition, let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: Toolbar Keep Awake menu

@MainActor private struct OverviewAwakeMenu: View {
    var model: TilveroModel
    @State private var pending: AwakePillRequest?
    @State private var consent: SleepPillConfirmation?
    @State private var confirms = false
    @State private var error: String?

    var body: some View {
        let awake = model.keepAwake
        Menu {
            if awake.hasOwnedAssertion {
                if awake.isActive, awake.expiry != .untilStopped {
                    Button(L10n.text("+15 min")) { try? awake.extend(by: 900) }
                }
                Button(L10n.text("Stop")) {
                    try? SleepPillActions.setAwakeEnabled(model, enabled: false, token: awake.ownedAssertionID.map(SleepControlToken.awake))
                }
                Divider()
            }
            ForEach(OverviewKeepAwake.presets, id: \.self) { minutes in
                Button(WindowDuration.text(minutes: minutes)) { apply(.duration(minutes)) }
            }
            Button("∞") { apply(.untilStopped) }
            Divider()
            Button(L10n.text("Sleep & drain") + "…") { model.navigation.navigate(to: .sleep(.awake)) }
        } label: {
            Label(L10n.text("Keep Awake"), systemImage: awake.hasOwnedAssertion ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .disabled(!awake.hasOwnedAssertion && !SleepPillActions.canChooseAwake(model))
        .help(error ?? L10n.text("Keep Awake"))
        .accessibilityIdentifier("overview-awake-menu")
        .confirmationDialog(consent?.title ?? "", isPresented: $confirms, titleVisibility: .visible) {
            Button(consent?.action ?? L10n.text("Apply")) { if let pending { apply(pending, consent: consent) } }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil; consent = nil }
        } message: { Text(consent?.explanation ?? "") }
    }

    private func apply(_ request: AwakePillRequest, consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.awake(model, request: request, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            pending = request; consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
}
