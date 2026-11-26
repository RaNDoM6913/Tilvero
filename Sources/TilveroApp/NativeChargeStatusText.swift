// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// The one status line of the native charge limit (quick panel, Charging page, Diagnostics, the older window): pure, so
/// every surface and test reads the same words. Nil when there is nothing to say.
enum NativeChargeStatusText {
    struct Inputs: Equatable {
        /// macOS lists two different manual limits (seen after a macOS update).
        var registryConflict = false
        /// The service's last explanation (a read failure, a timeout).
        var message: String?
        /// An incomplete read whose current target is still readable.
        var partialRead = false
        /// A native call of the service is running.
        var busy = false
    }

    static let partialReadWarning = "The current target is readable. Safe control and restoration are not yet confirmed for this charging mode."

    /// `compact`: the quick panel and the Charging page, where a read of a known setting has its own spinner slot.
    static func text(_ state: NativeChargePresentation, _ input: Inputs, compact: Bool = true) -> String? {
        switch state.attention {
        case .mutationUnresolved:
            return input.registryConflict ? NativeChargeService.registryConflictMessage : "macOS has not confirmed the last change yet."
        case .journalIntegrity: return "The native session journal needs review before further changes."
        case .operationPending:
            // A pending operation speaks only once it has passed its deadline (the spinner covers the ordinary case).
            if state.pendingTimedOut {
                return state.pendingPurpose == .read
                    ? "The native policy read timed out. Further actions wait for the read to return."
                    : "The native setting operation timed out. Its outcome needs review; further writes are blocked."
            }
            guard state.pendingPurpose == .read else { return "Waiting for the native charging operation…" }
            if compact && !input.busy, let message = input.message { return message }
            // The same reported target stays visible while a read is pending: so does its warning.
            if compact && input.partialRead { return partialReadWarning }
            return compact && state.currentPreference != nil ? nil : "Reading the native charge policy…"
        case .policyUnconfirmed:
            if input.registryConflict { return NativeChargeService.registryConflictMessage }
            if input.partialRead { return partialReadWarning }
            // A fresh stored setting is shown as it is; only when nothing fresh was read is there something to say.
            return state.currentPreference == nil ? input.message ?? "Active charge policy is unconfirmed" : nil
        case .none: return nil
        }
    }

    @MainActor static func inputs(_ native: NativeChargeService) -> Inputs {
        .init(registryConflict: native.nativeSetting?.registryConflict == true, message: native.message,
              partialRead: native.incompleteObservation != nil && native.currentReportedTarget != nil, busy: native.isBusy)
    }

    @MainActor static func text(_ state: NativeChargePresentation, model: TilveroModel, compact: Bool = true) -> String? {
        text(state, inputs(model.nativeCharge), compact: compact)
    }

    /// Orange for what needs a look (a session file that could not be handled, an overdue operation), grey otherwise.
    static func isWarning(_ state: NativeChargePresentation) -> Bool { state.requiresGlobalAttention || state.pendingTimedOut }
}

/// The native limit as read-only rows (what macOS stores, the diagnostic saved target of an unrecognised state) plus the
/// status line, for the older window and the legacy charge control. Changing the limit happens on the Charge page.
@MainActor struct NativeChargeReadOnlyRows: View {
    var model: TilveroModel
    var compact = false
    var body: some View {
        let native = model.nativeCharge
        let state = native.presentation()
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            if let preference = state.currentPreference {
                HStack(spacing: 8) {
                    StudioText(L10n.text("Native macOS setting") + ": " + (ChargeLimitKit.text(preference) ?? "—"), id: "native.setting")
                        .font(compact ? .subheadline : .caption).monospacedDigit()
                    if compact {
                        Spacer(minLength: 0)
                        // A refresh of a known setting belongs to this row: a fixed slot while the read comes and goes.
                        ZStack {
                            if state.pendingPurpose == .read {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel(L10n.text("Reading the native charge policy…"))
                            }
                        }.frame(width: 12, height: 12)
                    }
                }
            } else if let target = native.currentReportedTarget {
                StudioText(L10n.text("Current target reported by macOS") + ": \(target)%", id: "native.reportedTarget")
                    .font(.subheadline).monospacedDigit()
            }
            if let stored = native.diagnosticStoredTarget {
                StudioText(L10n.text("Saved target reported by macOS") + ": \(stored)%", id: "native.diagnosticStoredTarget")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("This diagnostic value is not a confirmed active limit; its source freshness is unknown."))
                Button(L10n.text("Charging settings in macOS…")) { model.openBatterySettings() }
            }
            if let status = NativeChargeStatusText.text(state, model: model, compact: compact) {
                StudioText(L10n.text(status), id: "native.status").font(.caption)
                    .foregroundStyle(NativeChargeStatusText.isWarning(state) ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.studioElement("native.statusPanel", kind: "container", label: "Native charging status")
    }
}
