// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// One catalog group as All data draws it: localised title, the rows left after search and filter.
struct BatteryCatalogSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [BatteryReadingRow]
}

enum BatteryCatalogSections {
    /// The ten catalog groups (plus "Other measurements" when present), filtered by the search text and the
    /// «Недоступные поля» toggle; empty groups are dropped. Row labels are catalog titles, values follow the shared rules.
    static func make(_ catalog: [CatalogReading], search: String, showUnavailable: Bool, reveal: Bool, fahrenheit: Bool,
                     language: String = L10n.language) -> [BatteryCatalogSection] {
        CatalogDataGroup.allData(catalog).compactMap { group in
            let visible = CatalogDataGroup.filtered(group.readings, search: search, showUnavailable: showUnavailable)
            guard !visible.isEmpty else { return nil }
            let rows = visible.map { reading in
                let value = BatteryRows.value(reading, fahrenheit: fahrenheit, reveal: reveal)
                return BatteryReadingRow(id: reading.id, label: language == "ru" ? reading.titleRussian : reading.titleEnglish,
                                         value: value.text, state: value.state, dim: value.dim, infoID: reading.id)
            }
            return BatteryCatalogSection(id: group.id, title: L10n.text(group.title), rows: rows)
        }
    }
}

/// All data: the only raw-catalog browser of the window. Search field on the page, filter menu in the page toolbar
/// (owned by `BatteryPage`).
@MainActor struct BatteryCatalogPage: View {
    var model: TilveroModel
    var showUnavailable = true
    var reveal = false
    @State private var search = ""

    var body: some View {
        let catalog = model.snapshot.catalog
        let fahrenheit = model.fahrenheit
        let sections = BatteryCatalogSections.make(catalog, search: search, showUnavailable: showUnavailable,
                                                   reveal: reveal, fahrenheit: fahrenheit)
        let readings = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                BatteryCatalogSearchField(search: $search)
                if sections.isEmpty {
                    WindowTile {
                        EmptyFrame(symbol: "magnifyingglass", title: L10n.text("No matching readings"), height: 90)
                    }
                }
                ForEach(sections) { section in
                    BatterySectionHeading(title: section.title, trailing: section.rows.count.formatted(.number.locale(L10n.locale)))
                    BatteryRowsTile(rows: section.rows, readings: readings, fahrenheit: fahrenheit, reveal: reveal, showsIDs: true)
                }
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

@MainActor private struct BatteryCatalogSearchField: View {
    @Binding var search: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("Search measurements"), text: $search).textFieldStyle(.plain)
                .accessibilityIdentifier("battery-search")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: WindowTheme.fieldRadius, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}
