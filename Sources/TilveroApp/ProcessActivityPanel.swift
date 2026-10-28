import SwiftUI
import AppKit
import PowerTelemetry

@MainActor struct ProcessActivityPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    var allowsNavigation = true
    var body: some View {
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
