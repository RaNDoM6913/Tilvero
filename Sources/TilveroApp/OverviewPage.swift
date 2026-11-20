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
                WindowNoticeView(model: model)
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
        case "Connected, charging state unavailable": input.power = .connectedStateUnknown
        default: input.power = .unknown
        }
        if !model.isDemo, let setting = model.nativeCharge.nativeSetting, setting.isFresh, setting.configuration.enabled {
            input.limit = setting.configuration.target
        }
        func seconds(_ id: String) -> Double? {
            guard let reading = reading(id), reading.availability == .available, reading.freshness != .stale,
                  let value = reading.value?.doubleValue, value > 0 else { return nil }
            return value
        }
        input.secondsToTarget = seconds("070")
        input.secondsToFull = seconds("069")
        let adapter = ReadingDisplay.make(reading("050"), fahrenheit: false, fractionDigits: 0...0)
        if adapter.number != nil, adapter.state != .stale { input.adapter = adapter.text }
        if input.power == .onBattery, let forecast = model.dischargeForecast { input.forecastSeconds = forecast.lowerSeconds...max(forecast.lowerSeconds, forecast.upperSeconds) }
        let lead = OverviewLead.make(input)
        return LeadLine(lead: lead) {
            if let charge = reading("011") { ReadingInfoButton(reading: charge, fahrenheit: model.fahrenheit) }
        }
    }
}

// MARK: Notice

/// The one notice under a page's lead (shared by the pages).
@MainActor struct WindowNoticeView: View {
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
            NoticeTile(symbol: notice.symbol, text: notice.text, tint: notice.isWarning ? .orange : .secondary, button: button(notice.action))
        }
    }
    private func button(_ action: NoticeDisplay.Action?) -> (title: String, action: @MainActor () -> Void)? {
        switch action {
        case .restore: (L10n.text("Restore original settings"), { model.restoreAll() })
        case .returnControl: (L10n.text("Return control to macOS"), { model.restoreAll() })
        case .diagnostics: (L10n.text("Details"), { model.navigation.navigate(to: .section(.diagnostics)) })
        case nil: nil
        }
    }
}

// MARK: Session tile (only while Keep Awake or the sleep timer runs)

@MainActor private struct OverviewSessionTile: View {
    var model: TilveroModel
    /// The last action error and the session it belongs to (a new session never shows an old error).
    @State private var failure: (session: String, text: String)?

