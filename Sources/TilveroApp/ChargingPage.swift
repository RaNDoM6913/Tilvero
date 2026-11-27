// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends
import PowerCore

/// Charging page of the main window (direction C, IA §3.3, one scroll, no toolbar): power lead, notice, the charge-limit
/// tile (the shared `ChargeLimitKit`, charge once, charge by time), reading strip, last-hour power chart, rows
/// «Адаптер» (+ «Ещё») and «Система». Reads only what it draws; every missing number is «—».
@MainActor struct ChargingPage: View {
    var model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("ChargingPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                ChargingLeadView(model: model)
                WindowNoticeView(model: model)
                ChargeLimitTile(model: model)
                ChargingReadingStrip(model: model)
                ChargingPowerChartTile(model: model)
                ChargingAdapterSection(model: model)
                ChargingSystemSection(model: model)
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.charging).title)
    }
}

// MARK: Composition (pure, testable)

/// Inputs of the Charging lead. The level, staleness, power state and discharge forecast are those of the Overview
/// lead (`OverviewLeadInputs`), so both pages agree on the state; the value here is power, not charge.
struct ChargingLeadInputs: Equatable, Sendable {
    var overview = OverviewLeadInputs()
    /// Live input power 054.
    var input: ReadingDisplay = .unavailable
    /// Battery power 038, magnitude.
    var battery: ReadingDisplay = .unavailable
    /// Connection transport 049 in the app's words («USB-C»).
    var transport: String?
    /// Adapter capability 050 with its unit («96 Вт»).
    var rating: String?
}

enum ChargingLead {
    static func make(_ input: ChargingLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        // Staleness and the forecast wording come from the Overview lead (one rule for both pages).
        let overview = OverviewLead.make(input.overview, language: language, locale: locale)
        switch input.overview.power {
        case .charging, .connectedNotCharging, .connectedStateUnknown:
            let value = input.input.number != nil ? input.input.text : "—"
            if input.overview.stale { return LeadDisplay(value: value, status: overview.status, tone: .attention, detail: overview.detail, stale: true) }
            var fragments = [input.transport, input.rating].compactMap { $0 }
            switch input.overview.power {
            case .charging: fragments.append(L10n.text("charging"))
            case .connectedNotCharging: fragments.append(L10n.text("not charging"))
            default: break
            }
            return LeadDisplay(value: value, status: L10n.text("On adapter"), tone: .input, detail: fragments.joined(separator: " · "))
        case .onBattery:
            let value = input.battery.number != nil ? input.battery.text : "—"
            if input.overview.stale { return LeadDisplay(value: value, status: overview.status, tone: .attention, detail: overview.detail, stale: true) }
            // The Overview's on-battery detail is exactly the forecast fragment («до 20 % ≈ 5 ч»), or empty.
            let fragments = [L10n.text("no adapter"), overview.detail].filter { !$0.isEmpty }
            return LeadDisplay(value: value, status: overview.status, tone: .battery, detail: fragments.joined(separator: " · "))
        case .unknown:
            return LeadDisplay(value: "—", status: L10n.text("Power source unavailable"), tone: .secondary, detail: "")
        }
    }
}

enum ChargingComposition {
    /// Battery power with its direction as a sign: «+7,2» into the battery, «−6,1» out of it; a value that rounds to
    /// zero carries no sign. Missing stays «—».
    static func signedBattery(_ reading: CatalogReading?, fahrenheit: Bool = false, locale: Locale = L10n.locale,
                              language: String = L10n.language) -> ReadingDisplay {
        let magnitude = ReadingDisplay.make(reading, fahrenheit: fahrenheit, magnitude: true, locale: locale, language: language)
        guard let number = magnitude.number, let value = reading?.value?.doubleValue, value.isFinite,
              (abs(value) * 10).rounded() != 0 else { return magnitude }
        return ReadingDisplay(number: (value > 0 ? "+" : "−") + number, unit: magnitude.unit,
                              approximate: magnitude.approximate, state: magnitude.state, masked: magnitude.masked)
    }

    /// The macOS limit as a read-only value: the fresh native setting first (100 % when the limit is off), then the
    /// registered manual limit read on AC; «—» when nothing fresh is known.
    static func macOSLimitText(native: NativeChargeConfiguration?, systemManual: Int?, language: String = L10n.language) -> String {
        if let text = ChargeLimitKit.text(native, language: language) { return text }
        return systemManual.map { ChargeLimitKit.percent($0, language: language) } ?? "—"
    }

