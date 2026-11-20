// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import AppKit
import PowerTelemetry

/// Inputs of the Apps lead, read from the process sample by the page.
struct AppsLeadInputs: Equatable, Sendable {
    var demo = false
    /// No process sample yet.
    var pending = false
    /// A baseline was collected; rates need the next sample.
    var warmingUp = false
    /// The scan's collection error (a localisation key), shown as the reason in the lead.
    var failure: String?
    /// Apps at or above the old panel's high-load threshold (≥ 50 % of one CPU) in this sample.
    var highCount = 0
    var accessibleCount = 0
    var collectedAt: Date?
    var stale = false
    var truncated = false
}

/// What the list tile shows instead of rows (or `.rows`).
enum AppsListState: Equatable, Sendable {
    case demo, pending, warmingUp, failed, noSamples, noMatches, noRankable, rows
}

/// Pure composition of the Apps page (lead, list state, row values), testable without a view tree.
enum AppsComposition {
    /// The old panel's "High · ≥50% CPU" filter threshold.
    static let highThreshold = 50.0
    /// The old panel called a sample stale after 90 s.
    static let staleAfter: TimeInterval = 90

    static func isHigh(cpuPercent: Double?) -> Bool {
        guard let cpu = ProcessActivitySearch.comparable(cpuPercent) else { return false }
        return cpu >= highThreshold
    }

    static func isStale(collectedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(collectedAt) > staleAfter
    }

    /// «из 214 доступных процессов» / "of 214 accessible processes" (genitive singular after 1, 21, 31 …).
    static func accessiblePhrase(_ count: Int, language: String = L10n.language, locale: Locale = L10n.locale) -> String {
        let number = count.formatted(.number.locale(locale))
        if language == "ru" {
            let singular = count % 10 == 1 && count % 100 != 11
            return "из \(number) " + (singular ? "доступного процесса" : "доступных процессов")
        }
        return "of \(number) accessible " + (count == 1 ? "process" : "processes")
    }

    static func lead(_ input: AppsLeadInputs, language: String = L10n.language, locale: Locale = L10n.locale) -> LeadDisplay {
        func t(_ key: String) -> String { L10n.text(key) }
        if input.demo {
            return LeadDisplay(value: "—", status: t("Simulation"), tone: .secondary, detail: t("Process activity is unavailable in simulation."))
        }
        if let failure = input.failure { return LeadDisplay(value: "—", status: t("Unavailable"), tone: .secondary, detail: t(failure)) }
        if input.pending {
            return LeadDisplay(value: "—", status: t("No data"), tone: .secondary, detail: t("Waiting for process observations."))
        }
        if input.warmingUp {
            return LeadDisplay(value: "—", status: t("No data"), tone: .secondary,
                               detail: t("Baseline collected. Waiting for the next sample."))
        }
        var fragments = [accessiblePhrase(input.accessibleCount, language: language, locale: locale)]
        if let time = input.collectedAt { fragments.append(time.formatted(.dateTime.hour().minute().locale(locale))) }
        if input.truncated { fragments.append(t("Limited scan")) }
        let value = input.highCount.formatted(.number.locale(locale))
        if input.stale {
            return LeadDisplay(value: value, status: t("Stale"), tone: .attention,
                               detail: fragments.joined(separator: " · "), stale: true)
        }
        return LeadDisplay(value: value, status: t(input.highCount > 0 ? "High load" : "Calm"),
                           tone: input.highCount > 0 ? .attention : .neutral, detail: fragments.joined(separator: " · "))
    }

    static func listState(demo: Bool, hasSample: Bool, warmingUp: Bool, failed: Bool, sampleRowCount: Int,
                          isFiltering: Bool, matchingCount: Int, topThree: Bool, rankableCount: Int) -> AppsListState {
        if demo { return .demo }
        guard hasSample else { return .pending }
        if failed { return .failed }
        if warmingUp { return .warmingUp }
        if sampleRowCount == 0 { return .noSamples }
        if isFiltering && matchingCount == 0 { return .noMatches }
        if topThree && rankableCount == 0 { return .noRankable }
        return .rows
    }

    /// The row value for the chosen sort: CPU power is an interval estimate («≈ 0,4 Вт», two decimals below 0.1 W), CPU usage a measured share
    /// of one CPU («12,3 %»). A missing value is «—», a valid 0 stays 0.
    static func value(sort: ProcessActivitySort, cpuPercent: Double?, cpuPowerWatts: Double?,
                      locale: Locale = L10n.locale, language: String = L10n.language) -> ReadingDisplay {
        switch sort {
        case .cpuPower:
            guard let watts = ProcessActivitySearch.comparable(cpuPowerWatts) else { return .unavailable }
            let digits = watts > 0 && watts < 0.1 ? 2 : 1
            return ReadingDisplay(number: watts.formatted(.number.locale(locale).precision(.fractionLength(digits))),
                                  unit: CatalogDataPresentation.unit("W", language: language), approximate: true,
                                  state: .live, masked: false)
        case .cpuUsage:
            guard let cpu = ProcessActivitySearch.comparable(cpuPercent) else { return .unavailable }
            return ReadingDisplay(number: cpu.formatted(.number.locale(locale).precision(.fractionLength(1))),
                                  unit: "%", approximate: false, state: .live, masked: false)
        }
    }

