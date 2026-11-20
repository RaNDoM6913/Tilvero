// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore
import PowerPersistence

/// Range of the History chart (toolbar picker). Both ranges are recorded history.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day, week
    var id: String { rawValue }
    var titleKey: String { self == .day ? "24 hours" : "7 days" }
    var seconds: TimeInterval { self == .day ? 86_400 : 604_800 }
    /// The Overview range whose chart labels this range shares.
    var labelRange: OverviewRange { self == .day ? .day : .week }
}

/// Measurements offered by the toolbar menu (the recorded scalar fields every stored sample keeps).
enum HistoryMeasurement: String, CaseIterable, Identifiable, Sendable {
    case charge, temperature, power
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .charge: "Charge"
        case .temperature: "Temperature"
        case .power: "Power"
        }
    }
    var series: HistorySeries.Measurement {
        switch self {
        case .charge: .charge
        case .temperature: .temperature
        case .power: .batteryPower
        }
    }
}

/// The chosen measurement inside the chosen range, built off the main actor from recorded samples only. Statistics
/// come from every recorded point of the range (before the min/max reduction for drawing).
struct HistoryPageSeries: Sendable {
    var points: [HistoryChartPoint] = []
    var window: ClosedRange<Date> = Date.distantPast...Date.distantPast
    var minimum: Double?
    var maximum: Double?
    var count = 0
    var measurement: HistoryMeasurement = .charge
    var range: HistoryRange = .day
    /// False until the first build finished (the frame shows a spinner, never an "empty" claim).
    var isBuilt: Bool { window.lowerBound != .distantPast }

    static func build(_ samples: [HistorySample], measurement: HistoryMeasurement, range: HistoryRange,
                      fahrenheit: Bool, now: Date) -> HistoryPageSeries {
        let window = now.addingTimeInterval(-range.seconds)...now
        var points = HistorySeries.points(samples, measurement: measurement.series, window: window)
        if measurement == .temperature, fahrenheit {
            points = points.map { HistoryChartPoint(id: $0.id, date: $0.date, value: $0.value * 9 / 5 + 32, series: $0.series) }
        }
        let values = points.map(\.value)
        return HistoryPageSeries(points: HistorySeries.downsample(points, window: window), window: window,
                                 minimum: values.min(), maximum: values.max(), count: values.count,
                                 measurement: measurement, range: range)
    }
}

/// Pure text composition of the History page (testable without a view tree).
enum HistoryPageText {
    /// «72 %», «32,4 °C», «−6,1 Вт»; nil value is «—».
    static func value(_ value: Double?, measurement: HistoryMeasurement, fahrenheit: Bool,
                      language: String = L10n.language, locale: Locale = L10n.locale) -> String {
        guard let value, value.isFinite else { return "—" }
        let ru = language == "ru"
        switch measurement {
        case .charge:
            let level = Int(value.rounded())
            return ru ? "\(level) %" : "\(level)%"
        case .temperature:
            return number(value, digits: 1, locale: locale) + (fahrenheit ? " °F" : " °C")
        case .power:
            return number(value, digits: 1, locale: locale) + (ru ? " Вт" : " W")
        }
    }

    /// One decimal with the locale's separator, a true minus sign, never «-0».
    static func number(_ value: Double, digits: Int, locale: Locale) -> String {
        var value = value
        if value == 0 || abs(value) < 0.5 * pow(10, -Double(digits)) { value = 0 }
        let text = abs(value).formatted(.number.locale(locale).precision(.fractionLength(digits)).grouping(.automatic))
        return value < 0 ? "−" + text : text
    }

    /// «1 440 измерений» / "1,440 samples" with Russian plural forms.
    static func samples(_ count: Int, language: String = L10n.language, locale: Locale = L10n.locale) -> String {
        let digits = count.formatted(.number.locale(locale))
        guard language == "ru" else { return digits + (count == 1 ? " sample" : " samples") }
        let tens = count % 100, ones = count % 10
        let word = (11...14).contains(tens) ? "измерений" : ones == 1 ? "измерение" : (2...4).contains(ones) ? "измерения" : "измерений"
        return digits + " " + word
    }

    /// Lead of the page. Current value from the snapshot; detail = range statistics of the recorded series.
    struct LeadInputs: Equatable, Sendable {
        var current: Double?
        var currentStale = false
        var recording = true
        var demo = false
        var minimum: Double?
        var maximum: Double?
        var count = 0
    }

