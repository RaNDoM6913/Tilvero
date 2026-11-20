// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// How this Mac is cooled, as far as the app knows it. A fan count is never claimed: a fan Mac is one whose fans were
/// discovered; a Mac that is neither the known fanless model nor has discovered fans is "system cooling".
enum CoolingKind: Equatable, Sendable {
    case fanless, fans, system

    static func resolve(fanless: Bool, discoveredFans: Int) -> CoolingKind {
        if fanless { return .fanless }
        return discoveredFans > 0 ? .fans : .system
    }

    /// Lead detail; the word «аккумулятор» says the value is the battery's, not the CPU's.
    var detailKey: String {
        switch self {
        case .fanless: "battery · fanless cooling"
        case .fans: "battery · fans"
        case .system: "battery · system cooling"
        }
    }
}

/// Cooling page of the main window (direction C, IA §3.4): lead with the battery temperature and the thermal state,
/// one reading strip, the live hour chart of the battery temperature, fan rows when fans were discovered, other sensors
/// when reported. No toolbar. Every missing number is «—».
@MainActor struct CoolingPage: View {
    var model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("CoolingPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                CoolingLeadView(model: model)
                CoolingReadingStrip(model: model)
                CoolingTemperatureChartTile(model: model)
                CoolingFanSection(model: model)
                CoolingOtherSensors(model: model)
                if CoolingPage.showsFanControls(fanless: model.fanless, isDemo: model.isDemo, canControlFans: model.canControlFans,
                                                discoveredFans: model.fanDescriptors.count) {
                    WindowTile { FanControlPanel(model: model) }
                }
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.cooling).title)
    }

    // MARK: Pure composition (tested)

    /// The old fan control panel appeared on a non-fanless Mac in DEMO or with discovered fans; IA §3.4 narrows it to
    /// DEMO or a Mac whose fans may be controlled (`canControlFans`, never in a release today).
    static func showsFanControls(fanless: Bool, isDemo: Bool, canControlFans: Bool, discoveredFans: Int) -> Bool {
        guard !fanless else { return false }
        return isDemo || (canControlFans && discoveredFans > 0)
    }

    /// Lead: battery temperature, thermal state as the status, cooling kind as the detail.
    static func lead(temperature: ReadingDisplay, thermalRaw: String?, thermalText: String?, kind: CoolingKind,
                     lastRead: Date?, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        let detail = L10n.text(kind.detailKey)
        guard temperature.number != nil else {
            return LeadDisplay(value: "—", status: L10n.text("No data"), tone: .secondary, detail: detail)
        }
        if temperature.state == .stale {
            let time = lastRead.map { $0.formatted(.dateTime.hour().minute().locale(locale)) }
            return LeadDisplay(value: temperature.text, status: L10n.text("Stale"), tone: .attention,
                               detail: time.map { (language == "ru" ? "последнее чтение " : "last read ") + $0 } ?? detail,
                               stale: true)
        }
        let tone: LeadDisplay.Tone
        switch thermalRaw {
        case "nominal": tone = .accent
        case "fair", "serious", "critical": tone = .attention
        default: tone = .secondary
        }
        return LeadDisplay(value: temperature.text, status: thermalText ?? "", tone: tone, detail: detail)
    }

    /// «Ячейки» (040): per-cell temperatures in the chosen unit, «—» when not reported.
    static func cellsDisplay(_ reading: CatalogReading?, fahrenheit: Bool, locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let reading, reading.availability == .available || reading.freshness == .stale,
              let value = reading.value else { return .unavailable }
        let state: ReadingDisplay.State = reading.freshness == .stale ? .stale : reading.freshness == .unknown ? .freshnessUnknown : .live
        let numbers: [Double]
        switch value {
        case .list(let items): numbers = items.compactMap(\.doubleValue)
        case .object(let items): numbers = items.keys.sorted().compactMap { items[$0]?.doubleValue }
        default: numbers = value.doubleValue.map { [$0] } ?? []
        }
        let finite = numbers.filter(\.isFinite)
        guard !finite.isEmpty else { return .unavailable }
        let converted = fahrenheit ? finite.map { $0 * 9 / 5 + 32 } : finite
        let text = converted.map { $0.formatted(.number.locale(locale).precision(.fractionLength(1))) }.joined(separator: " / ")
        return ReadingDisplay(number: text, unit: fahrenheit ? "°F" : "°C",
                              approximate: [.estimated, .inferred].contains(reading.provenance), state: state, masked: false)
    }

    /// One row per discovered fan (observed speed or «—»), then who controls the fans.
    static func fanRows(descriptors: [FanDescriptor], rpm: [String: Int], phase: FanPhase,
                        language: String = L10n.language, locale: Locale = L10n.locale) -> [WindowRow] {
        guard !descriptors.isEmpty else { return [] }
        let unit = CatalogDataPresentation.unit("RPM", language: language)
        var rows = descriptors.enumerated().map { index, fan in
            let value = rpm[fan.id].map { $0.formatted(.number.locale(locale)) + " " + unit }
            return WindowRow(id: "fan." + fan.id, label: L10n.text("Fan") + " \(index + 1)", value: value ?? "—", dim: value == nil)
        }
        rows.append(WindowRow(id: "fan.control", label: L10n.text("Control (fans)"), value: controlText(phase)))
        return rows
    }

    static func controlText(_ phase: FanPhase) -> String {
        switch phase {
        case .systemAuto: L10n.text("macOS (auto)")
        case .recoveryRequired: L10n.text("Recovery required")
        case .acquiring, .managed, .releasing: "Tilvero"
        }
    }

    /// «Другие датчики» (094): one row per named sensor; nothing when the reading is absent or unavailable.
    static func otherSensorRows(_ reading: CatalogReading?, fahrenheit: Bool, locale: Locale = L10n.locale) -> [WindowRow] {
        guard let reading, reading.availability == .available || reading.freshness == .stale,
              let value = reading.value else { return [] }
        func temperature(_ value: CatalogValue) -> String {
            guard let celsius = value.doubleValue, celsius.isFinite else { return value.displayText }
            let shown = fahrenheit ? celsius * 9 / 5 + 32 : celsius
            return shown.formatted(.number.locale(locale).precision(.fractionLength(1))) + (fahrenheit ? " °F" : " °C")
        }
        switch value {
        case .object(let sensors):
            return sensors.keys.sorted().map { WindowRow(id: "sensor." + $0, label: $0, value: temperature(sensors[$0]!)) }
        case .list(let items):
            return items.enumerated().map { WindowRow(id: "sensor.\($0.offset)", label: "\($0.offset + 1)", value: temperature($0.element)) }
        default:
            let title = L10n.language == "ru" ? reading.definition.titleRussian : reading.definition.titleEnglish
            return [WindowRow(id: "sensor", label: title, value: CatalogDataPresentation.value(reading, reveal: false, fahrenheit: fahrenheit))]
        }
    }

    /// Y scale fitted around the data (not from zero), whole numbers, at least 3 degrees tall.
    static func temperatureDomain(_ values: [Double]) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return (30...35, [30, 32, 34]) }
        var lower = low.rounded(.down), upper = high.rounded(.up)
        if upper - lower < 3 {
            let middle = (low + high) / 2
            lower = (middle - 1.5).rounded(.down); upper = (middle + 1.5).rounded(.up)
        }
        let span = upper - lower
        let step: Double = span <= 3 ? 1 : span <= 8 ? 2 : span <= 20 ? 5 : 10
        lower = (lower / step).rounded(.down) * step
        upper = (upper / step).rounded(.up) * step
        return (lower...upper, Array(stride(from: lower, through: upper, by: step)))
    }
}

