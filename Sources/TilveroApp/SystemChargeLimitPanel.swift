import SwiftUI
import ChargeBackends

/// A read-only view of system policy. Changing it is an explicit action in Apple's UI.
@MainActor struct SystemChargeLimitPanel: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits {
                if let manual = limits.manualLimit {
                    LabeledContent(L10n.text("macOS charge limit"), value: "\(manual)%")
                        .font(.headline).accessibilityElement(children: .combine)
                } else {
                    Text(L10n.text(limits.manualLimitIsConflicting ? "Conflicting manual limits reported" : "No manual limit registered"))
                }
                if !limits.otherLimits.isEmpty {
                    Text(L10n.text("Other system requests") + ": " + limits.otherLimits.map { "\($0)%" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("Read from macOS") + " · " + observation.collectedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(SystemChargeLimitObservation.source)
            } else {
                Text(L10n.text(model.isReadingSystemChargeLimit ? "Reading macOS charge limit…" : "macOS charge limit unavailable or stale"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(L10n.text("Set 80–100% in Battery → Charging ⓘ → Charge Limit. macOS manages this setting independently of Tilvero."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Change in macOS…")) { model.openBatterySettings() }
                    .buttonStyle(.borderedProminent)
                Button(L10n.text("Refresh")) { Task { await model.refreshSystemChargeLimit() } }
                    .disabled(model.isReadingSystemChargeLimit)
            }
            Text(L10n.text("Registered requests do not prove an exact cutoff. macOS may occasionally charge to 100% for calibration."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task { await model.refreshSystemChargeLimit() }
    }
}
