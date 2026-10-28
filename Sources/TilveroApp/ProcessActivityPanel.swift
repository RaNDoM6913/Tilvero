import SwiftUI
import AppKit
import PowerTelemetry

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
        VStack(alignment: .leading, spacing: compact ? 7 : 14) {
            HStack {
                Label(L10n.text("Application activity"), systemImage: "app.badge").font(compact ? .subheadline : .headline)
                Spacer()
                if compact && allowsNavigation {
                    Button { model.selectedSection = .activity; model.openDetails?() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.text("Application details"))
                }
            }
            if model.isDemo {
                Text(L10n.text("Process activity is unavailable in simulation.")).font(.caption).foregroundStyle(.secondary)
            } else if let snapshot = model.processActivity {
                if Date().timeIntervalSince(snapshot.collectedAt) > 90 { Text(L10n.text("Stale")).font(.caption).foregroundStyle(.orange) }
                if let error = snapshot.collectionError { Text(L10n.text(error)).font(.caption).foregroundStyle(.secondary) }
                if snapshot.isWarmingUp && snapshot.collectionError == nil {
                    Text(L10n.text("Baseline collected. Waiting for the next sample.")).font(.caption).foregroundStyle(.secondary)
                } else if snapshot.rows.isEmpty && snapshot.collectionError == nil {
                    Text(L10n.text("No comparable process samples.")).font(.caption).foregroundStyle(.secondary)
                }
                if !compact {
                    Text(L10n.text("Accessible processes") + ": \(snapshot.accessibleCount)/\(snapshot.listedCount) · " + L10n.text("Denied") + ": \(snapshot.deniedCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(snapshot.rows.prefix(compact ? 3 : 100))) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if let watts = row.cpuPowerWatts { Text("≈ " + number(watts, places: 3) + " W CPU").monospacedDigit() }
                            else { Text(row.cpuPercent.map { number($0, places: 1) + "% CPU" } ?? "—").monospacedDigit() }
                        }.font(compact ? .caption : .body)
                        if row.energyProcessCount < row.processCount || row.cpuProcessCount < row.processCount {
                            Text(L10n.text("Partial process coverage")).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !compact {
                            HStack {
                                Text(row.cpuPercent.map { number($0, places: 1) + "% CPU" } ?? "—")
                                Text(L10n.text("CPU coverage") + ": \(row.cpuProcessCount)/\(row.processCount)")
                                Text(L10n.text("Processes") + ": \(row.processCount)")
                                Text(L10n.text("CPU energy coverage") + ": \(row.energyProcessCount)/\(row.processCount)")
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("Idle wakeups/s") + ": " + optional(row.idleWakeupsPerSecond) + " · " + L10n.text("Interrupt wakeups/s") + ": " + optional(row.interruptWakeupsPerSecond))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("Disk read/write") + ": " + rate(row.readBytesPerSecond) + " / " + rate(row.writtenBytesPerSecond))
                                .font(.caption).foregroundStyle(.secondary)
                            if let share = row.performanceCPUShare { Text(L10n.text("Performance CPU energy share") + ": " + number(share, places: 1) + "%").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityElement(children: .combine).help(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
                }
                Text(L10n.text("Accessible processes") + ": \(snapshot.accessibleCount)/\(snapshot.listedCount)" + (snapshot.truncated ? " · " + L10n.text("Limited scan") : ""))
                    .font(.caption2).foregroundStyle(.secondary)
                if !compact {
                    Text(L10n.text("Denied") + ": \(snapshot.deniedCount) · " + L10n.text("Unavailable") + ": \(snapshot.unavailableCount)").font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("100% CPU means one full CPU. System processes can be inaccessible. Only verified app-bundle members are grouped; child rollups are not added."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.text("Waiting for process observations.")).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }
    private func number(_ value: Double, places: Int) -> String { value.formatted(.number.locale(L10n.locale).precision(.fractionLength(places))) }
    private func optional(_ value: Double?) -> String { value.map { number($0, places: 1) } ?? "—" }
    private func rate(_ value: Double?) -> String { value.map { $0 == 0 ? "0 B/s" : ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max - 1024))), countStyle: .binary) + "/s" } ?? "—" }
}