// MARK: Readings

/// The snapshot reading, replaced by the newest live point (about 1 Hz while the hour chart is on screen) when newer.
@MainActor private func coolingReading(_ model: TilveroModel, _ id: String, live: Bool) -> CatalogReading? {
    guard let base = model.snapshot.catalog.first(where: { $0.id == id }) else { return nil }
    guard live, model.wantsLiveCharts, let point = model.live.tail.points(id: id).last,
          point.date > base.collectedAt, Date().timeIntervalSince(point.date) < 5 else { return base }
    return CatalogReading(definition: base.definition, value: .decimal(point.value), unit: base.unit,
                          source: base.source, keyPath: base.keyPath, collectedAt: point.date,
                          provenance: base.provenance, availability: .available, freshness: .fresh)
}

// MARK: Lead

@MainActor private struct CoolingLeadView: View {
    var model: TilveroModel
    var body: some View {
        LiveRefresh(store: model.live) {
            let temperature = coolingReading(model, "039", live: true)
            let thermal = coolingReading(model, "044", live: false)
            let thermalUsable = thermal.map { $0.availability == .available || $0.freshness == .stale } ?? false
            let thermalText = thermalUsable ? thermal.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: false) } : nil
            let lead = CoolingPage.lead(
                temperature: ReadingDisplay.make(temperature, fahrenheit: model.fahrenheit),
                thermalRaw: thermalUsable ? thermal?.value?.stringValue : nil,
                thermalText: thermalText == "—" ? nil : thermalText,
                kind: CoolingKind.resolve(fanless: model.fanless, discoveredFans: model.fanDescriptors.count),
                lastRead: temperature.map { $0.sourceSampleAt ?? $0.collectedAt })
            LeadLine(lead: lead) {
                if let temperature { ReadingInfoButton(reading: temperature, fahrenheit: model.fahrenheit) }
            }
        }
    }
}

