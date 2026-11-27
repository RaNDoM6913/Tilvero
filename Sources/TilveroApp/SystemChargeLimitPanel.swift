// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// A read-only view of system policy. Changing it is an explicit action in Apple's UI.
@MainActor struct SystemChargeLimitPanel: View {
    var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits {
                let native = model.isDemo ? nil : model.nativeCharge.nativeSetting.flatMap { $0.isFresh ? $0.configuration : nil }
                // The same value the window's read-only row shows: the native setting, else a registry row read on AC.
                LabeledContent(L10n.text("macOS charge limit"), value: Self.headline(native: native, observation: observation))
                    .font(.headline).accessibilityElement(children: .combine)
                if native == nil, observation.readOnExternalPower == true {
                    if limits.manualLimitIsConflicting { Text(L10n.text("Conflicting manual limits reported")) }
                    else if limits.manualLimit == nil { Text(L10n.text("No manual limit registered")) }
                }
                if let row = Self.unconfirmedRow(observation) {
                    // On battery power macOS keeps listing old rows for minutes: shown as what it is, never as the limit.
                    Text(L10n.text("Listed by macOS: {level}. On battery power this list may be out of date.")
                        .replacingOccurrences(of: "{level}", with: ChargeLimitKit.percent(row)))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Button(L10n.text("Refresh")) { Task { await model.refreshSystemChargeLimit(reusingRecent: false) } }
                    .disabled(model.isReadingSystemChargeLimit)
            }
            Text(L10n.text("Registered requests do not prove an exact cutoff. macOS may occasionally charge to 100% for calibration."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.task { await model.refreshSystemChargeLimit(reusingRecent: false) }   // the page opening is an explicit read too
    }

    /// The headline, built as the Charging page's read-only row: the fresh native setting (100 % when the limit is off),
    /// else the registered manual row read on AC (evidence only then), else «—».
    static func headline(native: NativeChargeConfiguration?, observation: SystemChargeLimitObservation,
                         language: String = L10n.language) -> String {
        ChargingComposition.macOSLimitText(native: native, systemManual: observation.evidentManualLimit(), language: language)
    }

    /// The raw registered row when it is not evidence of the limit (read on battery power, or with the power state
    /// unknown): a secondary caption only.
    static func unconfirmedRow(_ observation: SystemChargeLimitObservation) -> Int? {
        observation.readOnExternalPower == true ? nil : observation.limits?.manualLimit
    }
}
