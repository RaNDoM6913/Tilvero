// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// Sub-page of Battery (toolbar picker «Сводка · Все данные»).
enum BatteryMode: String, CaseIterable, Identifiable, Sendable {
    case summary, catalog
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .summary: "Summary"
        case .catalog: "All data"
        }
    }
}

/// Battery page of the main window (direction C, IA §3.2): Summary (lead, one reading strip, rows «Сейчас», «Ячейки»,
/// «Аккумулятор», disclosure «За всё время») or All data (the raw-catalog browser). Reads only what it draws; every
/// missing number is «—».
@MainActor struct BatteryPage: View {
    var model: TilveroModel
    @State private var showUnavailable = true
    @State private var reveal = false
    /// Bound to the navigation, so Diagnostics can open All data directly.
    private var mode: BatteryMode { model.navigation.batteryMode }

    init(model: TilveroModel, mode: BatteryMode? = nil) {
        self.model = model
        if let mode { model.navigation.batteryMode = mode }
    }

    var body: some View {
        let _ = RenderProbe.hit("BatteryPage")
        Group {
            switch mode {
            case .summary: BatterySummaryPage(model: model, reveal: reveal)
            case .catalog: BatteryCatalogPage(model: model, showUnavailable: showUnavailable, reveal: reveal)
            }
        }
        .navigationTitle(WindowSection.entry(.battery).title)
        // Identifiers revealed in All data are hidden again on leaving it (Summary has no toggle to hide them).
        .onChange(of: mode) { _, _ in reveal = false }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L10n.text("Battery section"), selection: Binding(get: { model.navigation.batteryMode },
                                                                         set: { model.navigation.navigate(to: .battery($0)) })) {
                    ForEach(BatteryMode.allCases) { Text(L10n.text($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .accessibilityIdentifier("battery-mode")
            }
            if mode == .catalog {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle(L10n.text("Unavailable fields"), isOn: $showUnavailable)
                        Toggle(L10n.text("Reveal identifiers"), isOn: $reveal)
                    } label: {
                        Label(L10n.text("Filter"), systemImage: "line.3.horizontal.decrease")
                    }
                    .accessibilityIdentifier("battery-filter")
                }
            }
        }
    }
}

// MARK: Composition (pure, testable)

/// Inputs of the Battery lead, read from the snapshot and the weekly capacity by the page.
struct BatteryLeadInputs: Equatable, Sendable {
    /// Weekly median of capacity retention (history store), percent.
    var weeklyPercent: Double?
    /// Instantaneous capacity retention 026, percent (used when there is no weekly median yet).
    var retention: Double?
    var retentionStale = false
    /// macOS condition 023 in the app's words, and whether it is the healthy category.
    var condition: String?
    var conditionGood = false
    /// Cycle count 027.
    var cycles: Int64?
}

enum BatteryLead {
    /// The retention the page shows: the weekly median when there is one, otherwise the instantaneous 026.
    static func retention(_ input: BatteryLeadInputs) -> Double? {
        if let weekly = input.weeklyPercent, weekly.isFinite { return weekly }
        if let value = input.retention, value.isFinite { return value }
        return nil
    }

    static func make(_ input: BatteryLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        let retention = retention(input)
        let value = retention.map { "≈ " + $0.formatted(.number.locale(locale).precision(.fractionLength(0))) + " %" } ?? "—"
        var fragments: [String] = []
        if retention != nil { fragments.append(L10n.text("capacity retention (lead)")) }
        if let cycles = input.cycles, cycles >= 0 { fragments.append(cyclesText(cycles, language: language, locale: locale)) }
        let status: String, tone: LeadDisplay.Tone
        if let condition = input.condition {
            status = condition; tone = input.conditionGood ? .accent : .attention
        } else {
            status = L10n.text("No data"); tone = .secondary
        }
        let stale = input.weeklyPercent == nil && retention != nil && input.retentionStale
        return LeadDisplay(value: value, status: status, tone: tone, detail: fragments.joined(separator: " · "), stale: stale)
    }

    /// «146 циклов» / "146 cycles" with the catalog's plural keys.
    static func cyclesText(_ count: Int64, language: String = L10n.language, locale: Locale = L10n.locale) -> String {
        let key: String
        if language == "ru" {
            let tail = count % 100, last = count % 10
            key = (11...14).contains(tail) ? "cycles.many" : last == 1 ? "cycles.one" : (2...4).contains(last) ? "cycles.few" : "cycles.many"
        } else {
            key = count == 1 ? "cycles.one" : "cycles.many"
        }
        return count.formatted(.number.locale(locale)) + " " + L10n.text(key)
    }

