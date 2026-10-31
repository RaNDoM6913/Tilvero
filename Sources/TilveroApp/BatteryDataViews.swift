import SwiftUI
import PowerCore

// Presentation routing only: source readings and all qualification metadata remain intact.
enum BatteryDataTab: String, CaseIterable, Identifiable {
    case overview, capacity, cells, allData
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "Overview"; case .capacity: "Capacity"; case .cells: "Cells"; case .allData: "All data" }
    }
}
enum PowerDataTab: String, CaseIterable, Identifiable {
    case flow, adapter, statistics
    var id: String { rawValue }
    var title: String {
        switch self { case .flow: "Power"; case .adapter: "Adapter"; case .statistics: "Observations" }
    }
}

struct CatalogDataGroup: Identifiable {
    let id: String
    let title: String
    let readings: [CatalogReading]
    static func allData(_ catalog: [CatalogReading]) -> [Self] {
        let categories = [("device", "Device"), ("charge", "Charging state"), ("condition", "Capacity & condition"),
                          ("electrical", "Electrical readings"), ("adapter", "Adapter"), ("identity", "Battery identity"),
                          ("timing", "Time estimates"), ("history", "Recorded history"), ("cooling", "Cooling"), ("diagnostics", "Diagnostics & raw counters")]
        var groups = categories.map { category, title in
            Self(id: category, title: title, readings: catalog.filter { $0.category == category })
        }
        let known = Set(categories.map(\.0))
        let other = catalog.filter { !known.contains($0.category) }
        if !other.isEmpty { groups.append(.init(id: "other", title: "Other measurements", readings: other)) }
        return groups.filter { !$0.readings.isEmpty }
    }
    static func normalizedSearch(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func filtered(_ rows: [CatalogReading], search: String, showUnavailable: Bool) -> [CatalogReading] {
        let query = normalizedSearch(search)
        return rows.filter { row in
            let matches = query.isEmpty || "\(row.titleEnglish) \(row.titleRussian) \(row.id)".localizedCaseInsensitiveContains(query)
            return matches && (showUnavailable || !query.isEmpty || row.value != nil)
        }
    }
}

enum CatalogDataPresentation {
    static func unit(_ unit: String, language: String = L10n.language) -> String {
        guard language == "ru" else { return unit }
        return ["W": "Вт", "V": "В", "A": "А", "mV": "мВ", "mAh": "мА·ч", "Wh": "Вт·ч", "h": "ч", "s": "с", "RPM": "об/мин"][unit] ?? unit
    }
    static func value(_ reading: CatalogReading, reveal: Bool, fahrenheit: Bool) -> String {
        guard reading.privacy != .sensitive || reveal else { return reading.value == nil ? "—" : "••••••" }
        guard reading.availability == .available || reading.freshness == .stale, let value = reading.value else { return "—" }
        let displayed: String
        // Keep raw integer counters exact, including values beyond Double's integer precision.
        if case .integer(let number) = value, reading.unit != "cycles", reading.unit != "°C" {
            let suffix = reading.unit.map { unit($0) }
            displayed = number.formatted(.number.locale(L10n.locale)) + (suffix.map { " " + $0 } ?? "")
        } else if reading.id == "071", case .text(let status) = value {
            displayed = status == "unavailable" ? L10n.text("Unavailable")
                : status == "systemEstimate; target estimate unavailable" ? L10n.text("System estimate; target estimate unavailable") : status
        } else {
            let original = ReadingPresentation.display(reading, reveal: reveal, fahrenheit: fahrenheit)
            if let originalUnit = reading.unit, original.hasSuffix(" " + originalUnit) {
                displayed = String(original.dropLast(originalUnit.count)) + unit(originalUnit)
            } else { displayed = original }
        }
        return ([.estimated, .inferred].contains(reading.provenance) ? "≈ " : "") + displayed
    }
    static func rawValue(_ reading: CatalogReading, reveal: Bool) -> String? {
        guard reading.privacy != .sensitive || reveal else { return nil }
        return reading.rawValue?.displayText
    }
}

@MainActor struct CatalogReadingTable: View {
    let readings: [CatalogReading]
    var reveal = false
    var fahrenheit = false
    var titles: [String: String] = [:]
    var showsIDs = false
    var body: some View {
        VStack(spacing: 0) {
            ForEach(readings) { reading in
                CatalogDataRow(reading: reading, reveal: reveal, fahrenheit: fahrenheit,
                               title: titles[reading.id], showsID: showsIDs)
                if reading.id != readings.last?.id { Divider().opacity(0.55) }
            }
        }
    }
}

/// Only notable qualifications appear beside everyday values. They are independent:
/// retaining an old estimate must not hide either its age or its derivation.
extension CatalogDataPresentation {
    static func qualifications(_ reading: CatalogReading) -> [String] {
        var labels: [String] = []
        if reading.availability != .available { labels.append(L10n.text(reading.availability.rawValue)) }
        if reading.freshness == .stale { labels.append(L10n.text("Stale")) }
        else if reading.value != nil && reading.freshness == .unknown { labels.append(L10n.text("Freshness unknown")) }
        if [.estimated, .inferred].contains(reading.provenance) {
            labels.append(L10n.text(reading.provenance == .inferred ? "Inferred" : "Estimate"))
        }
        return labels
    }