// MARK: Reading strip

@MainActor private struct CoolingReadingStrip: View {
    var model: TilveroModel
    var body: some View {
        LiveRefresh(store: model.live) {
            let fahrenheit = model.fahrenheit
            let battery = coolingReading(model, "039", live: true)
            let thermal = coolingReading(model, "044", live: false)
            let cells = coolingReading(model, "040", live: false)
            ReadingStrip(items: [
                ReadingStripItem(id: "039", title: L10n.text("Battery"),
                                 display: ReadingDisplay.make(battery, fahrenheit: fahrenheit), reading: battery),
                ReadingStripItem(id: "044", title: L10n.text("Thermal state"),
                                 display: ReadingDisplay.make(thermal, fahrenheit: fahrenheit), reading: thermal),
                ReadingStripItem(id: "040", title: L10n.text("Cells"),
                                 display: CoolingPage.cellsDisplay(cells, fahrenheit: fahrenheit), reading: cells),
            ]) { item in
                if let reading = item.reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            }
        }
    }
}

// MARK: Temperature chart (last hour, live)

@MainActor private struct CoolingTemperatureChartTile: View {
    var model: TilveroModel
    var body: some View {
        WindowTile {
            VStack(alignment: .leading, spacing: 10) {
                TileHeading(title: L10n.text(model.fahrenheit ? "Battery temperature, °F" : "Battery temperature, °C"),
                            detail: L10n.text("hour (chart)")) { EmptyView() }
                if model.isDemo {
                    EmptyFrame(symbol: "thermometer.medium", title: L10n.text("No measurements (chart)"),
                               detail: L10n.text("Simulation is never stored in history"))
                } else {
                    LiveRefresh(store: model.live) { chart }
                        .liveCharts(model, surface: .windowOverview)
                }
            }
        }
    }

    @ViewBuilder private var chart: some View {
        let window = model.overviewChartWindow
        let series = model.metricSeries(id: "039")
        let fahrenheit = model.fahrenheit
        let points = fahrenheit
            ? series.points.map { HistoryChartPoint(id: $0.id, date: $0.date, value: $0.value * 9 / 5 + 32, series: $0.series) }
            : series.points
        if points.isEmpty {
            EmptyFrame(symbol: "thermometer.medium", title: L10n.text("No measurements (chart)"),
                       detail: L10n.text("They appear within seconds"), loading: model.historyLoading)
        } else {
            let scale = CoolingPage.temperatureDomain(points.map(\.value))
            WindowLineChart(
                series: [WindowChartSeries(id: "039", points: points,
                                           color: series.state == .staleTail ? .gray : WindowTheme.temperature)],
                window: window, yDomain: scale.domain, yValues: scale.ticks,
                xLabels: WindowChartLabels.labels(window: window, range: .hour))
                .frame(height: 110)
                .accessibilityLabel(L10n.text("Battery temperature"))
        }
    }
}

// MARK: Fans (only when fans were discovered)

@MainActor private struct CoolingFanSection: View {
    var model: TilveroModel
    var body: some View {
        let descriptors = model.fanless ? [] : model.fanDescriptors
        if !descriptors.isEmpty {
            let phase = model.fanPhase
            CoolingSectionHeading(title: L10n.text("Fans"),
                                  reading: model.snapshot.catalog.first { $0.id == "087" },
                                  trailing: phase == .systemAuto ? L10n.text("Auto · macOS") : nil,
                                  fahrenheit: model.fahrenheit)
            WindowRowsTile(rows: CoolingPage.fanRows(descriptors: descriptors, rpm: model.fanRPM, phase: phase))
        }
    }
}

// MARK: Other sensors (094, only when reported)

@MainActor private struct CoolingOtherSensors: View {
    var model: TilveroModel
    var body: some View {
        let reading = model.snapshot.catalog.first { $0.id == "094" }
        let rows = CoolingPage.otherSensorRows(reading, fahrenheit: model.fahrenheit)
        if !rows.isEmpty {
            CoolingSectionHeading(title: L10n.text("Other sensors"), reading: reading, trailing: nil, fahrenheit: model.fahrenheit)
            WindowRowsTile(rows: rows)
        }
    }
}

/// Heading above a rows tile: title, (i), trailing word.
@MainActor private struct CoolingSectionHeading: View {
    let title: String
    let reading: CatalogReading?
    let trailing: String?
    let fahrenheit: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let reading { ReadingInfoButton(reading: reading, fahrenheit: fahrenheit) }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }
}