    /// Adapter rows (IA §3.3): connection (015, with the transport 049 when known), 050, 051, 052, 047, 048 (masked).
    /// Without an adapter only the connection row remains.
    static func adapterRows(_ catalog: [CatalogReading], connected: Bool?, language: String = L10n.language) -> [BatteryReadingRow] {
        func reading(_ id: String) -> CatalogReading? { catalog.first { $0.id == id } }
        if connected == false {
            return [BatteryReadingRow(id: "015", label: L10n.text("Connection"), value: L10n.text("Not connected"), dim: true, infoID: "015")]
        }
        let transport = BatteryRows.value(reading("049"), fahrenheit: false)
        let connection: BatteryReadingRow
        if !transport.dim {
            connection = BatteryReadingRow(id: "015", label: L10n.text("Connection"), value: transport.text, state: transport.state, infoID: "049")
        } else if connected == true {
            connection = BatteryReadingRow(id: "015", label: L10n.text("Connection"), value: L10n.text("Connected"), infoID: "015")
        } else {
            connection = BatteryReadingRow(id: "015", label: L10n.text("Connection"), value: "—", state: .unavailable, dim: true, infoID: "015")
        }
        return [connection] + BatteryRows.rows(adapterFields, catalog: catalog, fahrenheit: false, language: language)
    }

    /// «Ещё»: 045, 046, 049 (unless the connection row already shows it), 053, 055, 056.
    static func moreRows(_ catalog: [CatalogReading], language: String = L10n.language) -> [BatteryReadingRow] {
        let transportShown = !BatteryRows.value(catalog.first { $0.id == "049" }, fahrenheit: false).dim
        return BatteryRows.rows(moreFields.filter { !(transportShown && $0.0 == "049") }, catalog: catalog, fahrenheit: false, language: language)
    }

    static let adapterFields: [(String, String?, ClosedRange<Int>, Bool)] = [
        ("050", "Power", 0...0, true), ("051", "Voltage", 0...1, true), ("052", "Current limit", 1...1, true),
        ("047", nil, 0...0, true), ("048", "Serial number", 0...0, false)]
    static let moreFields: [(String, String?, ClosedRange<Int>, Bool)] = [
        ("045", nil, 0...0, true), ("046", nil, 0...0, true), ("049", nil, 0...0, true),
        ("053", nil, 0...0, true), ("055", nil, 0...2, true), ("056", nil, 0...2, true)]

    /// «Вкл» / «Выкл», «—» when unknown.
    static func onOff(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "On" : "Off") } ?? "—"
    }
}

// MARK: Lead

@MainActor private func chargingReading(_ model: TilveroModel, _ id: String) -> CatalogReading? {
    model.snapshot.catalog.first { $0.id == id }
}

@MainActor private struct ChargingLeadView: View {
    var model: TilveroModel

    var body: some View {
        let snapshot = model.snapshot
        var input = ChargingLeadInputs()
        let levelUsable = snapshot.chargePercent.availability == .available || snapshot.chargePercent.freshness == .stale
        input.overview.level = levelUsable ? ReadingPresentation.validLevel(snapshot.chargePercent.value) : nil
        input.overview.stale = snapshot.chargePercent.freshness == .stale
        input.overview.lastRead = chargingReading(model, "011").map { $0.sourceSampleAt ?? $0.collectedAt }
        switch ReadingPresentation.chargingStateKey(snapshot) {
        case "Charging": input.overview.power = .charging
        case "On battery": input.overview.power = .onBattery
        case "Connected, not charging": input.overview.power = .connectedNotCharging
        case "Connected, charging state unavailable": input.overview.power = .connectedStateUnknown
        default: input.overview.power = .unknown
        }
        if input.overview.power == .onBattery, let forecast = model.dischargeForecast {
            input.overview.forecastSeconds = forecast.lowerSeconds...max(forecast.lowerSeconds, forecast.upperSeconds)
        }
        input.input = ReadingDisplay.make(chargingReading(model, "054"), fahrenheit: false)
        input.battery = ReadingDisplay.make(chargingReading(model, "038"), fahrenheit: false, magnitude: true)
        let transport = BatteryRows.value(chargingReading(model, "049"), fahrenheit: false)
        if !transport.dim, transport.state != .stale { input.transport = transport.text }
        let rating = ReadingDisplay.make(chargingReading(model, "050"), fahrenheit: false, fractionDigits: 0...0)
        if rating.number != nil, rating.state != .stale { input.rating = rating.text }
        let lead = ChargingLead.make(input)
        let source = input.overview.power == .onBattery ? "038" : "054"
        return LeadLine(lead: lead) {
            if let reading = chargingReading(model, source) { ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit) }
        }
    }
}