    var body: some View {
        let awake = model.keepAwake
        let timer = model.sleepTimer
        if awake.hasOwnedAssertion {
            // Tokens are captured when the controls are drawn: a click never acts on a session started meanwhile.
            let session = awake.ownedAssertionID.map { "awake:\($0)" } ?? "awake"
            let stopToken = awake.ownedAssertionID.map(SleepControlToken.awake)
            let extendToken = SleepPillActions.controlToken(model, awake: true)
            tile(session: session) {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(Color(nsColor: model.awakeIndicatorColor.nsColor)).accessibilityHidden(true)
                Text(L10n.text("Keep Awake")).font(.system(size: 13, weight: .semibold))
                if !awake.isActive {
                    Text(L10n.text("Check session")).foregroundStyle(.orange)
                } else if let end = OverviewKeepAwake.endText(expiry: awake.expiry, endDate: awake.endDate) {
                    Text(end).foregroundStyle(.secondary).monospacedDigit()
                } else if awake.expiry == .untilStopped {
                    Text("∞").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let extendToken, SleepPillActions.canExtend(model, token: extendToken, minutes: 15) {
                    Button(L10n.text("+15 min")) { run(session) { try SleepPillActions.extend(model, token: extendToken, minutes: 15) } }
                }
                Button(L10n.text("Stop")) {
                    run(session) { try SleepPillActions.setAwakeEnabled(model, enabled: false, token: stopToken) }
                }
            }
        } else if timer.isActive {
            let session = timer.sessionID.map { "timer:\($0)" } ?? "timer"
            let token = timer.sessionID.map(SleepControlToken.timer)
            let extendToken = SleepPillActions.controlToken(model, awake: false)
            tile(session: session) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(WindowTheme.sleep).accessibilityHidden(true)
                Text(L10n.text("Sleep timer")).font(.system(size: 13, weight: .semibold))
                if let end = timer.endDate {
                    Text(OverviewKeepAwake.untilText(end)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if let extendToken, SleepPillActions.canExtend(model, token: extendToken, minutes: 15) {
                    Button(L10n.text("+15 min")) { run(session) { try SleepPillActions.extend(model, token: extendToken, minutes: 15) } }
                }
                Button(L10n.text("Cancel")) {
                    run(session) { try SleepPillActions.setTimerEnabled(model, enabled: false, token: token) }
                }
            }
        }
    }

    private func tile<Content: View>(session: String, @ViewBuilder content: () -> Content) -> some View {
        let row = HStack(spacing: 10) { content() }
        return WindowTile {
            VStack(alignment: .leading, spacing: 6) {
                row
                if let failure, failure.session == session {
                    Text(failure.text).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run(_ session: String, _ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = (session, error.localizedDescription) }
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
            // The direction comes from the snapshot's charging state, not from the sign of each live sample
            // (no title flicker near the limit).
            let batteryTitle: String = switch ReadingPresentation.chargingStateKey(model.snapshot) {
            case "Charging": "Into battery"
            case "On battery": "From battery"
            default: "Battery (short)"
            }
            ReadingStrip(items: [
                ReadingStripItem(id: "054", title: L10n.text("Input"),
                                 display: adapterAbsent ? .unavailable : live("054", fahrenheit: fahrenheit),
                                 tint: WindowTheme.inputPower, reading: reading("054")),
                ReadingStripItem(id: "038", title: L10n.text(batteryTitle),
                                 display: live("038", fahrenheit: fahrenheit, magnitude: true),
                                 tint: WindowTheme.batteryPower, reading: reading("038")),
                ReadingStripItem(id: "039", title: L10n.text("Temperature"),
                                 display: live("039", fahrenheit: fahrenheit), reading: reading("039")),
                ReadingStripItem(id: "026", title: L10n.text("Capacity"),
                                 display: capacity(fahrenheit: fahrenheit), reading: reading("026")),
            ]) { item in
                if item.id == "026", let reading = item.reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            }
        }
    }

    /// The newest live SMC point (about 1 Hz while the Hour chart is on screen) when it is newer than the snapshot
    /// and the snapshot reading itself is usable; otherwise the snapshot's own reading. A live point is a measured
    /// value of its own: it does not inherit the registry reading's provenance, and it never revives a reading the
    /// registry reports as unavailable.
    private func live(_ id: String, fahrenheit: Bool, magnitude: Bool = false) -> ReadingDisplay {
        let base = reading(id)
        let snapshot = ReadingDisplay.make(base, fahrenheit: fahrenheit, magnitude: magnitude)
        guard snapshot.number != nil, let base, model.wantsLiveCharts, let point = model.live.tail.points(id: id).last,
              point.date > base.collectedAt, Date().timeIntervalSince(point.date) < 5 else { return snapshot }
        let measured = CatalogReading(definition: base.definition, value: .decimal(point.value), unit: base.unit,
                                      source: "SMC", collectedAt: point.date, provenance: .measured,
                                      availability: .available, freshness: .fresh)
        return ReadingDisplay.make(measured, fahrenheit: fahrenheit, magnitude: magnitude)
    }

    /// The weekly median of capacity retention when published, otherwise the instantaneous 026 (both «≈»).
    private func capacity(fahrenheit: Bool) -> ReadingDisplay {
        let instant = ReadingDisplay.make(reading("026"), fahrenheit: fahrenheit)
        guard let weekly = model.weeklyCapacity, weekly.percent.isFinite else { return instant }
        let number = weekly.percent.formatted(.number.locale(L10n.locale).precision(.fractionLength(1)))
        return ReadingDisplay(number: number, unit: "%", approximate: true, state: .live, masked: false)
    }
}

// MARK: Power chart

/// Day and week series, built off the main actor for one key (range, history revision, five-minute clock bucket).
private struct RecordedSeries: Sendable {
    let key: RecordedKey
    var input: [HistoryChartPoint] = []
    var battery: [HistoryChartPoint] = []
    var charge: [HistoryChartPoint] = []
    let window: ClosedRange<Date>

    /// Builds only the measurements a tile draws; stops early when its task was cancelled.
    static func build(_ samples: [HistorySample], key: RecordedKey, measurements: Set<HistorySeries.Measurement>, now: Date) -> RecordedSeries {
        let window = now.addingTimeInterval(-key.range.seconds)...now
        var result = RecordedSeries(key: key, window: window)
        func series(_ measurement: HistorySeries.Measurement) -> [HistoryChartPoint] {
            guard measurements.contains(measurement), !Task.isCancelled else { return [] }
            return HistorySeries.downsample(HistorySeries.points(samples, measurement: measurement, window: window), window: window)
        }
        result.input = series(.inputPower)
        result.battery = series(.batteryPower)
        result.charge = series(.charge)
        return result
    }
}

/// What a recorded chart was built for. The clock bucket moves the window forward even while nothing is recorded.
private struct RecordedKey: Hashable, Sendable {
    let range: OverviewRange
    let count: Int
    let last: UUID?
    let bucket: Int

    @MainActor init(range: OverviewRange, model: TilveroModel, now: Date = Date()) {
        self.range = range
        count = model.history.count
        last = model.history.last?.id
        bucket = Int(now.timeIntervalSince1970 / 300)
    }
}

/// Runs a recorded-series build off the main actor and cancels it with the view's task.
@MainActor private func buildRecorded(_ model: TilveroModel, key: RecordedKey, measurements: Set<HistorySeries.Measurement>) async -> RecordedSeries? {
    let samples = model.history, now = Date()
    let work = Task.detached(priority: .userInitiated) { RecordedSeries.build(samples, key: key, measurements: measurements, now: now) }
    let built = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    return Task.isCancelled ? nil : built
}

@MainActor private struct OverviewPowerChartTile: View {
    var model: TilveroModel
    let range: OverviewRange
    @State private var recorded: RecordedSeries?

    var body: some View {
        let key = RecordedKey(range: range, model: model)
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text("Power, W"), detail: L10n.text(rangeWordKey)) {
                    HStack(spacing: 10) {
                        if model.snapshot.adapterIsConnected != false || range != .hour {
                            ChartLegendItem(title: L10n.text("input (legend)"), color: WindowTheme.inputPower)
                        }
                        ChartLegendItem(title: L10n.text("battery (legend)"), color: WindowTheme.batteryPower)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                if range == .hour {
                    LiveRefresh(store: model.live) { hourChart }
                        .liveCharts(model, surface: .windowOverview)
                } else {
                    recordedChart(key: key)
                }
            }
        }
        .task(id: key) {
            guard range != .hour, !model.isDemo else { return }
            if let built = await buildRecorded(model, key: key, measurements: [.inputPower, .batteryPower]) { recorded = built }
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

    /// No "empty" claim before the series for this key exists: a spinner, as IA §2 asks for loading.
    @ViewBuilder private func recordedChart(key: RecordedKey) -> some View {
        if model.isDemo {
            EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                       detail: L10n.text("Simulation is never stored in history"))
        } else if let recorded, recorded.key.range == key.range, !model.historyLoading {
            if recorded.battery.isEmpty && recorded.input.isEmpty {
                EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                           detail: model.historyEnabled ? nil : L10n.text("Recording is off"))
            } else {
                chart(input: recorded.input, battery: recorded.battery, window: recorded.window, stale: false)
            }
        } else {
            EmptyFrame(symbol: "chart.xyaxis.line", title: "", loading: true)
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
    @State private var recorded: RecordedSeries?
    private var chartRange: OverviewRange { range == .week ? .week : .day }

    var body: some View {
        let key = RecordedKey(range: chartRange, model: model)
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text("Charge, %"), detail: L10n.text(chartRange == .week ? "7 days (chart)" : "24 hours (chart)")) {
                    Button(L10n.text("History")) { model.navigation.navigate(to: .section(.history)) }
                        .buttonStyle(.link)
                }
                if model.isDemo {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                               detail: L10n.text("Simulation is never stored in history"))
                } else if let recorded, recorded.key.range == key.range, !model.historyLoading {
                    if recorded.charge.isEmpty {
                        EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                                   detail: L10n.text(model.historyEnabled ? "History starts recording now" : "Recording is off"))
                    } else {
                        WindowLineChart(
                            series: [WindowChartSeries(id: "charge", points: recorded.charge, color: WindowTheme.accent)],
                            window: recorded.window, yDomain: 0...100, yValues: [0, 25, 50, 75, 100],
                            xLabels: WindowChartLabels.labels(window: recorded.window, range: chartRange))
                            .frame(height: 110)
                            .accessibilityLabel(L10n.text("Charge, %"))
                    }
                } else {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: "", loading: true)
                }
            }
        }
        .task(id: key) {
            guard !model.isDemo else { return }
            if let built = await buildRecorded(model, key: key, measurements: [.charge]) { recorded = built }
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
        // Tokens captured when the menu is drawn (a click never acts on a session started meanwhile).
        let stopToken = awake.ownedAssertionID.map(SleepControlToken.awake)
        let extendToken = SleepPillActions.controlToken(model, awake: true)
        Menu {
            if awake.hasOwnedAssertion {
                if let extendToken, SleepPillActions.canExtend(model, token: extendToken, minutes: 15) {
                    Button(L10n.text("+15 min")) { run { try SleepPillActions.extend(model, token: extendToken, minutes: 15) } }
                }
                Button(L10n.text("Stop")) {
                    run { try SleepPillActions.setAwakeEnabled(model, enabled: false, token: stopToken) }
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
        .help(L10n.text("Keep Awake"))
        .accessibilityIdentifier("overview-awake-menu")
        .confirmationDialog(consent?.title ?? "", isPresented: $confirms, titleVisibility: .visible) {
            Button(consent?.action ?? L10n.text("Apply")) { if let pending { apply(pending, consent: consent) } }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil; consent = nil }
        } message: { Text(consent?.explanation ?? "") }
        .alert(L10n.text("Keep Awake"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error.map(L10n.text) ?? "") }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
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