    /// Processes the scan could not read (permission denied or gone/unsupported during the scan).
    static func inaccessibleCount(denied: Int, unavailable: Int) -> Int { max(0, denied) + max(0, unavailable) }
}

/// Apps page of the main window (direction C, IA §3.7): lead with the high-load count, toolbar sort / search / filter,
/// one list tile of apps from the current process sample. Scans are driven by the model: it follows the poll while the
/// window shows this section (`processScansFollowPoll`) and scans at once when the section appears
/// (`activityPageMayHaveAppeared` on section change and window visibility), exactly as for the previous panel.
@MainActor struct AppsPage: View {
    var model: TilveroModel
    @State private var search = ""
    @State private var loadFilter: ProcessActivityLoadFilter = .all
    @State private var sort: ProcessActivitySort = .cpuPower
    @State private var scope: ProcessActivityListScope = .all

    var body: some View {
        let _ = RenderProbe.hit("AppsPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                AppsLeadView(model: model)
                WindowNoticeView(model: model)
                AppsListTile(model: model, search: search, loadFilter: loadFilter, sort: sort, scope: scope)
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.activity).title)
        .searchable(text: $search, placement: .toolbar, prompt: L10n.text("Search"))
        .onChange(of: search) { _, value in
            // As in the previous panel: a search looks through every app, not only the top three.
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scope = .all }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L10n.text("Sort by"), selection: $sort) {
                    ForEach(ProcessActivitySort.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                }
                .pickerStyle(.menu).fixedSize().labelsHidden()
                .accessibilityLabel(L10n.text("Sort by"))
                .accessibilityIdentifier("apps-sort")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L10n.text("CPU load"), selection: $loadFilter) {
                        ForEach(ProcessActivityLoadFilter.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                    }.pickerStyle(.inline)
                    Picker(L10n.text("List scope"), selection: $scope) {
                        ForEach(ProcessActivityListScope.allCases, id: \.self) { Text(L10n.text($0.title)).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Label(L10n.text("Filter"), systemImage: loadFilter != .all || scope != .all
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help(L10n.text("Filter"))
                .accessibilityIdentifier("apps-filter")
            }
        }
    }
}

// MARK: Lead

@MainActor private struct AppsLeadView: View {
    var model: TilveroModel
    var body: some View {
        // The clock advances without a new sample (scans stop in sleep or on a failing source), so staleness is re-read.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let snapshot = model.processActivity
            var input = AppsLeadInputs()
            input.demo = model.isDemo
            input.pending = snapshot == nil
            if let snapshot {
                input.warmingUp = snapshot.isWarmingUp
                input.failure = snapshot.collectionError
                input.highCount = snapshot.rows.filter { AppsComposition.isHigh(cpuPercent: $0.cpuPercent) }.count
                input.accessibleCount = snapshot.accessibleCount
                input.collectedAt = snapshot.collectedAt
                input.stale = AppsComposition.isStale(collectedAt: snapshot.collectedAt, now: context.date)
                input.truncated = snapshot.truncated
            }
            return LeadLine(lead: AppsComposition.lead(input)) { EmptyView() }
        }
    }
}

// MARK: List

@MainActor private struct AppsListTile: View {
    var model: TilveroModel
    let search: String
    let loadFilter: ProcessActivityLoadFilter
    let sort: ProcessActivitySort
    let scope: ProcessActivityListScope