    static func lead(_ input: LeadInputs, measurement: HistoryMeasurement, fahrenheit: Bool,
                     language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        let ru = language == "ru"
        if !input.recording && !input.demo {
            return LeadDisplay(value: "—", status: L10n.text("Recording is off"), tone: .secondary,
                               detail: L10n.text("Turn on in Settings › History"))
        }
        let value = Self.value(input.current, measurement: measurement, fahrenheit: fahrenheit, language: language, locale: locale)
        var fragments: [String] = []
        if !input.demo, input.count > 0, let low = input.minimum, let high = input.maximum {
            fragments.append((ru ? "мин " : "min ") + Self.value(low, measurement: measurement, fahrenheit: fahrenheit, language: language, locale: locale))
            fragments.append((ru ? "макс " : "max ") + Self.value(high, measurement: measurement, fahrenheit: fahrenheit, language: language, locale: locale))
            fragments.append(samples(input.count, language: language, locale: locale))
        }
        guard input.current != nil else {
            return LeadDisplay(value: "—", status: L10n.text("No data"), tone: .secondary, detail: fragments.joined(separator: " · "))
        }
        if input.currentStale {
            return LeadDisplay(value: value, status: L10n.text("Stale"), tone: .attention,
                               detail: fragments.joined(separator: " · "), stale: true)
        }
        return LeadDisplay(value: value, status: L10n.text("Now"), tone: .secondary, detail: fragments.joined(separator: " · "))
    }

    /// «≈ +412 Вт·ч» / «≈ −398 Вт·ч»; nil (no qualified interval) is «—», never a measured zero.
    static func energy(_ wattHours: Double?, sign: FloatingPointSign, language: String = L10n.language,
                       locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let wattHours, wattHours.isFinite else { return .unavailable }
        let magnitude = abs(wattHours)
        let digits = magnitude >= 100 ? 0 : 1
        let text = magnitude.formatted(.number.locale(locale).precision(.fractionLength(digits)))
        let signed = magnitude == 0 ? text : (sign == .plus ? "+" : "−") + text
        return ReadingDisplay(number: signed, unit: CatalogDataPresentation.unit("Wh", language: language),
                              approximate: true, state: .live, masked: false)
    }

    static func count(_ value: Int?, locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let value else { return .unavailable }
        return ReadingDisplay(number: value.formatted(.number.locale(locale)), unit: "", approximate: false, state: .live, masked: false)
    }

    /// «с 4 ноября» / "since Nov 4".
    static func since(_ date: Date?, language: String = L10n.language, locale: Locale = L10n.locale) -> String? {
        guard let date else { return nil }
        let day = date.formatted(.dateTime.day().month(.wide).locale(locale))
        return (language == "ru" ? "с " : "since ") + day
    }

    struct SessionRow: Equatable, Sendable {
        let id: UUID
        let label: String
        let value: String
    }

    /// The last five recorded charging sessions, newest first: «Сегодня 12:10 – сейчас», duration. Only times the
    /// store recorded; a session whose real start predates monitoring says «≥» before its duration.
    static func sessionRows(_ sessions: [HistorySession], now: Date, language: String = L10n.language,
                            locale: Locale = L10n.locale, calendar: Calendar = .current) -> [SessionRow] {
        let ru = language == "ru"
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        func day(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return ru ? "Сегодня" : "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
                return ru ? "Вчера" : "Yesterday"
            }
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        return sessions.filter { $0.kind == "charging" }.suffix(5).reversed().map { session in
            let start = day(session.observedFrom) + " " + session.observedFrom.formatted(time)
            let endText: String
            if let end = session.endedAt {
                endText = calendar.isDate(end, inSameDayAs: session.observedFrom)
                    ? end.formatted(time) : day(end) + " " + end.formatted(time)
            } else {
                endText = ru ? "сейчас" : "now"
            }
            let seconds = max(0, (session.endedAt ?? now).timeIntervalSince(session.observedFrom))
            let duration = WindowDuration.text(minutes: Int((seconds / 60).rounded()), language: language)
            return SessionRow(id: session.id, label: start + " – " + endText,
                              value: (session.originalStartKnown ? "" : "≥ ") + duration)
        }
    }

    /// Catalog ids of the readings the history store derives (072–074, 077–086).
    static let recordedReadingIDs: Set<String> = ["072", "073", "074", "077", "078", "079", "080", "081", "082", "083",
                                                  "084", "085", "086"]
}

/// History page of the main window (direction C): lead for the chosen measurement, chart of the recorded range,
/// all-history totals, recorded charging sessions, recorded readings. Export goes through the existing preview sheet.
@MainActor struct HistoryPage: View {
    var model: TilveroModel
    @State private var range: HistoryRange = .day
    @State private var measurement: HistoryMeasurement = .charge
    @State private var series = HistoryPageSeries()

