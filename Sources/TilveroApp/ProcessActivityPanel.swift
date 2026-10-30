import SwiftUI
import AppKit
import PowerTelemetry

enum ProcessActivityLoadFilter: String, CaseIterable {
    case all, high, moderate, low, unknown

    var title: String {
        switch self {
        case .all: "All loads"
        case .high: "High · ≥50% CPU"
        case .moderate: "Moderate · 10–<50% CPU"
        case .low: "Low · <10% CPU"
        case .unknown: "Unknown CPU usage"
        }
    }

    func includes(_ row: ProcessActivityRow) -> Bool {
        guard self != .all else { return true }
        guard let cpu = ProcessActivitySearch.comparable(row.cpuPercent) else { return self == .unknown }
        switch self {
        case .all: return true
        case .high: return cpu >= 50
        case .moderate: return (10..<50).contains(cpu)
        case .low: return cpu < 10
        case .unknown: return false
        }
    }
}

enum ProcessActivitySort: String, CaseIterable {
    case cpuPower, cpuUsage

    var title: String { self == .cpuPower ? "CPU power" : "CPU usage" }

    func metric(_ row: ProcessActivityRow) -> Double? {
        ProcessActivitySearch.comparable(self == .cpuPower ? row.cpuPowerWatts : row.cpuPercent)
    }
}

enum ProcessActivityListScope: String, CaseIterable {
    case topThree, all

    var title: String { self == .topThree ? "Top 3" : "All" }
}

struct ProcessActivitySearchResult {
    let rows: [ProcessActivityRow]
    let matchingCount: Int
    let totalCount: Int
    let isFiltering: Bool
    let rankableCount: Int
}

