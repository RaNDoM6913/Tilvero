import SwiftUI
import ChargeBackends

@MainActor struct NativeChargeStatusPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    var body: some View {
        let state = model.nativeCharge.presentation()
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            if let preference = state.currentPreference {
                Text(L10n.text("Native macOS setting") + ": " + configurationText(preference))
                    .font(compact ? .subheadline : .caption).monospacedDigit()
            }
            if let policy = state.activePolicy {
                Text(L10n.text("Confirmed active policy") + ": " + configurationText(policy))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Active charge policy is unconfirmed"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = statusText(state) {
                Text(L10n.text(status)).font(.caption)
                    .foregroundStyle(state.requiresGlobalAttention ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target = state.pendingTarget ?? state.restorationTarget {
                Text(L10n.text("Waiting for discharge below") + " \(target)%")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("Lower targets wait for natural discharge."))
            }
            if compact {
                Text(model.chargingStateText).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Changes here use the same native limit as macOS Battery settings."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.nativeCharge.message {
                    Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.nativeCharge.admitted && !model.nativeCharge.canChargeToFullOnce {
                    Text(L10n.text("One-time full charging awaits a separate completion and cancellation check."))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(L10n.text("Refresh")) { Task { await model.refreshNativeCharge() } }
                    .disabled(actionsBlocked)
                if !model.nativeCharge.admitted && !model.nativeCharge.recoveryRequired {
                    Button(L10n.text("Validate native control…")) { model.qualifyNativeCharge() }
                        .disabled(actionsBlocked)
                        .help(L10n.text("Native control needs one local setting-and-restoration check."))
                }
            }
            // Recovery is an explicit existing action, never a consequence of
            // merely displaying a readable preference or this status panel.
            if !compact && (state.hasOwnership || model.nativeCharge.recoveryRequired || model.nativeCharge.restorationPending) {
                Button(L10n.text("Restore previous macOS limit")) { model.releaseControl() }
                    .disabled(actionsBlocked)
            }
        }.help(model.nativeCharge.message.map(L10n.text) ?? "")
    }
    private var actionsBlocked: Bool {
        model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying
            || model.nativeCharge.presentation().pendingPurpose != nil
    }
    private func configurationText(_ configuration: NativeChargeConfiguration) -> String {
        configuration.enabled ? "\(configuration.target)%" : L10n.text("System managed")
    }
    private func statusText(_ state: NativeChargePresentation) -> String? {
        switch state.attention {
        case .sessionReview: "The native charge session needs review. A readable setting does not resolve its saved state."
        case .mutationUnresolved: "A dispatched native setting still has an unconfirmed outcome."
        case .journalIntegrity: "The native session journal needs review before further changes."
        case .operationPending:
            state.pendingPurpose == .read ? "Reading the native charge policy…" : "Waiting for the native charging operation…"
        case .restorationPending: "Restoring the previous setting is waiting for natural discharge."
        case .lowerTargetPending: "The lower target is waiting for natural discharge."
        case .policyUnconfirmed: "Refresh to check the active policy. The readable native setting is shown separately."
        case .none: state.hasOwnership ? "Tilvero manages this native setting." : nil
        }
    }
}