    var body: some View {
        let _ = RenderProbe.hit("HistoryPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                HistoryLeadView(model: model, measurement: measurement, series: series)
                WindowNoticeView(model: model)
                HistoryChartTile(model: model, series: series, measurement: measurement)
                if !model.isDemo {
                    HistoryTotals(model: model)
                    HistorySessions(model: model)
                    HistoryRecordedReadings(model: model)
                }
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.history).title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L10n.text("Range"), selection: $range) {
                    ForEach(HistoryRange.allCases) { Text(L10n.text($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityIdentifier("history-range")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker(L10n.text("Measurement"), selection: $measurement) {
                    ForEach(HistoryMeasurement.allCases) { Text(L10n.text($0.titleKey)).tag($0) }
                }
                .pickerStyle(.menu).fixedSize().labelsHidden()
                .accessibilityIdentifier("history-measurement")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("JSON…") { model.prepareExport() }
                    Button("CSV…") { model.prepareExport(csv: true) }
                } label: {
                    Label(L10n.text("Export"), systemImage: "square.and.arrow.up")
                }
                .disabled(model.isDemo)
                .help(L10n.text("Export"))
                .accessibilityIdentifier("history-export")
            }
        }
        .task(id: SeriesKey(range: range, measurement: measurement, fahrenheit: model.fahrenheit,
                            count: model.history.count, last: model.history.last?.id)) {
            let samples = model.history, range = range, measurement = measurement, fahrenheit = model.fahrenheit, now = Date()
            let built = await Task.detached(priority: .userInitiated) {
                HistoryPageSeries.build(samples, measurement: measurement, range: range, fahrenheit: fahrenheit, now: now)
            }.value
            guard !Task.isCancelled else { return }
            series = built
        }
        .sheet(isPresented: Binding(get: { model.exportPreview != nil }, set: { if !$0 { model.exportPreview = nil } })) {
            HistoryExportSheet(model: model)
        }
    }
}

private struct SeriesKey: Hashable {
    let range: HistoryRange
    let measurement: HistoryMeasurement
    let fahrenheit: Bool
    let count: Int
    let last: UUID?
}

// MARK: Lead

@MainActor private struct HistoryLeadView: View {
    var model: TilveroModel
    let measurement: HistoryMeasurement
    let series: HistoryPageSeries
    private func reading(_ id: String) -> CatalogReading? { model.snapshot.catalog.first { $0.id == id } }

    var body: some View {
        var input = HistoryPageText.LeadInputs(recording: model.historyEnabled, demo: model.isDemo)
        if series.measurement == measurement {
            input.minimum = series.minimum; input.maximum = series.maximum; input.count = series.count
        }
        switch measurement {
        case .charge:
            let level = model.snapshot.chargePercent
            if level.availability == .available || level.freshness == .stale,
               let value = ReadingPresentation.validLevel(level.value) {
                input.current = Double(value); input.currentStale = level.freshness == .stale
            }
        case .temperature, .power:
            let id = measurement == .temperature ? "039" : "038"
            if let reading = reading(id), reading.availability == .available || reading.freshness == .stale,
               var value = reading.value?.doubleValue, value.isFinite {
                if measurement == .temperature, model.fahrenheit { value = value * 9 / 5 + 32 }
                input.current = value; input.currentStale = reading.freshness == .stale
            }
        }
        let lead = HistoryPageText.lead(input, measurement: measurement, fahrenheit: model.fahrenheit)
        return LeadLine(lead: lead) {
            if !model.historyEnabled && !model.isDemo {
                Button(L10n.text("Open Settings")) { model.navigation.navigate(to: .settings(.history)) }
                    .controlSize(.small)
                    .accessibilityIdentifier("history-open-settings")
            } else if let reading = reading(measurement == .charge ? "011" : measurement == .temperature ? "039" : "038") {
                ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit)
            }
        }
    }
}

// MARK: Chart

@MainActor private struct HistoryChartTile: View {
    var model: TilveroModel
    let series: HistoryPageSeries
    let measurement: HistoryMeasurement
    private let height: CGFloat = 200