    /// Wear as the existing health card derives it: 100 minus the shown retention, an estimate (≈).
    static func wear(retention: Double?, stale: Bool = false, locale: Locale = L10n.locale) -> ReadingDisplay {
        guard let retention, retention.isFinite else { return .unavailable }
        // A retention above 100 % (a new battery) is no wear, never a negative one.
        var wear = max(0, 100 - retention)
        if wear == 0 { wear = 0 }   // never «-0»
        return ReadingDisplay(number: wear.formatted(.number.locale(locale).precision(.fractionLength(1))), unit: "%",
                              approximate: true, state: stale ? .stale : .live, masked: false)
    }
}

/// One row of a Battery rows tile: label, value, optional (i) for the reading behind it.
struct BatteryReadingRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    var state: ReadingDisplay.State = .live
    var dim = false
    /// Catalog id of the reading the (i) explains; nil = no (i).
    var infoID: String?
}

enum BatteryRows {
    /// The row's title: an app key when given, otherwise the catalog title in the app's language.
    static func title(_ id: String, key: String? = nil, language: String = L10n.language) -> String {
        if let key { return L10n.text(key) }
        guard let definition = BatteryCatalog.definitions.first(where: { $0.id == id }) else { return id }
        return language == "ru" ? definition.titleRussian : definition.titleEnglish
    }

    /// Value text and state of any catalog reading: «—» when missing, «••••••» when sensitive and not revealed, numbers
    /// via `ReadingDisplay`, short numeric lists formatted item by item, other composites via the catalog presentation.
    static func value(_ reading: CatalogReading?, fahrenheit: Bool, reveal: Bool = false,
                      fractionDigits: ClosedRange<Int> = 0...2) -> (text: String, state: ReadingDisplay.State, dim: Bool) {
        guard let reading else { return ("—", .unavailable, true) }
        let usable = (reading.availability == .available || reading.freshness == .stale) && reading.value != nil
        let state: ReadingDisplay.State = !usable ? .unavailable
            : reading.freshness == .stale ? .stale : reading.freshness == .unknown ? .freshnessUnknown : .live
        if reading.privacy == .sensitive {
            guard usable else { return ("—", .unavailable, true) }
            return reveal ? (CatalogDataPresentation.value(reading, reveal: true, fahrenheit: fahrenheit), state, false)
                          : ("••••••", state, true)
        }
        switch reading.value {
        case .list(let items)?:
            guard usable else { return ("—", .unavailable, true) }
            if let numbers = numbers(items, reading: reading, fahrenheit: fahrenheit, fractionDigits: fractionDigits) {
                let unit = unitText(reading, fahrenheit: fahrenheit)
                let approx = [.estimated, .inferred].contains(reading.provenance) ? "≈ " : ""
                return (approx + numbers.joined(separator: ", ") + (unit.isEmpty ? "" : " " + unit), state, false)
            }
            return (CatalogDataPresentation.conciseValue(reading, reveal: reveal, fahrenheit: fahrenheit), state, false)
        case .object?:
            guard usable else { return ("—", .unavailable, true) }
            return (CatalogDataPresentation.conciseValue(reading, reveal: reveal, fahrenheit: fahrenheit), state, false)
        default:
            let display = ReadingDisplay.make(reading, fahrenheit: fahrenheit, fractionDigits: fractionDigits)
            return (display.text, display.state, display.number == nil)
        }
    }

    /// Cell rows: one row per reported cell voltage (041), then battery current (036) and cell temperatures (040).
    /// Without a usable cell list the voltages stay one «—» row.
    static func cells(_ catalog: [CatalogReading], fahrenheit: Bool, language: String = L10n.language,
                      locale: Locale = L10n.locale) -> [BatteryReadingRow] {
        let reading = { (id: String) in catalog.first { $0.id == id } }
        var rows: [BatteryReadingRow] = []
        if let cells = reading("041"), cells.availability == .available || cells.freshness == .stale,
           case .list(let items)? = cells.value, !items.isEmpty,
           let numbers = numbers(items, reading: cells, fahrenheit: fahrenheit, fractionDigits: 3...3, locale: locale) {
            let unit = unitText(cells, fahrenheit: fahrenheit, language: language)
            let state: ReadingDisplay.State = cells.freshness == .stale ? .stale : .live
            for (index, number) in numbers.enumerated() {
                rows.append(BatteryReadingRow(id: "041.\(index + 1)", label: L10n.text("Cell") + " \(index + 1)",
                                              value: number + " " + unit, state: state))
            }
        } else {
            let value = value(reading("041"), fahrenheit: fahrenheit)
            rows.append(BatteryReadingRow(id: "041", label: title("041", language: language), value: value.text,
                                          state: value.state, dim: value.dim, infoID: "041"))
        }
        for (id, key, digits) in [("036", "Battery current", 2...2), ("040", "Cell temperatures", 1...1)] {
            let value = value(reading(id), fahrenheit: fahrenheit, fractionDigits: digits)
            rows.append(BatteryReadingRow(id: id, label: title(id, key: key, language: language), value: value.text,
                                          state: value.state, dim: value.dim, infoID: id))
        }
        return rows
    }