enum ProcessActivitySearch {
    static func comparable(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Filter and rank the complete collected list before limiting displayed rows.
    /// An omitted sort preserves observed order for existing search callers.
    static func result(_ rows: [ProcessActivityRow], query: String,
                       filter: ProcessActivityLoadFilter = .all, sort: ProcessActivitySort? = nil,
                       scope: ProcessActivityListScope = .all,
                       displayLimit: Int? = 100) -> ProcessActivitySearchResult {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = rows.filter {
            (normalized.isEmpty || $0.name.localizedCaseInsensitiveContains(normalized)) && filter.includes($0)
        }
        let ranking: ProcessActivitySort? = sort ?? (scope == .topThree ? .cpuPower : nil)
        let rankableCount = ranking.map { order in matches.filter { order.metric($0) != nil }.count } ?? matches.count
        let ordered: [ProcessActivityRow]
        if let ranking {
            ordered = matches.enumerated().sorted { lhs, rhs in
                switch (ranking.metric(lhs.element), ranking.metric(rhs.element)) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }.map(\.element)
        } else {
            ordered = matches
        }
        let displayed = scope == .topThree
            ? Array(ordered.filter { ranking?.metric($0) != nil }.prefix(3))
            : displayLimit.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
        return .init(rows: displayed, matchingCount: matches.count,
                     totalCount: rows.count, isFiltering: !normalized.isEmpty || filter != .all,
                     rankableCount: rankableCount)
    }
}

struct SustainedCPUActivity {
    private struct Run { var seconds: Double; var intervals: Int; var endedAt: Double }
    private var runs: [String: Run] = [:]
    mutating func reset() { runs.removeAll() }
    mutating func accept(_ snapshot: ProcessActivitySnapshot, monotonic: Double) -> [ProcessActivityRow] {
        guard !snapshot.isWarmingUp, snapshot.collectionError == nil,
              let interval = snapshot.intervalSeconds, interval.isFinite, (0.05...45).contains(interval), monotonic.isFinite else {
            reset(); return []
        }
        var next: [String: Run] = [:]
        for row in snapshot.rows {
            // An app's accessible CPU usage is a lower bound, never a battery share.
            guard row.bundlePath != nil, row.processCount > 0, row.cpuProcessCount == row.processCount,
                  let cpu = row.cpuPercent, cpu.isFinite, cpu >= 50 else { continue }
            var run = Run(seconds: 0, intervals: 0, endedAt: monotonic)
            if let previous = runs[row.id], monotonic > previous.endedAt,
               abs(monotonic - previous.endedAt - interval) < 0.01 { run = previous }
            run.seconds += interval; run.intervals += 1; run.endedAt = monotonic
            next[row.id] = run
        }
        runs = next
        return Array(snapshot.rows.filter { row in
            runs[row.id].map { $0.seconds >= 30 && $0.intervals >= 3 } == true
        }.sorted {
            let a = $0.cpuPercent ?? 0, b = $1.cpuPercent ?? 0
            return a == b ? $0.id < $1.id : a > b
        }.prefix(3))
    }
}

@MainActor struct ProcessActivityPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    var allowsNavigation = true
    @State private var search = ""
    @State private var loadFilter: ProcessActivityLoadFilter = .all
    @State private var sort: ProcessActivitySort = .cpuPower
    @State private var scope: ProcessActivityListScope = .topThree
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if compact { compactContent } else { detailedContent }
    }
    private var compactRows: [ProcessActivityRow] {
        guard !model.isDemo, let snapshot = model.processActivity,
              (-5...45).contains(Date().timeIntervalSince(snapshot.collectedAt)) else { return [] }
        return model.highCPUApplications
    }
    private var compactContent: some View {
        Group {
            if !compactRows.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(L10n.text("High CPU usage"), systemImage: "app.badge").font(.subheadline)
                        Spacer()
                        if allowsNavigation {
                            Button { model.selectedSection = .activity; model.openDetails?() } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.borderless).accessibilityLabel(L10n.text("Application details"))
                        }
                    }
                    ForEach(compactRows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(number(row.cpuPercent ?? 0, places: 1) + "% CPU").monospacedDigit()
                        }.font(.caption).accessibilityElement(children: .combine)
                    }
                }.help(L10n.text("Shows accessible apps at 50% or more of one CPU for at least 30 seconds across three or more consecutive intervals. Other processes may be inaccessible."))
            }
        }.accessibilityElement(children: .contain)
    }
    private var detailedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isDemo {
                ProductSurface {
                    Label(L10n.text("Process activity is unavailable in simulation."), systemImage: "testtube.2")
                        .foregroundStyle(.secondary)
                }
            } else if let snapshot = model.processActivity {
                let result = ProcessActivitySearch.result(snapshot.rows, query: search, filter: loadFilter,
                                                          sort: sort, scope: scope, displayLimit: nil)
                processSearch
                processControls
                collectionCoverage(snapshot)
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.text("Application"))
                        Spacer()
                        Text(L10n.text(sort.title))
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 8)
                    if snapshot.isWarmingUp && snapshot.collectionError == nil {
                        Label(L10n.text("Baseline collected. Waiting for the next sample."), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    } else if snapshot.rows.isEmpty && snapshot.collectionError == nil {
                        Text(L10n.text("No comparable process samples.")).foregroundStyle(.secondary)
                    } else if result.isFiltering && result.matchingCount == 0 && snapshot.collectionError == nil {
                        Text(L10n.text("No matching applications or processes")).foregroundStyle(.secondary)
                    } else if scope == .topThree && result.rankableCount == 0 && snapshot.collectionError == nil {
                        Text(L10n.text(sort == .cpuPower ? "No comparable CPU power estimates. Choose All to include unknown values."
                                                       : "No comparable CPU usage samples. Choose All to include unknown values."))
                            .foregroundStyle(.secondary)
                    }
                    if !snapshot.isWarmingUp && snapshot.collectionError == nil {
                        Text(L10n.text("Shown") + ": \(result.rows.count) · "
                             + L10n.text("Matches") + ": \(result.matchingCount) · "
                             + L10n.text(sort == .cpuPower ? "With CPU power" : "With CPU usage") + ": \(result.rankableCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(result.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        applicationRow(row)
                    }
                    if scope == .topThree && !snapshot.isWarmingUp && snapshot.collectionError == nil {
                        Text(L10n.text(sort == .cpuPower ? "Top 3 by available CPU power estimates. Unknown values are included in All."
                                                       : "Top 3 by available CPU usage. Unknown values are included in All."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L10n.text("100% CPU means one full CPU. System processes can be inaccessible. Only verified app-bundle members are grouped; child rollups are not added."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                    Text(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
            } else {
                ProductSurface {
                    Label(L10n.text("Waiting for process observations."), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .contain)
            .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: expanded)
    }

    private var processSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("Search applications or processes"), text: $search).textFieldStyle(.plain)
                .disableAutocorrection(true)
                .accessibilityIdentifier("process-activity-search")
                .onChange(of: search) { _, value in
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scope = .all }
                }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
    }

    private var processControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scopeControl; sortControl; loadControl }
            VStack(alignment: .leading, spacing: 8) {
                scopeControl
                HStack(spacing: 12) { sortControl; loadControl }
            }
            VStack(alignment: .leading, spacing: 8) { scopeControl; sortControl; loadControl }
        }.controlSize(.small)
    }

    private var scopeControl: some View {
        Picker(L10n.text("List scope"), selection: $scope) {
            ForEach(ProcessActivityListScope.allCases, id: \.self) { value in
                Text(L10n.text(value.title)).tag(value)
            }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .accessibilityLabel(L10n.text("List scope"))
            .accessibilityIdentifier("process-activity-scope")
    }

    private var sortControl: some View {
        Picker(L10n.text("Sort by"), selection: $sort) {
            ForEach(ProcessActivitySort.allCases, id: \.self) { value in
                Text(L10n.text(value.title)).tag(value)
            }
        }.pickerStyle(.menu).fixedSize()
            .accessibilityIdentifier("process-activity-sort")
    }

    private var loadControl: some View {
        Picker(L10n.text("CPU load"), selection: $loadFilter) {
            ForEach(ProcessActivityLoadFilter.allCases, id: \.self) { value in
                Text(L10n.text(value.title)).tag(value)
            }
        }.pickerStyle(.menu).fixedSize()
            .accessibilityIdentifier("process-activity-load")
    }

    private func collectionCoverage(_ snapshot: ProcessActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Observed applications")).font(.system(size: 15, weight: .semibold))
            Text(L10n.text("Accessible processes") + ": \(snapshot.accessibleCount)/\(snapshot.listedCount) · "
                 + L10n.text("Denied") + ": \(snapshot.deniedCount) · "
                 + L10n.text("Unavailable") + ": \(snapshot.unavailableCount)")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.text("Observed") + ": " + snapshot.collectedAt.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))
                if snapshot.truncated { Label(L10n.text("Limited scan"), systemImage: "info.circle") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if Date().timeIntervalSince(snapshot.collectedAt) > 90 {
                Label(L10n.text("Stale"), systemImage: "clock.badge.exclamationmark").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let error = snapshot.collectionError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applicationRow(_ row: ProcessActivityRow) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(row.id) }, set: { value in
            if value { expanded.insert(row.id) } else { expanded.remove(row.id) }
        })) {
            VStack(alignment: .leading, spacing: 10) {
                detail("CPU usage", value: cpuUsage(row))
                detail("CPU power", value: cpuPower(row))
                detail("CPU coverage", value: "\(row.cpuProcessCount)/\(row.processCount)")
                detail("CPU energy coverage", value: "\(row.energyProcessCount)/\(row.processCount)")
                detail("Idle wakeups/s", value: optional(row.idleWakeupsPerSecond))
                detail("Interrupt wakeups/s", value: optional(row.interruptWakeupsPerSecond))
                detail("Disk read/write", value: rate(row.readBytesPerSecond) + " / " + rate(row.writtenBytesPerSecond))
                if let share = row.performanceCPUShare {
                    detail("Performance CPU energy share", value: number(share, places: 1) + "%")
                }
            }.padding(.leading, 34).padding(.top, 10)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.bundlePath == nil ? "gearshape" : "app")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.name).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("Processes") + ": \(row.processCount)").font(.caption).foregroundStyle(.secondary)
                    if row.energyProcessCount < row.processCount || row.cpuProcessCount < row.processCount {
                        Text(L10n.text("Partial process coverage")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(sort == .cpuPower ? cpuPower(row) : cpuUsage(row))
                        .font(.system(size: 15, weight: .semibold))
                    Text(sort == .cpuPower ? cpuUsage(row) : cpuPower(row))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
            }.padding(.vertical, 12)
        }.help(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
    }

    private func cpuUsage(_ row: ProcessActivityRow) -> String {
        ProcessActivitySearch.comparable(row.cpuPercent).map { number($0, places: 1) + "% CPU" } ?? "—"
    }

    private func cpuPower(_ row: ProcessActivityRow) -> String {
        ProcessActivitySearch.comparable(row.cpuPowerWatts).map { "≈ " + number($0, places: 3) + " " + CatalogDataPresentation.unit("W") + " CPU" } ?? "—"
    }

    private func detail(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit().textSelection(.enabled)
        } label: {
            Text(L10n.text(title)).foregroundStyle(.secondary)
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    private func number(_ value: Double, places: Int) -> String { value.formatted(.number.locale(L10n.locale).precision(.fractionLength(places))) }
    private func optional(_ value: Double?) -> String { value.map { number($0, places: 1) } ?? "—" }
    private func rate(_ value: Double?) -> String { value.map { $0 == 0 ? "0 B/s" : ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max - 1024))), countStyle: .binary) + "/s" } ?? "—" }
}