    var body: some View {
        WindowTile {
            if model.isDemo {
                EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                           detail: L10n.text("Simulation is never stored in history"), height: height)
            } else if series.measurement != measurement || series.points.isEmpty {
                if model.historyLoading || series.measurement != measurement || !series.isBuilt {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: "", loading: true, height: height)
                } else if !model.historyEnabled {
                    EmptyFrame(symbol: "pause.circle", title: L10n.text("History is not recorded"),
                               detail: L10n.text("Saved measurements stay"), height: height)
                } else {
                    EmptyFrame(symbol: "chart.xyaxis.line", title: L10n.text("No recorded measurements yet"),
                               detail: L10n.text("History starts recording now"), height: height)
                }
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        let color: Color = switch measurement {
        case .charge: WindowTheme.accent
        case .temperature: WindowTheme.temperature
        case .power: WindowTheme.batteryPower
        }
        let values = series.points.map(\.value)
        let domain: ClosedRange<Double> = switch measurement {
        case .charge: 0...100
        case .temperature: HistorySeries.yDomain(values, minimumTop: model.fahrenheit ? 120 : 50)
        case .power: HistorySeries.yDomain(values)
        }
        return WindowLineChart(
            series: [WindowChartSeries(id: measurement.rawValue, points: series.points, color: color)],
            window: series.window, yDomain: domain,
            yValues: measurement == .charge ? [0, 25, 50, 75, 100] : nil,
            xLabels: WindowChartLabels.labels(window: series.window, range: series.range.labelRange))
            .frame(height: height)
            .accessibilityLabel(L10n.text(measurement.titleKey))
    }
}

// MARK: All recorded history

@MainActor private struct HistoryTotals: View {
    var model: TilveroModel
    var body: some View {
        let summary = model.historySummary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(L10n.text("All recorded history (heading)")).font(.system(size: 13, weight: .semibold))
                SectionInfoButton(title: L10n.text("All recorded history (heading)"),
                                  paragraphs: [L10n.text("Totals cover everything Tilvero has recorded, not only the chosen range. Energy is estimated from recorded power.")],
                                  id: "history-totals-info")
                Spacer(minLength: 8)
                if let since = HistoryPageText.since(summary?.monitoringStart) {
                    Text(since).foregroundStyle(.secondary)
                }
            }
            ReadingStrip(items: [
                ReadingStripItem(id: "sessions", title: L10n.text("Charging sessions"),
                                 display: HistoryPageText.count(summary?.chargingSessionCount)),
                ReadingStripItem(id: "gaps", title: L10n.text("Gaps (history)"),
                                 display: HistoryPageText.count(summary?.gaps.count)),
                ReadingStripItem(id: "charged", title: L10n.text("Charged (history)"),
                                 display: HistoryPageText.energy(summary?.estimatedChargedWh, sign: .plus)),
                ReadingStripItem(id: "used", title: L10n.text("Used (history)"),
                                 display: HistoryPageText.energy(summary?.estimatedDischargedWh, sign: .minus)),
            ]) { item in
                if item.id == "gaps" {
                    SectionInfoButton(title: L10n.text("Gaps (history)"),
                                      paragraphs: [L10n.text("History starts with observations made by Tilvero. Sleep and missing readings remain gaps.")],
                                      id: "history-gaps-info")
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: Sessions

@MainActor private struct HistorySessions: View {
    var model: TilveroModel
    var body: some View {
        let rows = HistoryPageText.sessionRows(model.historySummary?.sessions ?? [], now: Date())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TileHeading(title: L10n.text("Sessions (history)")) { EmptyView() }
                WindowRowsTile(rows: rows.map { WindowRow(id: $0.id.uuidString, label: $0.label, value: $0.value) })
            }
            .padding(.top, 6)
        }
    }
}

// MARK: Recorded readings (072–086)

@MainActor private struct HistoryRecordedReadings: View {
    var model: TilveroModel
    @State private var expanded = false
    var body: some View {
        let readings = model.snapshot.catalog.filter { HistoryPageText.recordedReadingIDs.contains($0.id) }
        if !readings.isEmpty {
            WindowTile {
                DisclosureGroup(isExpanded: $expanded) {
                    CatalogReadingTable(readings: readings, fahrenheit: model.fahrenheit).padding(.top, 6)
                } label: {
                    Text(L10n.text("Recorded readings")).font(.system(size: 13, weight: .semibold))
                }
            }
        }
    }
}

// MARK: Export preview

@MainActor private struct HistoryExportSheet: View {
    var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Export preview")).font(.title2)
            Text(L10n.text("Serials and private identifiers are excluded.")).foregroundStyle(.secondary)
            ScrollView {
                Text(model.exportPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L10n.text("Cancel")) { model.exportPreview = nil }
                Spacer()
                Button(L10n.text("Save…")) { model.saveExport() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 620, height: 470)
    }
}