    static func conciseValue(_ reading: CatalogReading, reveal: Bool, fahrenheit: Bool) -> String {
        // Apply the same reveal/availability boundary before inspecting composite values.
        guard reading.privacy != .sensitive || reveal,
              reading.availability == .available || reading.freshness == .stale,
              let value = reading.value else {
            return reading.value == nil ? L10n.text("Unavailable") : self.value(reading, reveal: reveal, fahrenheit: fahrenheit)
        }
        switch value {
        case .list(let values):
            // Preserve useful small readings such as the three reported cell
            // voltages. Diagnostic payloads still require deliberate inspection.
            if !values.isEmpty && values.count <= 6 {
                let parts = values.compactMap { value -> String? in
                    switch value {
                    case .integer, .decimal, .boolean, .text, .date:
                        let text = value.displayText
                        return text.count <= 32 && text.rangeOfCharacter(from: .newlines) == nil ? text : nil
                    case .list, .object: return nil
                    }
                }
                if parts.count == values.count && parts.joined(separator: ", ").count <= 120 {
                    return self.value(reading, reveal: reveal, fahrenheit: fahrenheit)
                }
            }
            return "\(values.count) " + L10n.text("values")
        case .object(let properties): return "\(properties.count) " + L10n.text("properties")
        default: return self.value(reading, reveal: reveal, fahrenheit: fahrenheit)
        }
    }
}

struct ReadingDetailField: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// The concise surface never consumes technical source strings or raw values.
/// The complete projection remains available on the deliberately opened sheet.
struct ReadingInfoPresentation {
    let reading: CatalogReading
    var reveal = false
    var fahrenheit = false
    var title: String { L10n.language == "ru" ? reading.titleRussian : reading.titleEnglish }
    var qualifications: [String] { CatalogDataPresentation.qualifications(reading) }
    var value: String { CatalogDataPresentation.conciseValue(reading, reveal: reveal, fahrenheit: fahrenheit) }
    var explanation: String {
        let key: String
        switch reading.id {
        case "011": key = "The charge level reported by macOS."
        case "025": key = "The maximum-capacity assessment reported by macOS."
        case "026": key = "Full-charge capacity compared with design capacity. Calculated separately from the macOS health assessment."
        case "027": key = "The accumulated battery cycle count reported by the source."
        case "029": key = "The design charge capacity reported for the battery."
        case "030": key = "The reported charge capacity of the battery when full."
        case "031": key = "The reported charge capacity currently remaining in the battery."
        case "035": key = "The electrical voltage reported for the battery pack."
        case "038": key = "Approximate battery power calculated from voltage and current."
        case "039": key = "The temperature reading reported for the battery."
        case "042": key = "The difference between the highest and lowest reported cell voltages."
        case "050": key = "The adapter's reported power capability, which can differ from current power use."
        case "054": key = "The input-power reading reported by the battery subsystem."
        case "067", "068", "069", "070": key = "A time estimate that can change with activity and charging conditions."
        default: key = "Availability depends on the data reported for this Mac."
        }
        return L10n.text(key)
    }
    var sourceDate: ReadingDetailField? {
        guard reading.freshness == .stale, let date = reading.sourceSampleAt else { return nil }
        return .init(label: L10n.text("Source sample"), value: date.formatted(.dateTime.locale(L10n.locale)))
    }
    var technicalFields: [ReadingDetailField] {
        func field(_ label: String, _ value: String) -> ReadingDetailField { .init(label: L10n.text(label), value: value) }
        var fields = [
            field("Value", CatalogDataPresentation.value(reading, reveal: reveal, fahrenheit: fahrenheit)),
            field("Source", reading.source), field("Source path", reading.keyPath),
            field("Availability", L10n.text(reading.availability.rawValue)),
            field("Freshness", L10n.text(reading.freshness.rawValue)),
            field("Provenance", L10n.text(reading.provenance.rawValue)),
            field("Collected", timestamp(reading.collectedAt)),
            field("Source sample", reading.sourceSampleAt.map(timestamp) ?? L10n.text("No source timestamp"))
        ]
        if let age = reading.monotonicAgeSeconds { fields.append(field("Sample age (seconds)", String(age))) }
        if let reason = reading.reason { fields.append(field("Reason", reason)) }
        if let raw = CatalogDataPresentation.rawValue(reading, reveal: reveal) { fields.append(field("Raw value", raw)) }
        return fields
    }
    private func timestamp(_ date: Date) -> String {
        date.ISO8601Format(.init(includingFractionalSeconds: true))
    }
}

/// Both presentations belong to this persistent button, rather than presenting a
/// sheet from a popover subtree that disappears as the popover closes.
@MainActor struct ReadingInfoButton: View {
    let reading: CatalogReading
    var reveal = false
    var fahrenheit = false
    @State private var showingInfo = false
    @State private var showingTechnicalDetails = false
    @State private var technicalDetailsRequested = false
    @FocusState private var buttonFocused: Bool
    private var presentation: ReadingInfoPresentation {
        .init(reading: reading, reveal: reveal, fahrenheit: fahrenheit)
    }
    var body: some View {
        Button { showingInfo = true } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusable()
        .focused($buttonFocused)
        .onKeyPress(.space) { showingInfo = true; return .handled }
        .onKeyPress(.return) { showingInfo = true; return .handled }
        .accessibilityLabel(L10n.text("Reading details") + ": " + presentation.title)
        .accessibilityIdentifier("reading-info-" + reading.id)
        .help(L10n.text("Reading details"))
        .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
            ReadingInfoPopover(presentation: presentation) {
                technicalDetailsRequested = true
                showingInfo = false
            }
        }
        .onChange(of: showingInfo) { _, visible in
            if !visible {
                if technicalDetailsRequested {
                    technicalDetailsRequested = false
                    // Let the native popover complete dismissal before opening a sheet.
                    Task { @MainActor in
                        await Task.yield()
                        showingTechnicalDetails = true
                    }
                } else { buttonFocused = true }
            }
        }
        .sheet(isPresented: $showingTechnicalDetails, onDismiss: { buttonFocused = true }) {
            ReadingTechnicalDetails(presentation: presentation)
        }
    }
}

