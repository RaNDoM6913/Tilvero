import SwiftUI
import ChargeBackends

@MainActor struct NativeChargeStatusPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    @State private var showsDetails = false
    var body: some View {
        let state = model.nativeCharge.presentation()
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            if let preference = state.currentPreference {
                HStack(spacing: 8) {
                    StudioText(L10n.text("Native macOS setting") + ": " + configurationText(preference), id: "native.setting")
                        .font(compact ? .subheadline : .caption).monospacedDigit()
                    if compact {
                        Spacer(minLength: 0)
                        // A refresh of a known setting belongs to this row. Keep
                        // its slot stable while the native read comes and goes.
                        ZStack {
                            if state.pendingPurpose == .read {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel(L10n.text("Reading the native charge policy…"))
                            }
                        }.frame(width: 12, height: 12)
                    }
                }
            } else if let target = model.nativeCharge.currentReportedTarget {
                StudioText(L10n.text("Current target reported by macOS") + ": \(target)%", id: "native.reportedTarget")
                    .font(.subheadline).monospacedDigit()
            }
            if let stored = model.nativeCharge.diagnosticStoredTarget {
                StudioText(L10n.text("Saved target reported by macOS") + ": \(stored)%", id: "native.diagnosticStoredTarget")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("This diagnostic value is not a confirmed active limit; its source freshness is unknown."))
                Text(L10n.text("The return time is unavailable here. Check the charging mode in macOS settings."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Charging settings in macOS…")) { model.openBatterySettings() }
            }
            if let status = statusText(state) {
                StudioText(L10n.text(status), id: "native.status").font(.caption)
                    .foregroundStyle(state.requiresGlobalAttention ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let target = state.pendingTarget ?? state.restorationTarget {
                StudioText(L10n.text(state.pendingTarget == nil ? "Restoration pending" : "Pending charging target")
                     + " · " + L10n.text("Waiting for discharge below") + " \(target)%", id: "native.pending")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("Lower targets wait for natural discharge."))
            }
            if compact {
                StudioText(model.chargingStateText, id: "native.chargingState").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                StudioActionButton(L10n.text("Refresh"), id: "action.refresh") { Task { await model.refreshNativeCharge() } }
                    .disabled(actionsBlocked)
                if !model.nativeCharge.admitted && !model.nativeCharge.recoveryRequired {
                    StudioActionButton(L10n.text("Validate 80–95%…"), id: "action.validate-native-control") { model.qualifyNativeCharge() }
                        .disabled(actionsBlocked || !model.nativeCharge.canRequestQualification)
                        .help(L10n.text("Validation writes 80%, 85%, 90% and 95% in turn and restores your setting, after a confirmed persistent baseline and a battery level below 80%."))
                }
            }
            if model.nativeCharge.interfaceWasDiscovered && !model.nativeCharge.admitted {
                Text(L10n.text("Native control must be validated on this macOS version before Apply is available."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.nativeCharge.admitted && model.nativeCharge.authorizedPersistentTargets == NativeChargeAdmission.persistentTargets {
                Text(L10n.text("Verified persistent limits: 80%, 85%, 90% and 95%. Other targets and one-time full charging need separate validation."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Recovery is an explicit existing action, never a consequence of
            // merely displaying a readable preference or this status panel.
            if !compact && (state.hasOwnership || model.nativeCharge.recoveryRequired || model.nativeCharge.restorationPending) {
                StudioActionButton(L10n.text("Restore previous macOS limit"), id: "action.restore-previous-macos-limit") { model.releaseControl() }
                    .disabled(actionsBlocked)
            }
            if !compact {
                DisclosureGroup(L10n.text("Details"), isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let policy = state.activePolicy {
                            Text(L10n.text("Confirmed active policy") + ": " + configurationText(policy))
                        } else {
                            Text(L10n.text("Active charge policy is unconfirmed"))
                        }
                        if let explanation = explanationText(state) {
                            Text(L10n.text(explanation))
                        }
                        if let message = model.nativeCharge.message {
                            Text(L10n.text(message))
                        }
                        Text(L10n.text("Changes here use the same native limit as macOS Battery settings."))
                        if model.nativeCharge.admitted && !model.nativeCharge.canChargeToFullOnce {
                            Text(L10n.text("One-time full charging awaits a separate completion and cancellation check."))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }.studioElement("native.statusPanel", kind: "container", label: "Native charging status")
    }
    private var actionsBlocked: Bool {
        model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying
            || model.nativeCharge.presentation().pendingPurpose != nil
    }
    private func configurationText(_ configuration: NativeChargeConfiguration) -> String {
        configuration.enabled ? "\(configuration.target)%" : L10n.text("System managed")
    }
    func statusText(_ state: NativeChargePresentation) -> String? {
        switch state.attention {
        case .sessionReview: "Saved charging session needs review."
        case .mutationUnresolved: "A dispatched native setting still has an unconfirmed outcome."
        case .journalIntegrity: "The native session journal needs review before further changes."
        case .operationPending:
            if state.pendingPurpose == .read {
                if compact && !model.nativeCharge.isBusy && !model.nativeCharge.isQualifying,
                   let message = model.nativeCharge.message {
                    message
                } else if compact && !model.nativeCharge.isQualifying, let partialPolicyWarning {
                    // The same reported target and diagnostic context remain visible
                    // while a read is pending. Keep their policy warning in place.
                    partialPolicyWarning
                } else {
                    compact && state.currentPreference != nil ? nil : "Reading the native charge policy…"
                }
            } else {
                "Waiting for the native charging operation…"
            }
        case .restorationPending:
            state.restorationTarget == nil ? "Restoring the previous setting is waiting for natural discharge." : nil
        case .lowerTargetPending:
            state.pendingTarget == nil ? "The lower target is waiting for natural discharge." : nil
        case .policyUnconfirmed:
            partialPolicyWarning ?? (model.nativeCharge.nativeSetting == nil
                ? model.nativeCharge.message ?? "Active charge policy is unconfirmed"
                : "Active charge policy is unconfirmed")
        case .none: nil
        }
    }
    private var partialPolicyWarning: String? {
        guard model.nativeCharge.incompleteObservation != nil,
              model.nativeCharge.currentReportedTarget != nil else { return nil }
        return "The current target is readable. Safe control and restoration are not yet confirmed for this charging mode."
    }
    private func explanationText(_ state: NativeChargePresentation) -> String? {
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