// MARK: Charge limit tile

@MainActor private struct ChargeLimitTile: View {
    var model: TilveroModel
    @State private var chosen: Int?
    @Environment(\.windowTheme) private var theme

    var body: some View {
        let mode = ChargeLimitKit.mode(model)
        let state = model.nativeCharge.presentation()
        WindowTile {
            VStack(alignment: .leading, spacing: 12) {
                switch mode {
                case .slider: editor(state)
                case .unavailable:
                    // Found, but not changeable by Tilvero right now: what macOS reports, read-only.
                    header(value: ChargeLimitKit.reported(model), applied: state.currentPreference != nil, state: state)
                    ChargeLimitUnavailableNote(model: model)
                    statusLine(state)
                    // Nothing to act on here: charge once only while it runs (its cancel stays reachable).
                    if ChargeLimitKit.showsChargeOnce(model) { actions }
                case .readOnly: readOnly
                }
                // Optimized Charging is its own macOS setting: its switch is drawn in every mode.
                if ChargeLimitKit.showsOptimizedSwitch(isDemo: model.isDemo, optimizedAvailable: model.optimizedCharging.isAvailable) {
                    Divider()
                    OptimizedChargingRow(service: model.optimizedCharging, showsHold: true)
                }
                if !model.isDemo, mode != .readOnly { ChargeByBlock(model: model, service: model.chargeBy) }
            }
        }
        .task {
            if model.isDemo { return }
            if mode == .readOnly { await model.refreshSystemChargeLimit(reusingRecent: true) }
            else { await model.refreshNativeChargeIfStale() }
        }
    }

    private var current: Int? {
        model.isDemo ? model.chargeState?.appliedTarget : ChargeLimitKit.current(model.nativeCharge.presentation().currentPreference)
    }