    /// Rows from (id, title key, decimals, shows (i)).
    static func rows(_ fields: [(String, String?, ClosedRange<Int>, Bool)], catalog: [CatalogReading], fahrenheit: Bool,
                     reveal: Bool = false, language: String = L10n.language) -> [BatteryReadingRow] {
        fields.map { id, key, digits, info in
            let value = value(catalog.first { $0.id == id }, fahrenheit: fahrenheit, reveal: reveal, fractionDigits: digits)
            return BatteryReadingRow(id: id, label: title(id, key: key, language: language), value: value.text,
                                     state: value.state, dim: value.dim, infoID: info ? id : nil)
        }
    }

    static let now: [(String, String?, ClosedRange<Int>, Bool)] = [
        ("011", "Charge", 0...0, true), ("035", "Voltage", 2...2, true),
        ("039", "Temperature", 1...1, true), ("042", "Cell spread", 0...0, true)]
    static let battery: [(String, String?, ClosedRange<Int>, Bool)] = [
        ("023", "macOS condition", 0...0, false), ("025", "macOS assessment", 0...0, true),
        ("057", "Manufacturer", 0...0, true), ("062", "Technology", 0...0, false), ("059", "Serial number", 0...0, false)]
    /// Lifetime counters reported by the gauge (103–111), catalog titles.
    static let lifetime: [(String, String?, ClosedRange<Int>, Bool)] =
        (103...111).map { (String(format: "%03d", $0), nil, 0...1, true) }

    private static func unitText(_ reading: CatalogReading, fahrenheit: Bool, language: String = L10n.language) -> String {
        guard let unit = reading.unit, unit != "cycles" else { return "" }
        if unit == "°C", fahrenheit { return "°F" }
        return CatalogDataPresentation.unit(unit, language: language)
    }

    private static func numbers(_ items: [CatalogValue], reading: CatalogReading, fahrenheit: Bool,
                                fractionDigits: ClosedRange<Int>, locale: Locale = L10n.locale) -> [String]? {
        guard !items.isEmpty, items.count <= 12 else { return nil }
        var out: [String] = []
        for item in items {
            guard var number = item.doubleValue, number.isFinite else { return nil }
            if reading.unit == "°C", fahrenheit { number = number * 9 / 5 + 32 }
            if number == 0 { number = 0 }
            out.append(number.formatted(.number.locale(locale).precision(.fractionLength(fractionDigits))))
        }
        return out
    }
}

// MARK: Shared views

/// Heading outside the tiles (render `CHeading`): title, optional (i), trailing text.
struct BatterySectionHeading<Info: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var info: () -> Info
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.headline)
            info()
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 4).padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

extension BatterySectionHeading where Info == EmptyView {
    init(title: String, trailing: String? = nil) {
        self.init(title: title, trailing: trailing) { EmptyView() }
    }
}

