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
        switch self { case .flow: "Energy flow"; case .adapter: "Adapter"; case .statistics: "Statistics" }
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
    var body: some View {
        VStack(spacing: 0) {
            ForEach(readings) { reading in
                CatalogDataRow(reading: reading, reveal: reveal, fahrenheit: fahrenheit)
                if reading.id != readings.last?.id { Divider().padding(.horizontal, 12) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}

@MainActor private struct CatalogDataRow: View {
    let reading: CatalogReading
    let reveal: Bool
    let fahrenheit: Bool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                detail("Source", reading.source)
                detail("Source path", reading.keyPath)
                detail("Availability", L10n.text(reading.availability.rawValue))
                detail("Freshness", L10n.text(reading.freshness.rawValue))
                detail("Provenance", L10n.text(reading.provenance.rawValue))
                detail("Collected", reading.collectedAt.formatted(.dateTime.locale(L10n.locale)))
                detail("Source sample", reading.sourceSampleAt.map { $0.formatted(.dateTime.locale(L10n.locale)) } ?? L10n.text("No source timestamp"))
                if let reason = reading.reason { Text(reason).fixedSize(horizontal: false, vertical: true) }
                if let raw = CatalogDataPresentation.rawValue(reading, reveal: reveal) { detail("Raw value", raw) }
            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(L10n.language == "ru" ? reading.titleRussian : reading.titleEnglish)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(reading.value == nil ? L10n.text("Unavailable") : CatalogDataPresentation.value(reading, reveal: reveal, fahrenheit: fahrenheit))
                        .monospacedDigit().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(reading.value == nil ? Color.secondary : Color.primary)
                    if reading.freshness == .stale { Text(L10n.text("Stale")).foregroundStyle(.orange).font(.caption2) }
                    else if [.estimated, .inferred].contains(reading.provenance) {
                        Text(L10n.text(reading.provenance == .inferred ? "Inferred" : "Estimate")).foregroundStyle(.secondary).font(.caption2)
                    }
                }.frame(minWidth: 110, idealWidth: 180, maxWidth: 230, alignment: .trailing)
            }.font(.subheadline).padding(.vertical, 9)
        }.padding(.horizontal, 12).help(L10n.text("Source details"))
    }
    private func detail(_ key: String, _ value: String) -> some View {
        Text(L10n.text(key) + ": " + value).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor struct DataReadingSection: View {
    let title: String
    let readings: [CatalogReading]
    var reveal = false
    var fahrenheit = false
    var body: some View {
        if !readings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProductSectionHeading(title: title)
                CatalogReadingTable(readings: readings, reveal: reveal, fahrenheit: fahrenheit)
            }
        }
    }
}