    var body: some View {
        let snapshot = model.isDemo ? nil : model.processActivity
        let result = snapshot.map {
            ProcessActivitySearch.result($0.rows, query: search, filter: loadFilter, sort: sort, scope: scope, displayLimit: nil)
        }
        let state = AppsComposition.listState(
            demo: model.isDemo, hasSample: snapshot != nil, warmingUp: snapshot?.isWarmingUp ?? false,
            failed: snapshot?.collectionError != nil, sampleRowCount: snapshot?.rows.count ?? 0,
            isFiltering: result?.isFiltering ?? false, matchingCount: result?.matchingCount ?? 0,
            topThree: scope == .topThree, rankableCount: result?.rankableCount ?? 0)
        if state != .failed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(L10n.text("Observed applications")).font(.system(size: 13, weight: .semibold))
                    AppsInfoButton(snapshot: snapshot)
                    Spacer(minLength: 0)
                }
                WindowTile(padding: 0) {
                    if state == .rows, let snapshot, let result {
                        rows(result.rows, snapshot: snapshot, showInaccessible: !result.isFiltering)
                    } else {
                        frame(state)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ rows: [ProcessActivityRow], snapshot: ProcessActivitySnapshot, showInaccessible: Bool) -> some View {
        let inaccessible = AppsComposition.inaccessibleCount(denied: snapshot.deniedCount, unavailable: snapshot.unavailableCount)
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 52) }
                AppsRow(name: row.name, bundlePath: row.bundlePath, processCount: row.processCount,
                        value: AppsComposition.value(sort: sort, cpuPercent: row.cpuPercent, cpuPowerWatts: row.cpuPowerWatts),
                        high: AppsComposition.isHigh(cpuPercent: row.cpuPercent),
                        help: helpText(row))
                    .padding(.horizontal, 16)
            }
            if showInaccessible && inaccessible > 0 {
                if !rows.isEmpty { Divider().padding(.leading, 52) }
                AppsRow(name: L10n.text("Unavailable"), bundlePath: nil, symbol: "lock", processCount: inaccessible,
                        value: .unavailable, high: false, dimmed: true,
                        help: L10n.text("Denied") + ": \(snapshot.deniedCount) · " + L10n.text("Unavailable") + ": \(snapshot.unavailableCount)")
                    .padding(.horizontal, 16)
            }
        }.padding(.vertical, 4)
    }

    /// The other metric in the tooltip (the list shows the sorted one).
    private func helpText(_ row: ProcessActivityRow) -> String {
        let usage = AppsComposition.value(sort: .cpuUsage, cpuPercent: row.cpuPercent, cpuPowerWatts: nil).text
        let power = AppsComposition.value(sort: .cpuPower, cpuPercent: nil, cpuPowerWatts: row.cpuPowerWatts).text
        return L10n.text("CPU usage") + ": " + usage + " · " + L10n.text("CPU power") + ": " + power
    }

    @ViewBuilder private func frame(_ state: AppsListState) -> some View {
        switch state {
        case .demo:
            EmptyFrame(symbol: "testtube.2", title: L10n.text("Simulation"))
        case .pending:
            EmptyFrame(symbol: "clock", title: L10n.text("Waiting for process observations."), loading: true)
        case .warmingUp:
            EmptyFrame(symbol: "clock", title: L10n.text("Baseline collected. Waiting for the next sample."))
        case .noSamples:
            EmptyFrame(symbol: "square.stack.3d.up.slash", title: L10n.text("No comparable process samples."))
        case .noMatches:
            EmptyFrame(symbol: "magnifyingglass", title: L10n.text("No matching applications or processes"))
        case .noRankable:
            EmptyFrame(symbol: "line.3.horizontal.decrease.circle",
                       title: L10n.text(sort == .cpuPower ? "No comparable CPU power estimates. Choose All to include unknown values."
                                                          : "No comparable CPU usage samples. Choose All to include unknown values."))
        case .failed, .rows:
            EmptyView()
        }
    }
}

/// The (i) after the list title: the previous panel's footnotes and the scan coverage.
@MainActor private struct AppsInfoButton: View {
    let snapshot: ProcessActivitySnapshot?
    var body: some View {
        var paragraphs = [
            L10n.text("100% CPU means one full CPU. System processes can be inaccessible. Only verified app-bundle members are grouped; child rollups are not added."),
            L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."),
        ]
        if let snapshot, snapshot.collectionError == nil {
            var coverage = L10n.text("Accessible processes") + ": \(snapshot.accessibleCount)/\(snapshot.listedCount) · "
                + L10n.text("Denied") + ": \(snapshot.deniedCount) · " + L10n.text("Unavailable") + ": \(snapshot.unavailableCount)"
            if snapshot.truncated { coverage += " · " + L10n.text("Limited scan") }
            paragraphs.append(coverage)
        }
        return SectionInfoButton(title: L10n.text("Observed applications"), paragraphs: paragraphs, id: "apps-info")
    }
}

/// One app: icon, name, «Процессов: N», value (orange at high load).
@MainActor private struct AppsRow: View {
    let name: String
    let bundlePath: String?
    var symbol = "gearshape"
    let processCount: Int
    let value: ReadingDisplay
    let high: Bool
    var dimmed = false
    let help: String

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(L10n.text("Processes (count)") + ": \(processCount)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            WindowNumber(display: value, size: 15, tint: high ? .orange : .primary)
                .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        if let bundlePath, let image = AppsIconCache.icon(bundlePath) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}

/// App icons by bundle path (the list re-renders every poll; the icon of a bundle does not change while shown).
@MainActor enum AppsIconCache {
    private static var icons: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage? {
        if let icon = icons[path] { return icon }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if icons.count > 512 { icons.removeAll() }
        icons[path] = icon
        return icon
    }
}
