// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// The quick panel's Charge page for the native macOS charge limit: the chosen level beside the title and the shared
/// `ChargeLimitKit` slider over the verified targets (100 means "no limit"). Letting go of the slider applies the
/// level; there is no Apply button. Explanations live in the info popover; other lines appear only when there is
/// something to say. The window's Charging page lays out the same editor pieces.
@MainActor struct QuickNativeChargePanel: View {
    var model: TilveroModel
    /// What the slider shows from the user's first movement until the apply is done, so a busy model never snaps it back.
    @State private var chosen: Int?

    private var targets: [Int] { ChargeLimitKit.targets(model) }

    var body: some View {
        let _ = RenderProbe.hit("QuickNativeChargePanel")
        let state = model.nativeCharge.presentation()
        VStack(alignment: .leading, spacing: 14) {
            if model.canShowChargeControls, !targets.isEmpty { controls(state) } else { validationHeader(state) }
            attention(state)
            footer(state)
            if model.canShowChargeControls, model.optimizedCharging.isAvailable {
                Divider()
                OptimizedChargingRow(service: model.optimizedCharging, showsHold: false)
            }
            ChargeByBlock(model: model, service: model.chargeBy)
        }
        .studioElement("charge.editor", kind: "container", label: "Charge limit editor")
        .task { await model.refreshNativeChargeIfStale() }
    }

    // MARK: Title row

    private func title(value: Int?, state: NativeChargePresentation) -> some View {
        HStack(spacing: 6) {
            StudioText(L10n.text("Charge limit"), id: "charge.title").font(.system(size: 14, weight: .semibold)).fixedSize()
            ChargeLimitInfoButton()
            Spacer(minLength: 8)
            // A fixed slot: a native read or an apply comes and goes without moving the row.
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                .opacity(ChargeLimitKit.isWorking(model, state) ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: ChargeLimitKit.isWorking(model, state))
                .accessibilityHidden(true)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    StudioText("\(value)", id: "charge.readout")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(width: 58, alignment: .trailing)   // 80 and 100 take the same room: nothing beside it moves
            }
        }
        .frame(height: 30)
    }

    // MARK: Limit controls (the shared editor's slider)

    private func controls(_ state: NativeChargePresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title(value: ChargeLimitKit.shown(chosen: chosen, model: model), state: state)
            ChargeLimitLevelSlider(model: model, targets: targets, chosen: $chosen)
                .studioElement("charge.slider", label: "Charge limit slider")
        }
    }

    // MARK: Not validated yet

    @ViewBuilder private func validationHeader(_ state: NativeChargePresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title(value: nil, state: state)
            ChargeLimitValidateButton(model: model)
                .studioElement("action.validate-native-control", label: "Validate 80–100%")
        }
    }
    /// Validation needs macOS's own registry entry, which exists only while the Mac is plugged in.
    static func needsPowerForValidation(admitted: Bool, onBattery: Bool) -> Bool {
        ChargeLimitKit.needsPowerForValidation(admitted: admitted, onBattery: onBattery)
    }

    // MARK: Only when there is something to say

    @ViewBuilder private func attention(_ state: NativeChargePresentation) -> some View {
        // A waiting limit has no line of its own: moving the slider back to the limit macOS holds cancels the wait.
        // While an operation is pending the spinner is the only sign (no text that appears and vanishes).
        if state.attention != .operationPending, let status = NativeChargeStatusPanel(model: model, compact: true).statusText(state) {
            StudioText(L10n.text(status), id: "native.status").font(.caption)
                .foregroundStyle(state.requiresGlobalAttention ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = model.notices.current(excluding: [.chargeStatus])?.text, message != model.nativeCharge.message.map(L10n.text) {
            Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func footer(_ state: NativeChargePresentation) -> some View {
        // Always present with the controls (dimmed when it cannot start) so applying a limit never resizes the page.
        if model.canShowChargeControls {
            ChargeOncePill(model: model)
                .studioElement("charge.once", label: model.isChargeOnceRunning ? "Cancel one-time charge" : "Charge to 100% once")
        }
    }
}
// tlv-origin:ef476f6f9470fa55
