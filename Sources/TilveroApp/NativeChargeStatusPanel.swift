import SwiftUI

@MainActor struct NativeChargeStatusPanel: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let observed = model.nativeCharge.observed {
                Text(L10n.text(model.nativeCharge.recoveryRequired ? "Last confirmed macOS limit" : "macOS charge limit") + ": " + (observed.configuration.enabled ? "\(observed.configuration.target)%" : L10n.text("System managed")))
                    .font(.caption).monospacedDigit()
                Text(L10n.text("Changes here use the same native limit as macOS Battery settings."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.nativeCharge.observed == nil, let setting = model.nativeCharge.nativeSetting, setting.isFresh {
                Text(L10n.text("Native macOS setting") + ": " + (setting.configuration.enabled ? "\(setting.configuration.target)%" : L10n.text("System managed")))
                    .font(.caption).monospacedDigit()
                Text(L10n.text("The native setting is readable, but the active policy is unconfirmed. Connect power and refresh before validation or applying."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.nativeCharge.admitted {
                Text(L10n.text("Native control needs one local setting-and-restoration check."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Validate native control…")) { model.qualifyNativeCharge() }
                    .disabled(model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.recoveryRequired)
            }
            if let message = model.nativeCharge.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(model.nativeCharge.recoveryRequired ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.nativeCharge.admitted && !model.nativeCharge.canChargeToFullOnce {
                Text(L10n.text("One-time full charging awaits a separate completion and cancellation check."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.nativeCharge.restorationPending {
                Text(L10n.text("Keep Tilvero open and let the battery discharge naturally before restoring the previous limit."))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.nativeCharge.recoveryRequired || model.nativeCharge.restorationPending {
                Button(L10n.text("Restore previous macOS limit")) { model.releaseControl() }
                    .disabled(model.isApplying || model.nativeCharge.isBusy)
            }
        }
    }
}