    private func header(value: Int?, applied: Bool, state: NativeChargePresentation) -> some View {
        HStack(spacing: 5) {
            Text(L10n.text("Charge limit")).font(.headline)
            ChargeLimitInfoButton()
            if model.isDemo {
                Text(L10n.text("Simulation")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Spacer(minLength: 8)
            // A fixed slot: a native read or an apply comes and goes without moving the row.
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                .opacity(!model.isDemo && ChargeLimitKit.isWorking(model, state) ? 1 : 0)
                .accessibilityHidden(true)
            // A level that is not the one macOS holds (pending, or still being applied) is never drawn as applied; "—" while
            // macOS has not reported a level (never a guessed number).
            let secondary: Color = theme.secondaryIsPrimary ? .primary : .secondary
            let held = applied && value != nil
            let _ = RenderProbe.held("charging.readout", held)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                StudioText(ChargeLimitKit.readout(value), id: "charging.readout")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(held ? Color.primary : secondary)
                if value != nil {
                    Text(L10n.language == "ru" ? " %" : "%").font(.system(size: 16, weight: .medium)).foregroundStyle(secondary)
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Charge limit"))
            .accessibilityValue(value.map { ChargeLimitKit.percent($0) } ?? "—")
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder private func editor(_ state: NativeChargePresentation) -> some View {
        let shown = ChargeLimitKit.shown(chosen: chosen, model: model)
        // Only the simulation's lower target waits; the native limit is set at once (as in System Settings).
        let pendingTarget = model.isDemo ? model.pendingTarget : nil
        header(value: shown, applied: ChargeLimitKit.isApplied(shown: shown, current: current, pendingTarget: pendingTarget), state: state)
        if let pending = ChargeLimitKit.pendingText(pendingTarget: pendingTarget) {
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(.orange).accessibilityHidden(true)
                Text(pending).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let current { Text(L10n.text("Now") + " " + ChargeLimitKit.percent(current)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
        ChargeLimitLevelSlider(model: model, targets: ChargeLimitKit.targets(model), chosen: $chosen)
            .steadyControl(ChargeLimitKit.sliderLook(model, targets: ChargeLimitKit.targets(model)))
        statusLine(state)
        actions
    }

    /// Charge once: shown with the slider (as in the quick menu, where it stays dimmed until it can start), and with the
    /// read-only native value only while it runs. Charge by time and the Optimized Charging switch follow in the tile body.
    @ViewBuilder private var actions: some View {
        Divider()
        HStack {
            if model.isDemo {
                // The simulation's own one-shot (acts on the simulation only).
                Button(L10n.text(model.isFullChargeOnceRequested ? "Cancel one-time charge" : "Charge to 100% once")) {
                    model.toggleSimulatedFullChargeOnce()
                }
                .controlSize(.large).disabled(model.isApplying)
            } else if ChargeLimitKit.showsChargeOnce(model) {
                ChargeOncePill(model: model, fillsWidth: false)
            }
            Spacer(minLength: 0)
        }
    }

    /// The native status line (an unconfirmed change or policy); the notice strip under the lead carries the page-wide
    /// notices.
    @ViewBuilder private func statusLine(_ state: NativeChargePresentation) -> some View {
        if !model.isDemo, let status = NativeChargeStatusText.shown(state, model: model) {
            Text(L10n.text(status)).font(.callout)
                .foregroundStyle(NativeChargeStatusText.isWarning(state) ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No native control or monitoring only: the macOS limit as a read-only row.
    private var readOnly: some View {
        let native = model.nativeCharge.nativeSetting.flatMap { $0.isFresh ? $0.configuration : nil }
        // The registry rows are evidence only on AC (on battery macOS keeps listing old rows for minutes).
        let system = model.systemChargeLimit?.evidentManualLimit()
        let text = ChargingComposition.macOSLimitText(native: model.isDemo ? nil : native, systemManual: system)
        return HStack(spacing: 5) {
            Text(L10n.text("macOS charge limit")).font(.headline)
            SectionInfoButton(title: L10n.text("macOS charge limit"),
                              paragraphs: [L10n.text("Read from macOS; change it in System Settings › Battery.")], id: "charge-limit-readonly-info")
            Spacer(minLength: 8)
            Text(text).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .foregroundStyle(text == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Reading strip

@MainActor private struct ChargingReadingStrip: View {
    var model: TilveroModel

    var body: some View {
        LiveRefresh(store: model.live) {
            let adapterAbsent = model.snapshot.isExternalPower.value == false
            ReadingStrip(items: [
                ReadingStripItem(id: "054", title: L10n.text("Input"),
                                 display: adapterAbsent ? .unavailable : live("054"),
                                 tint: WindowTheme.inputPower, reading: chargingReading(model, "054")),
                ReadingStripItem(id: "038", title: L10n.text("Battery (short)"),
                                 display: liveBattery(), tint: WindowTheme.batteryPower, reading: chargingReading(model, "038")),
                ReadingStripItem(id: "050", title: L10n.text("Adapter rating"),
                                 display: adapterAbsent ? .unavailable
                                    : ReadingDisplay.make(chargingReading(model, "050"), fahrenheit: false, fractionDigits: 0...0),
                                 reading: chargingReading(model, "050")),
            ]) { item in
                if let reading = item.reading, item.display.number != nil { ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit) }
            }
        }
    }

    /// The newest live SMC point (about 1 Hz while the chart is on screen) when it is newer than the snapshot and the
    /// snapshot reading itself is usable (same rule as the Overview strip); otherwise the snapshot's own reading.
    private func liveReading(_ id: String) -> CatalogReading? {
        let base = chargingReading(model, id)
        guard let base, ReadingDisplay.make(base, fahrenheit: false).number != nil, model.wantsLiveCharts,
              let point = model.live.tail.points(id: id).last,
              point.date > base.collectedAt, Date().timeIntervalSince(point.date) < 5 else { return base }
        return CatalogReading(definition: base.definition, value: .decimal(point.value), unit: base.unit,
                              source: "SMC", collectedAt: point.date, provenance: .measured,
                              availability: .available, freshness: .fresh)
    }
    private func live(_ id: String) -> ReadingDisplay { ReadingDisplay.make(liveReading(id), fahrenheit: false) }
    private func liveBattery() -> ReadingDisplay { ChargingComposition.signedBattery(liveReading("038")) }
}

// MARK: Power chart (last hour, live)

@MainActor private struct ChargingPowerChartTile: View {
    var model: TilveroModel

    var body: some View {
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text("Power, W"), detail: L10n.text("hour (chart)")) {
                    HStack(spacing: 10) {
                        if model.snapshot.adapterIsConnected {
                            ChartLegendItem(title: L10n.text("input (legend)"), color: WindowTheme.inputPower)
                        }
                        ChartLegendItem(title: L10n.text("battery (legend)"), color: WindowTheme.batteryPower)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                // The window's live surface: the sampler runs only while this chart is on screen in a visible window.
                LiveRefresh(store: model.live) { chart }
                    .liveCharts(model, surface: .windowOverview)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        let window = model.overviewChartWindow
        // No adapter: the input line is dropped, the battery line stays.
        let adapter = model.snapshot.adapterIsConnected ? model.metricSeries(id: "054") : nil
        let battery = model.metricSeries(id: "038")
        let stale = battery.state == .staleTail
        if battery.points.isEmpty && (adapter?.points.isEmpty ?? true) {
            EmptyFrame(symbol: "waveform.path.ecg", title: L10n.text("No measurements (chart)"),
                       detail: model.isDemo ? L10n.text("Simulation is never stored in history") : L10n.text("They appear within seconds"),
                       loading: model.historyLoading)
        } else {
            let input = adapter?.points ?? []
            WindowLineChart(
                series: [WindowChartSeries(id: "054", points: input, color: stale ? .gray : WindowTheme.inputPower),
                         WindowChartSeries(id: "038", points: battery.points, color: stale ? .gray.opacity(0.6) : WindowTheme.batteryPower)],
                window: window,
                yDomain: HistorySeries.yDomain((input + battery.points).map(\.value)),
                xLabels: WindowChartLabels.labels(window: window, range: .hour))
                .frame(height: 120)
                .accessibilityLabel(L10n.text("Power, W"))
        }
    }
}

// MARK: Adapter rows

@MainActor private struct ChargingAdapterSection: View {
    var model: TilveroModel
    @State private var expanded = false

    var body: some View {
        let catalog = model.snapshot.catalog
        let readings = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let connected = model.snapshot.isExternalPower.value
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            BatterySectionHeading(title: L10n.text("Adapter"))
            BatteryRowsTile(rows: ChargingComposition.adapterRows(catalog, connected: connected), readings: readings)
            if connected != false {
                // Heading-styled disclosure: the tile keeps the page's full width (a DisclosureGroup would indent it).
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                        Text(L10n.text("More")).font(.headline)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(L10n.text(expanded ? "Expanded" : "Collapsed"))
                .accessibilityIdentifier("charging-adapter-more")
                if expanded {
                    BatteryRowsTile(rows: ChargingComposition.moreRows(catalog), readings: readings)
                }
            }
        }
    }
}

// MARK: System rows

@MainActor private struct ChargingSystemSection: View {
    var model: TilveroModel

    var body: some View {
        let optimized: Bool? = model.isDemo ? nil : model.optimizedChargingEnabled
        let optimizedText = ChargingComposition.onOff(optimized)
        // With its own switch row on this page, Optimized charging is not repeated here as a read-only line.
        let switchShown = ChargeLimitKit.showsOptimizedSwitch(isDemo: model.isDemo, optimizedAvailable: model.optimizedCharging.isAvailable)
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            BatterySectionHeading(title: L10n.text("System"))
            WindowRowsTile(rows: (switchShown ? [] : [
                WindowRow(id: "optimized", label: L10n.text("Optimized charging"), value: optimizedText, dim: optimizedText == "—")]) + [
                // Read-only: Low Power Mode is a macOS setting.
                WindowRow(id: "lowPower", label: L10n.text("Low Power Mode"), value: ChargingComposition.onOff(model.isLowPowerModeEnabled)),
                WindowRow(id: "settings", label: L10n.text("macOS Settings…"), value: "", action: { model.openBatterySettings() }),
            ])
        }
    }
}