/// Rows tile with an (i) beside the label where the row has a reading behind it.
@MainActor struct BatteryRowsTile: View {
    let rows: [BatteryReadingRow]
    let readings: [String: CatalogReading]
    var fahrenheit = false
    var reveal = false
    /// Catalog id after the label (All data).
    var showsIDs = false
    var body: some View {
        WindowTile(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row).padding(.horizontal, 16)
                    if index < rows.count - 1 { Divider().padding(.leading, 16) }
                }
            }.padding(.vertical, 4)
        }
    }
    private func rowView(_ row: BatteryReadingRow) -> some View {
        HStack(spacing: 4) {
            Text(row.label).fixedSize(horizontal: false, vertical: true)
            if showsIDs, let id = row.infoID {
                Text(id).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            if let id = row.infoID, let reading = readings[id] {
                // The button's 20 pt hit frame would make rows with (i) taller than rows without.
                ReadingInfoButton(reading: reading, reveal: reveal, fahrenheit: fahrenheit).frame(height: 16)
            }
            Spacer(minLength: 12)
            ReadingStateBadge(state: row.dim ? .live : row.state)
            Text(row.value).monospacedDigit().multilineTextAlignment(.trailing).lineLimit(3)
                .textSelection(.enabled)
                .foregroundStyle(row.dim ? AnyShapeStyle(.tertiary)
                                 : row.state == .stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .padding(.vertical, WindowTheme.rowVerticalPadding)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Summary

@MainActor struct BatterySummaryPage: View {
    var model: TilveroModel
    var reveal = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                BatteryLeadView(model: model)
                WindowNoticeView(model: model)
                BatteryCapacityStrip(model: model)
                BatterySummaryRows(model: model, reveal: reveal)
                BatteryLifetimeSection(model: model)
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

@MainActor private func batteryLeadInputs(_ model: TilveroModel) -> BatteryLeadInputs {
    let catalog = model.snapshot.catalog
    func reading(_ id: String) -> CatalogReading? { catalog.first { $0.id == id } }
    func usable(_ reading: CatalogReading?) -> CatalogReading? {
        guard let reading, reading.availability == .available || reading.freshness == .stale, reading.value != nil else { return nil }
        return reading
    }
    var input = BatteryLeadInputs()
    input.weeklyPercent = model.weeklyCapacity?.percent
    if let retention = usable(reading("026")) {
        input.retention = retention.value?.doubleValue
        input.retentionStale = retention.freshness == .stale
    }
    if let condition = usable(reading("023")) {
        input.condition = CatalogDataPresentation.value(condition, reveal: false, fahrenheit: false)
        input.conditionGood = condition.value?.stringValue == "Good"
    }
    if let cycles = usable(reading("027")), case .integer(let count)? = cycles.value { input.cycles = count }
    return input
}

@MainActor private struct BatteryLeadView: View {
    var model: TilveroModel
    var body: some View {
        let lead = BatteryLead.make(batteryLeadInputs(model))
        LeadLine(lead: lead) {
            if let retention = model.snapshot.catalog.first(where: { $0.id == "026" }) {
                ReadingInfoButton(reading: retention, fahrenheit: model.fahrenheit)
            }
        }
    }
}

@MainActor private struct BatteryCapacityStrip: View {
    var model: TilveroModel
    var body: some View {
        let catalog = model.snapshot.catalog
        let fahrenheit = model.fahrenheit
        func reading(_ id: String) -> CatalogReading? { catalog.first { $0.id == id } }
        let input = batteryLeadInputs(model)
        let stale = input.weeklyPercent == nil && input.retentionStale
        return ReadingStrip(items: [
            ReadingStripItem(id: "030", title: L10n.text("Full charge"),
                             display: ReadingDisplay.make(reading("030"), fahrenheit: fahrenheit, fractionDigits: 0...0), reading: reading("030")),
            ReadingStripItem(id: "029", title: L10n.text("Design (capacity)"),
                             display: ReadingDisplay.make(reading("029"), fahrenheit: fahrenheit, fractionDigits: 0...0), reading: reading("029")),
            ReadingStripItem(id: "027", title: L10n.text("Cycles"),
                             display: ReadingDisplay.make(reading("027"), fahrenheit: fahrenheit), reading: reading("027")),
            ReadingStripItem(id: "wear", title: L10n.text("Wear"),
                             display: BatteryLead.wear(retention: BatteryLead.retention(input), stale: stale), reading: reading("026")),
        ]) { _ in EmptyView() }
    }
}

@MainActor private struct BatterySummaryRows: View {
    var model: TilveroModel
    var reveal: Bool
    var body: some View {
        let catalog = model.snapshot.catalog
        let fahrenheit = model.fahrenheit
        let readings = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            BatterySectionHeading(title: L10n.text("Now"))
            BatteryRowsTile(rows: BatteryRows.rows(BatteryRows.now, catalog: catalog, fahrenheit: fahrenheit),
                            readings: readings, fahrenheit: fahrenheit)
            BatterySectionHeading(title: L10n.text("Cells"))
            BatteryRowsTile(rows: BatteryRows.cells(catalog, fahrenheit: fahrenheit), readings: readings, fahrenheit: fahrenheit)
            BatterySectionHeading(title: L10n.text("Battery"))
            BatteryRowsTile(rows: BatteryRows.rows(BatteryRows.battery, catalog: catalog, fahrenheit: fahrenheit, reveal: reveal),
                            readings: readings, fahrenheit: fahrenheit, reveal: reveal)
        }
    }
}

@MainActor private struct BatteryLifetimeSection: View {
    var model: TilveroModel
    @State private var expanded = false
    var body: some View {
        let catalog = model.snapshot.catalog
        let fahrenheit = model.fahrenheit
        let readings = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            // Heading-styled disclosure: the tile keeps the page's full width (a DisclosureGroup would indent it).
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                    Text(L10n.text("All time (battery)")).font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(L10n.text(expanded ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("battery-lifetime")
            if expanded {
                BatteryRowsTile(rows: BatteryRows.rows(BatteryRows.lifetime, catalog: catalog, fahrenheit: fahrenheit),
                                readings: readings, fahrenheit: fahrenheit)
            }
        }
    }
}
