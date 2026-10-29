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
        VStack(alignment: .leading, spacing: 18) {
            ProductIntro(title: "Application activity",
                         subtitle: "CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption.",
                         symbol: "app.badge")
            if model.isDemo {
                ProductSurface {
                    Label(L10n.text("Process activity is unavailable in simulation."), systemImage: "testtube.2")
                        .foregroundStyle(.secondary)
                }
            } else if let snapshot = model.processActivity {
                collectionCoverage(snapshot)
                ProductSurface(title: "Observed applications", symbol: "square.stack.3d.up") {
                    if snapshot.isWarmingUp && snapshot.collectionError == nil {
                        Label(L10n.text("Baseline collected. Waiting for the next sample."), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    } else if snapshot.rows.isEmpty && snapshot.collectionError == nil {
                        Text(L10n.text("No comparable process samples.")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(snapshot.rows.prefix(100).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        applicationRow(row)
                    }
                    Text(L10n.text("100% CPU means one full CPU. System processes can be inaccessible. Only verified app-bundle members are grouped; child rollups are not added."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProductSurface {
                    Label(L10n.text("Waiting for process observations."), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .contain)
    }

    private func collectionCoverage(_ snapshot: ProcessActivitySnapshot) -> some View {
        ProductSurface(title: "Collection coverage", symbol: "waveform.path") {
            HStack(alignment: .top, spacing: 20) {
                ProductMetric(title: "Accessible processes", value: "\(snapshot.accessibleCount)/\(snapshot.listedCount)")
                ProductMetric(title: "Denied", value: "\(snapshot.deniedCount)")
                ProductMetric(title: "Unavailable", value: "\(snapshot.unavailableCount)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.text("Observed") + ": " + snapshot.collectedAt.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))
                if snapshot.truncated { Label(L10n.text("Limited scan"), systemImage: "info.circle") }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if Date().timeIntervalSince(snapshot.collectedAt) > 90 {
                Label(L10n.text("Stale"), systemImage: "clock.badge.exclamationmark").font(.callout).foregroundStyle(.orange)
            }
            if let error = snapshot.collectionError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applicationRow(_ row: ProcessActivityRow) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                detail("CPU usage", value: row.cpuPercent.map { number($0, places: 1) + "% CPU" } ?? "—")
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
                    .font(.title3).foregroundStyle(.secondary).frame(width: 24, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.name).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("Processes") + ": \(row.processCount)").font(.caption).foregroundStyle(.secondary)
                    if row.energyProcessCount < row.processCount || row.cpuProcessCount < row.processCount {
                        Text(L10n.text("Partial process coverage")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    if let watts = row.cpuPowerWatts {
                        Text("≈ " + number(watts, places: 3) + " W CPU").font(.body.weight(.medium))
                        Text(row.cpuPercent.map { number($0, places: 1) + "% CPU" } ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(row.cpuPercent.map { number($0, places: 1) + "% CPU" } ?? "—").font(.body.weight(.medium))
                    }
                }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
            }.padding(.vertical, 3)
        }.help(L10n.text("CPU power is an interval estimate from macOS CPU energy counters, not total app or battery consumption."))
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