/// A main-window summary of a catalog reading, using the same privacy and
/// qualification rules as its expandable source row below.
@MainActor private struct CatalogSummaryMetric: View {
    @ObservedObject var model: TilveroModel
    let id: String
    let title: String
    var reveal = false
    private var reading: CatalogReading? { model.snapshot.catalog.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProductMetric(title: title,
                          value: reading.map { CatalogDataPresentation.value($0, reveal: reveal, fahrenheit: model.fahrenheit) } ?? "—")
            if let reading {
                if reading.value == nil || (reading.availability != .available && reading.freshness != .stale) {
                    Text(L10n.text("Unavailable")).foregroundStyle(.secondary)
                } else if reading.freshness == .stale {
                    Label(L10n.text("Stale"), systemImage: "clock").foregroundStyle(.orange)
                } else if reading.freshness == .unknown {
                    Text(L10n.text("Freshness unknown")).foregroundStyle(.secondary)
                }
                if [.estimated, .inferred].contains(reading.provenance) {
                    Text(L10n.text(reading.provenance == .inferred ? "Inferred" : "Estimate")).foregroundStyle(.secondary)
                }
                Text(L10n.text("Source") + ": " + reading.source).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor struct BatteryDataPanel: View {
    @ObservedObject var model: TilveroModel
    var search = ""
    var showUnavailable = true
    var reveal = false
    @State var tab: BatteryDataTab = .overview
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("Battery section"), selection: $tab) {
                ForEach(BatteryDataTab.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .overview:
                ProductSurface { BatteryEnergyHeading(model: model) }
                section("Battery state", ["011", "013", "014", "015", "016", "023", "024"])
                section("Current readings", ["038", "039", "067", "068", "069", "070", "071"])
            case .capacity:
                ProductIntro(title: "Capacity & condition",
                             subtitle: "Capacity retention is calculated separately from the macOS health assessment.",
                             symbol: "battery.100percent", artwork: EnergyArtwork.image)
                Text(L10n.text("Schematic battery illustration")).font(.caption2).foregroundStyle(.secondary)
                    .help(L10n.text("The illustration does not identify this Mac's physical cell layout."))
                ProductSurface {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        metric("026", "Capacity retention")
                        metric("025", "System maximum capacity")
                        metric("027", "Cycle count")
                    }
                }
                section("Charge capacity", ["029", "030", "031", "112", "113", "115"])
                section("Health & design reference", ["025", "026", "027", "028", "032", "033", "034"])
                section("Battery identity", (57...66).map { String(format: "%03d", $0) })
                Text(L10n.text("Cell manufacturer is not inferred from the reported pack manufacturer.")).font(.caption).foregroundStyle(.secondary)
            case .cells:
                ProductIntro(title: "Pack & cells",
                             subtitle: "Only reported cell readings are shown. Missing sensors are not reconstructed.",
                             symbol: "square.stack.3d.up")
                ProductSurface {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        metric("035", "Battery voltage")
                        metric("039", "Battery temperature")
                        metric("042", "Cell voltage spread")
                    }
                }
                section("Pack & cells", ["035", "036", "037", "039", "040", "041", "042"])
                section("Reported lifetime observations", (103...111).map { String(format: "%03d", $0) })
            case .allData:
                ProductIntro(title: "All data",
                             subtitle: "Every catalog field remains available here. Expand a row for its source and qualification.",
                             symbol: "list.bullet.rectangle")
                ForEach(CatalogDataGroup.allData(model.snapshot.catalog)) { group in
                    DataReadingSection(title: group.title, readings: filtered(group.readings), reveal: reveal, fahrenheit: model.fahrenheit)
                }
            }
        }
    }
    private func filtered(_ readings: [CatalogReading]) -> [CatalogReading] {
        CatalogDataGroup.filtered(readings, search: search, showUnavailable: showUnavailable)
    }
    private func metric(_ id: String, _ title: String) -> some View {
        CatalogSummaryMetric(model: model, id: id, title: title, reveal: reveal)
    }
    private func section(_ title: String, _ ids: [String]) -> some View {
        DataReadingSection(title: title, readings: filtered(ids.compactMap { id in model.snapshot.catalog.first { $0.id == id } }), reveal: reveal, fahrenheit: model.fahrenheit)
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
    @State var tab: PowerDataTab = .flow
    @State private var showControls = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("Power section"), selection: $tab) {
                ForEach(PowerDataTab.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            chargingControls
            switch tab {
            case .flow:
                ProductSurface { PowerConnectionHeading(model: model) }
                section("Electrical boundaries", ["054", "043", "038", "017", "035", "036", "037"])
                Text(L10n.text("Adapter input and battery power measure different electrical boundaries. Rated capability is not current consumption."))
                    .font(.callout).foregroundStyle(.secondary)
                section("Charging state", (13...22).map { String(format: "%03d", $0) })
            case .adapter:
                ProductIntro(title: "Adapter",
                             subtitle: "Device illustrations are schematic.", symbol: "powerplug", artwork: EnergyArtwork.adapter)
                ProductSurface {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .topLeading)], alignment: .leading, spacing: 18) {
                        CatalogSummaryMetric(model: model, id: "050", title: "Rated capability", reveal: reveal)
                        CatalogSummaryMetric(model: model, id: "054", title: "Adapter input", reveal: reveal)
                    }
                    Text(L10n.text("Adapter input and battery power measure different electrical boundaries. Rated capability is not current consumption."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("Adapter identity", (45...49).map { String(format: "%03d", $0) })
                section("Connection capability", ["050", "051", "052", "053"])
                section("Measured input", ["054", "055", "056"])
            case .statistics:
                ProductIntro(title: "Power observations",
                             subtitle: "History starts with observations made by Tilvero. Sleep and missing readings remain gaps.",
                             symbol: "chart.xyaxis.line")
                PowerObservationsPanel(model: model)
                section("Recorded sessions", (72...86).map { String(format: "%03d", $0) })
            }
        }
    }
    private var chargingControls: some View {
        ProductSurface {
            DisclosureGroup(L10n.text("Charging controls & modes"), isExpanded: $showControls) {
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
                }
            }
        }
    }
    private func section(_ title: String, _ ids: [String]) -> some View {
        let readings = ids.compactMap { id in model.snapshot.catalog.first { $0.id == id } }
        return DataReadingSection(title: title, readings: CatalogDataGroup.filtered(readings, search: "", showUnavailable: showUnavailable), reveal: reveal, fahrenheit: model.fahrenheit)
    }
}