@MainActor struct ReadingInfoPopover: View {
    let presentation: ReadingInfoPresentation
    let showTechnicalDetails: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(presentation.value).font(.title2).monospacedDigit().textSelection(.enabled)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(presentation.explanation).fixedSize(horizontal: false, vertical: true)
            if !presentation.qualifications.isEmpty {
                Text(presentation.qualifications.joined(separator: " · ")).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = presentation.sourceDate {
                Text(date.label + ": " + date.value).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button(L10n.text("Technical details"), action: showTechnicalDetails)
                .accessibilityIdentifier("reading-technical-" + presentation.reading.id)
        }
        .font(.body).padding(18).frame(width: 320, alignment: .leading)
    }
}

@MainActor struct ReadingTechnicalDetails: View {
    let presentation: ReadingInfoPresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(presentation.title).font(.title2).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Technical details")).font(.headline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(presentation.technicalFields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).font(.headline)
                            Text(field.value).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
            }
            HStack {
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(.body).padding(24).frame(width: 560, height: 560)
            .onExitCommand { dismiss() }
    }
}

@MainActor private struct CatalogDataRow: View {
    let reading: CatalogReading
    let reveal: Bool
    let fahrenheit: Bool
    var title: String? = nil
    var showsID = false
    private var label: String {
        let name = title.map(L10n.text) ?? (L10n.language == "ru" ? reading.titleRussian : reading.titleEnglish)
        return name + (showsID ? " · " + reading.id : "")
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .trailing, spacing: 3) {
                Text(CatalogDataPresentation.conciseValue(reading, reveal: reveal, fahrenheit: fahrenheit))
                    .monospacedDigit().textSelection(.enabled).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(reading.value == nil ? Color.secondary : Color.primary)
                let qualifications = CatalogDataPresentation.qualifications(reading)
                if !qualifications.isEmpty {
                    Text(qualifications.joined(separator: " · "))
                        .foregroundStyle(reading.freshness == .stale ? Color.orange : Color.secondary)
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }.fixedSize(horizontal: false, vertical: true)
            ReadingInfoButton(reading: reading, reveal: reveal, fahrenheit: fahrenheit)
        }.font(.system(size: 12)).padding(.vertical, 8)
    }
}

