// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// The quick panel's Charge page for the native macOS charge limit: the chosen level beside the title and a step
/// slider over the verified targets (100 means "no limit"). Letting go of the slider applies the level; there is
/// no Apply button. Explanations live in the info popover; other lines appear only when there is something to say.
@MainActor struct QuickNativeChargePanel: View {
    @ObservedObject var model: TilveroModel
    @State private var dragging = false
    @State private var settle: Task<Void, Never>?
    /// What the slider shows from the user's first movement until the apply is done, so a busy model never snaps it back.
    @State private var chosen: Int?

    private var targets: [Int] { model.nativeCharge.authorizedPersistentTargets.sorted() }

    var body: some View {
        let state = model.nativeCharge.presentation()
        VStack(alignment: .leading, spacing: 14) {
            if model.canShowChargeControls, !targets.isEmpty { controls(state) } else { validationHeader(state) }
            attention(state)
            footer(state)
            ChargeByBlock(model: model, service: model.chargeBy)
        }
        .studioElement("charge.editor", kind: "container", label: "Charge limit editor")
        .task { await model.refreshNativeChargeIfStale() }
        .onDisappear { settle?.cancel() }
    }

    // MARK: Title row

    private func title(value: Int?, state: NativeChargePresentation) -> some View {
        HStack(spacing: 6) {
            StudioText(L10n.text("Charge limit"), id: "charge.title").font(.system(size: 14, weight: .semibold)).fixedSize()
            SectionInfoButton(title: L10n.text("Charge limit"), paragraphs: [
                L10n.text("The same limit as macOS Battery settings: charging stops at the chosen level. Letting go of the slider applies it."),
                L10n.text("A level below the current charge takes effect when the battery discharges to it."),
                L10n.text("100% means no limit. Verified levels: 80%, 85%, 90%, 95% and 100%."),
                L10n.text("Charge to 100% once lifts the limit until the battery is full or the adapter is unplugged, then your previous limit returns. Tap the button again to cancel."),
            ], id: "charge-limit-info")
            Spacer(minLength: 8)
            // A fixed slot: a native read or an apply comes and goes without moving the row.
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                .opacity(state.pendingPurpose != nil || model.isApplying ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: state.pendingPurpose != nil || model.isApplying)
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

    // MARK: Limit controls

    private func controls(_ state: NativeChargePresentation) -> some View {
        let shown = chosen ?? model.draftTarget ?? state.currentPreference.map { $0.enabled ? $0.target : NativeChargeAdmission.unlimitedTarget }
        return VStack(alignment: .leading, spacing: 8) {
            title(value: shown, state: state)
            Slider(value: Binding(get: { sliderPosition(shown) }, set: { setSlider($0) }),
                   in: 0...Double(max(1, targets.count - 1)), step: 1,
                   onEditingChanged: { editing in
                       dragging = editing
                       if !editing { applySoon(after: .milliseconds(150)) }
                   })
                .accessibilityLabel(L10n.text("Charge limit"))
                .accessibilityValue(shown.map { "\($0)%" } ?? "")
                .accessibilityIdentifier("charge.slider")
                .studioElement("charge.slider", label: "Charge limit slider")
            // Labels sit under the slider's own tick positions (the track runs between the thumb's end stops).
            GeometryReader { proxy in
                let inset: CGFloat = 10
                let step = targets.count > 1 ? (proxy.size.width - 2 * inset) / CGFloat(targets.count - 1) : 0
                ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                    Text("\(target)").font(.system(size: 11, weight: shown == target ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(shown == target ? Color.primary : Color.secondary)
                        .fixedSize()
                        .position(x: inset + CGFloat(index) * step, y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    private func sliderPosition(_ shown: Int?) -> Double {
        Double(targets.firstIndex(of: shown ?? targets.first ?? 80) ?? 0)
    }
    /// Only the user's own slider movement reaches this point, so only it can lead to a write.
    private func setSlider(_ value: Double) {
        guard value.isFinite, !targets.isEmpty else { return }
        let target = targets[min(targets.count - 1, max(0, Int(value.rounded())))]
        chosen = target
        model.setDraft(target)
        if !dragging { applySoon(after: .milliseconds(800)) }   // keyboard and accessibility steps settle first
    }
    private func applySoon(after delay: Duration) {
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // A busy model (a read or an earlier apply) is waited for, not fought: the choice is applied once it is free.
            for _ in 0..<40 {
                guard !Task.isCancelled, !dragging else { return }
                if !model.isApplying && !model.nativeCharge.isBusy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, !dragging, let target = chosen else { return }
            model.setDraft(target)
            if model.canApply { model.applyDemoTarget() }
            // Release the local choice once the model shows the same level (or has refused it).
            for _ in 0..<60 {
                if !model.isApplying && !model.nativeCharge.isBusy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled, !dragging { chosen = nil }
        }
    }

    // MARK: Not validated yet

    @ViewBuilder private func validationHeader(_ state: NativeChargePresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title(value: nil, state: state)
            if !model.nativeCharge.admitted && !model.nativeCharge.recoveryRequired {
                Button { model.qualifyNativeCharge() } label: {
                    StudioText(L10n.text("Validate 80–100%…"), id: "action.validate-native-control.caption")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canValidate ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(canValidate ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!canValidate)
                .help(L10n.text("Validation writes 80%, 85%, 95% and 100% in turn and restores your setting, after a confirmed persistent baseline and a battery level below 80%."))
                .accessibilityIdentifier("action.validate-native-control")
                .studioElement("action.validate-native-control", label: "Validate 80–100%")
                if Self.needsPowerForValidation(admitted: model.nativeCharge.admitted, onBattery: onBattery) {
                    Text(L10n.text("Connect the charger for the one-time validation. After that the limit works on battery power too."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    /// Validation needs macOS's own registry entry, which exists only while the Mac is plugged in; the limit itself
    /// works on battery power too once validated.
    static func needsPowerForValidation(admitted: Bool, onBattery: Bool) -> Bool { !admitted && onBattery }
    private var onBattery: Bool {
        model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.value == false
    }
    private var canValidate: Bool { !actionsBlocked && model.nativeCharge.canRequestQualification }
    private var actionsBlocked: Bool {
        model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying
            || model.nativeCharge.presentation().pendingPurpose != nil
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
        if let message = model.notice, model.notice != model.nativeCharge.message.map(L10n.text) {
            Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func footer(_ state: NativeChargePresentation) -> some View {
        // Always present with the controls (dimmed when it cannot start) so applying a limit never resizes the page.
        if model.canShowChargeControls {
            let running = model.isChargeOnceRunning
            // The app's pill: grey to start, accent while it runs; tapping it again cancels.
            Button { if running { model.cancelChargeOnce() } else { model.startChargeOnce() } } label: {
                StudioText(running ? L10n.text("Charging to 100%") + (model.snapshot.chargePercent.value.map { " · \($0)%" } ?? "") : L10n.text("Charge to 100% once"), id: "charge.once.caption")
                    .font(running ? .system(.subheadline, design: .rounded).weight(.semibold) : .subheadline.weight(.medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(running ? Color.white : Color.primary)
                    .background(Capsule().fill(running ? Color.accentColor : Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
            }.buttonStyle(.plain)
                // Steady look: a read or an apply in flight ignores taps but never dims the pill (it used to blink on every limit change).
                .steadyControl(SteadyControlLook(offered: running || model.chargeOnceOffered, busy: model.isApplying || model.nativeCharge.isBusy))
                .accessibilityLabel(L10n.text(running ? "Cancel one-time charge" : "Charge to 100% once"))
                .accessibilityAddTraits(running ? .isSelected : [])
                .studioElement("charge.once", label: running ? "Cancel one-time charge" : "Charge to 100% once")
        }
    }
}
// tlv-origin:ef476f6f9470fa55