@MainActor struct DataReadingSection: View {
    let title: String
    let readings: [CatalogReading]
    var reveal = false
    var fahrenheit = false
    var titles: [String: String] = [:]
    var showsIDs = false
    var body: some View {
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !title.isEmpty { ProductSectionHeading(title: title) }
                CatalogReadingTable(readings: readings, reveal: reveal, fahrenheit: fahrenheit,
                                    titles: titles, showsIDs: showsIDs)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Summary readings share the value, privacy and quality rules of their detail rows.
@MainActor struct CatalogSummaryMetric: View {
    @ObservedObject var model: TilveroModel
    let id: String
    let title: String
    var reveal = false
    private var reading: CatalogReading? { model.snapshot.catalog.first { $0.id == id } }
    private var value: String {
        guard let reading else { return "—" }
        // The metric's explicit cycle label supplies the unit; keep the counter exact.
        if reading.unit == "cycles", reading.privacy != .sensitive || reveal,
           reading.availability == .available || reading.freshness == .stale,
           case .integer(let count) = reading.value {
            return ([.estimated, .inferred].contains(reading.provenance) ? "≈ " : "")
                + count.formatted(.number.locale(L10n.locale))
        }
        return CatalogDataPresentation.value(reading, reveal: reveal, fahrenheit: model.fahrenheit)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: value.rangeOfCharacter(from: .decimalDigits) == nil ? 22 : 28, weight: .medium, design: .rounded))
                .monospacedDigit().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reading { ReadingInfoButton(reading: reading, reveal: reveal, fahrenheit: model.fahrenheit) }
            }
            if let reading {
                let quality = CatalogDataPresentation.qualifications(reading)
                if !quality.isEmpty {
                    Text(quality.joined(separator: " · "))
                        .foregroundStyle(reading.freshness == .stale ? Color.orange : Color.secondary)
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

@MainActor struct BatteryDataPanel: View {
    @ObservedObject var model: TilveroModel
    var showUnavailable = true
    var reveal = false
    var options: AnyView? = nil
    @State var tab: BatteryDataTab = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(L10n.text("Battery section"), selection: $tab) {
                ForEach(BatteryDataTab.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("battery-tabs")
            batteryContent.id(tab).transition(.opacity)
        }.animation(ProductMotion.animation(reduceMotion: reduceMotion), value: tab)
    }
    @ViewBuilder private var batteryContent: some View {
        switch tab {
        case .overview:
            VStack(spacing: 18) {
                BatteryEnergyHeading(model: model)
                HStack(alignment: .top, spacing: 20) {
                    section("Battery", [("023", "Condition"), ("057", "Pack manufacturer"), ("062", "Technology"),
                                        ("033", "Design energy"), ("034", "Full-charge energy")])
                    section("Current readings", [("011", "Charge"), ("031", "Remaining charge capacity"),
                                                 ("035", "Voltage"), ("039", "Temperature"), ("027", "Cycles")])
                }
            }
        case .capacity:
            VStack(alignment: .leading, spacing: 22) {
                EnergyArtworkView(image: EnergyArtwork.image, symbol: "battery.100percent", height: 145)
                    .frame(maxWidth: .infinity)
                EnergySchematicCaption()
                HStack(alignment: .top, spacing: 22) {
                    metric("026", "Capacity retention")
                    metric("025", "macOS assessment")
                    metric("027", "Cycles")
                }
                section("Charge capacity", [("029", "Design capacity"), ("030", "At full charge"), ("031", "Now")])
                section("Condition & identity", [("023", "Battery condition"), ("057", "Pack manufacturer"), ("059", "Serial number")])
                Text(L10n.text("Cell manufacturer is not inferred from the reported pack manufacturer."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .cells:
            VStack(alignment: .leading, spacing: 22) {
                EnergyArtworkView(image: EnergyArtwork.image, symbol: "battery.100percent", height: 155)
                    .frame(maxWidth: .infinity)
                EnergySchematicCaption()
                HStack(alignment: .top, spacing: 20) {
                    metric("035", "Pack voltage")
                    metric("039", "Battery temperature")
                    metric("042", "Cell voltage spread")
                }
                section("Reported cells", [("041", "Voltages"), ("036", "Battery current"), ("040", "Cell temperatures")])
                Text(L10n.text("Only reported cell readings are shown. Missing sensors are not reconstructed."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                section("Reported lifetime observations", (103...111).map { (String(format: "%03d", $0), "") })
            }
        case .allData:
            VStack(alignment: .leading, spacing: 22) {
                if let options { options }
                Text(L10n.text("Every catalog field remains available here. Use the info button for an explanation and technical details."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(CatalogDataGroup.allData(model.snapshot.catalog)) { group in
                    DataReadingSection(title: group.title,
                                       readings: CatalogDataGroup.filtered(group.readings, search: "", showUnavailable: showUnavailable),
                                       reveal: reveal, fahrenheit: model.fahrenheit, showsIDs: true)
                }
            }
        }
    }
    private func metric(_ id: String, _ title: String) -> some View {
        CatalogSummaryMetric(model: model, id: id, title: title, reveal: reveal)
    }
    private func section(_ title: String, _ fields: [(String, String)]) -> some View {
        let readings = fields.compactMap { id, _ in model.snapshot.catalog.first { $0.id == id } }
        let titles = Dictionary(uniqueKeysWithValues: fields.filter { !$0.1.isEmpty })
        return DataReadingSection(title: title, readings: readings, reveal: reveal, fahrenheit: model.fahrenheit, titles: titles)
    }
}

@MainActor struct BatteryStateHeading: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NativeBatteryStatusImage.make(
                level: model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil,
                style: .iconOnly,
                externalPower: model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.freshness != .stale && model.snapshot.isExternalPower.value == true))
                .resizable().interpolation(.high).frame(width: 64, height: 42).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.chargeText).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(model.chargingStateText).font(.subheadline).foregroundStyle(.secondary)
                if model.snapshot.chargePercent.freshness == .stale { Text(L10n.text("Stale")).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
        }.padding(.vertical, 4)
    }
}

@MainActor struct PowerDataPanel: View {
    @ObservedObject var model: TilveroModel
    var showUnavailable = true
    var reveal = false
    var options: AnyView? = nil
    @State var tab: PowerDataTab = .flow
    @State private var showControls = false
    @State private var showRecorded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(L10n.text("Power section"), selection: $tab) {
                ForEach(PowerDataTab.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("power-tabs")
            powerContent.id(tab).transition(.opacity)
        }.animation(ProductMotion.animation(reduceMotion: reduceMotion), value: tab)
    }
    @ViewBuilder private var powerContent: some View {
        switch tab {
        case .flow:
            VStack(spacing: 20) {
                PowerConnectionHeading(model: model)
                chargingControls
            }
        case .adapter:
            VStack(alignment: .leading, spacing: 22) {
                EnergyArtworkView(image: EnergyArtwork.adapter, symbol: "powerplug", height: 200)
                    .frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 24) {
                    CatalogSummaryMetric(model: model, id: "050", title: "Rated capability", reveal: reveal)
                    CatalogSummaryMetric(model: model, id: "054", title: "Input power", reveal: reveal)
                }
                if let options { options }
                section("Adapter data", ["015", "050", "051", "052", "047", "048"],
                        titles: ["015": "Connection", "050": "Rated capability", "051": "Negotiated voltage",
                                 "052": "Current ceiling", "047": "Adapter identifier", "048": "Serial number"],
                        includeUnavailable: showUnavailable)
                Text(L10n.text("Device illustrations are schematic. Exact adapter model and authenticity are not established by power capability."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.text("More adapter readings")) {
                    section("", ["045", "046", "049", "053", "055", "056"], includeUnavailable: showUnavailable)
                        .padding(.top, 12)
                }.font(.callout)
                chargingControls
            }
        case .statistics:
            VStack(alignment: .leading, spacing: 22) {
                section("Independent observations", ["015", "013", "054", "038", "069", "070"],
                        titles: ["015": "External power · 015", "013": "Charging · 013", "054": "Input power · 054",
                                 "038": "Battery power · 038", "069": "Until full charge · 069", "070": "Until target level"])
                Label(L10n.text("Input power and battery power do not describe the Mac's complete power consumption. Component energy use is not calculated here."), systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $showRecorded) {
                    VStack(alignment: .leading, spacing: 18) {
                        PowerObservationsPanel(model: model)
                        section("Recorded sessions", (72...86).map { String(format: "%03d", $0) }, includeUnavailable: showUnavailable)
                    }.padding(.top, 12)
                } label: { Text(L10n.text("Recorded observations")).font(.callout.weight(.medium)) }
                    .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: showRecorded)
                chargingControls
            }
        }
    }
    private var chargingControls: some View {
        DisclosureGroup(isExpanded: $showControls) {
            VStack(alignment: .leading, spacing: 18) {
                ChargeLimitControl(model: model).padding(.top, 10)
                if model.canShowChargeControls {
                    HStack {
                        Button(L10n.text(model.isOneShotDemo ? "Cancel one-time charge" : "Charge to 100% once")) { model.toggleOneShotDemo() }.disabled(!model.canChargeToFullOnce)
                        Button(L10n.text("Return to system control")) { model.releaseControl() }.disabled(!model.canReleaseCharge)
                    }.disabled(model.isApplying)
                }
                Label(L10n.text("Power mode") + ": " + L10n.text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power" : "Automatic"), systemImage: "bolt.circle")
                ProfilePanel(model: model)
            }.padding(.top, 12).padding(.bottom, 4)
        } label: {
            Text(L10n.text("Charging controls & modes")).font(.callout.weight(.medium)).foregroundStyle(.primary)
        }
        .disclosureGroupStyle(ProductDisclosureStyle(headerInset: 12))
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: showControls)
    }
    private func section(_ title: String, _ ids: [String], titles: [String: String] = [:], includeUnavailable: Bool = true) -> some View {
        let readings = ids.compactMap { id in model.snapshot.catalog.first { $0.id == id } }
        return DataReadingSection(title: title,
                                  readings: CatalogDataGroup.filtered(readings, search: "", showUnavailable: includeUnavailable),
                                  reveal: reveal, fahrenheit: model.fahrenheit, titles: titles)
    }
}
