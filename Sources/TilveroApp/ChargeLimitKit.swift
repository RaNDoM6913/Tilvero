// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// The charge-limit editor shared by the quick menu's Charge page and the window's Charging page: one set of rules and
/// one set of pieces (slider over the verified levels that applies on release, validation entry, one-time full charge,
/// info text), laid out by each surface. Both surfaces read and write the same model state, so they always agree.
enum ChargeLimitKit {
    /// What the limit tile offers.
    enum Mode: Equatable, Sendable {
        /// Slider over the verified levels.
        case slider
        /// Native control found but not validated yet: «Проверить 80–100 %…» instead of the slider.
        case validate
        /// No native control, or monitoring only: the macOS limit as a read-only row.
        case readOnly
    }

    static func mode(isDemo: Bool, usesNativeCharge: Bool, canShowControls: Bool, hasTargets: Bool) -> Mode {
        if isDemo { return canShowControls && hasTargets ? .slider : .readOnly }
        guard usesNativeCharge else { return .readOnly }
        return canShowControls && hasTargets ? .slider : .validate
    }

    @MainActor static func mode(_ model: TilveroModel) -> Mode {
        mode(isDemo: model.isDemo, usesNativeCharge: model.usesNativeCharge,
             canShowControls: model.canShowChargeControls, hasTargets: !targets(model).isEmpty)
    }

    /// Levels the slider offers: the verified persistent targets (100 means no limit); the simulation's own in DEMO.
    @MainActor static func targets(_ model: TilveroModel) -> [Int] {
        model.isDemo ? model.acceptedTargets.sorted() : model.nativeCharge.authorizedPersistentTargets.sorted()
    }

    /// The limit macOS holds now (100 when the limit is off), nil until read.
    static func current(_ preference: NativeChargeConfiguration?) -> Int? {
        preference.map { $0.enabled ? $0.target : NativeChargeAdmission.unlimitedTarget }
    }

    /// The level the editor shows: the user's own choice while it is applied, else the model's draft, else macOS's.
    static func shown(chosen: Int?, draft: Int?, preference: NativeChargeConfiguration?) -> Int? {
        chosen ?? draft ?? current(preference)
    }

    @MainActor static func shown(chosen: Int?, model: TilveroModel) -> Int? {
        shown(chosen: chosen, draft: model.draftTarget,
              preference: model.isDemo ? nil : model.nativeCharge.presentation().currentPreference)
    }

    /// The shown level is the one macOS holds and nothing waits: only then is it drawn as applied (pending never is).
    static func isApplied(shown: Int?, current: Int?, pendingTarget: Int?) -> Bool {
        guard let shown, let current, pendingTarget == nil else { return false }
        return shown == current
    }

    /// «80 %» / "80%".
    static func percent(_ value: Int, language: String = L10n.language) -> String {
        language == "ru" ? "\(value) %" : "\(value)%"
    }

    /// The pending line: «Ожидает: 80 % после разряда ниже 80 %». Nil when nothing waits.
    static func pendingText(pendingTarget: Int?, language: String = L10n.language) -> String? {
        guard let pendingTarget else { return nil }
        let level = percent(pendingTarget, language: language)
        return L10n.text("Pending: {level} after discharging below {level}").replacingOccurrences(of: "{level}", with: level)
    }

    /// Validation needs macOS's own registry entry, which exists only while the Mac is plugged in; the limit itself
    /// works on battery power too once validated.
    static func needsPowerForValidation(admitted: Bool, onBattery: Bool) -> Bool { !admitted && onBattery }

    @MainActor static func onBattery(_ model: TilveroModel) -> Bool {
        model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.value == false
    }
    @MainActor static func actionsBlocked(_ model: TilveroModel) -> Bool {
        model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying
            || model.nativeCharge.presentation().pendingPurpose != nil
    }
    @MainActor static func canValidate(_ model: TilveroModel) -> Bool {
        !actionsBlocked(model) && model.nativeCharge.canRequestQualification
    }
    /// The native read or an apply is in flight (the spinner slot beside the value).
    @MainActor static func isWorking(_ model: TilveroModel, _ state: NativeChargePresentation) -> Bool {
        state.pendingPurpose != nil || model.isApplying
    }

    static let infoParagraphKeys = [
        "The same limit as macOS Battery settings: charging stops at the chosen level. Letting go of the slider applies it.",
        "A level below the current charge takes effect when the battery discharges to it.",
        "100% means no limit. Verified levels: 80%, 85%, 90%, 95% and 100%.",
        "Charge to 100% once lifts the limit until the battery is full or the adapter is unplugged, then your previous limit returns. Tap the button again to cancel.",
    ]
}

// MARK: Pieces

/// (i) beside the «Лимит зарядки» title.
@MainActor struct ChargeLimitInfoButton: View {
    var body: some View {
        SectionInfoButton(title: L10n.text("Charge limit"), paragraphs: ChargeLimitKit.infoParagraphKeys.map(L10n.text),
                          id: "charge-limit-info")
    }
}

/// Step slider over the verified levels with the level labels under its tick positions. Letting go applies the level
/// (there is no Apply button); keyboard and accessibility steps settle first. `chosen` holds what the slider shows from
/// the user's first movement until the apply is done, so a busy model never snaps it back.
@MainActor struct ChargeLimitLevelSlider: View {
    var model: TilveroModel
    let targets: [Int]
    @Binding var chosen: Int?
    var labelSize: CGFloat = 11
    @State private var dragging = false
    @State private var settle: Task<Void, Never>?

    var body: some View {
        let shown = ChargeLimitKit.shown(chosen: chosen, model: model)
        VStack(alignment: .leading, spacing: 8) {
            Slider(value: Binding(get: { sliderPosition(shown) }, set: { setSlider($0) }),
                   in: 0...Double(max(1, targets.count - 1)), step: 1,
                   onEditingChanged: { editing in
                       dragging = editing
                       if !editing { applySoon(after: .milliseconds(150)) }
                   })
                .accessibilityLabel(L10n.text("Charge limit"))
                .accessibilityValue(shown.map { "\($0)%" } ?? "")
                .accessibilityIdentifier("charge.slider")
            // Labels sit under the slider's own tick positions (the track runs between the thumb's end stops).
            GeometryReader { proxy in
                let inset: CGFloat = 10
                let step = targets.count > 1 ? (proxy.size.width - 2 * inset) / CGFloat(targets.count - 1) : 0
                // A dense simulated range (80…100 by one) labels every fifth level; the verified five are all labelled.
                ForEach(Array(targets.enumerated()).filter { targets.count <= 7 || $0.element % 5 == 0 }, id: \.offset) { index, target in
                    Text("\(target)").font(.system(size: labelSize, weight: shown == target ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(shown == target ? Color.primary : Color.secondary)
                        .fixedSize()
                        .position(x: inset + CGFloat(index) * step, y: 7)
                }
            }
            .frame(height: 14)
        }
        .onDisappear { settle?.cancel() }
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
            if model.canApply { model.applyDraftTarget() }
            // Release the local choice once the model shows the same level (or has refused it).
            for _ in 0..<60 {
                if !model.isApplying && !model.nativeCharge.isBusy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled, !dragging { chosen = nil }
        }
    }
}

/// «Проверить 80–100 %…»: the one validation flow both surfaces share (shown while not validated and not in recovery).
@MainActor struct ChargeLimitValidateButton: View {
    var model: TilveroModel
    var body: some View {
        if !model.nativeCharge.admitted && !model.nativeCharge.recoveryRequired {
            let enabled = ChargeLimitKit.canValidate(model)
            Button { model.qualifyNativeCharge() } label: {
                Text(L10n.text("Validate 80–100%…"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(enabled ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).disabled(!enabled)
            .help(L10n.text("Validation writes each of the other verified limits in turn and restores your setting, after a confirmed persistent baseline and a battery level below 80%."))
            .accessibilityIdentifier("action.validate-native-control")
            if ChargeLimitKit.needsPowerForValidation(admitted: model.nativeCharge.admitted, onBattery: ChargeLimitKit.onBattery(model)) {
                Text(L10n.text("Connect the charger for the one-time validation. After that the limit works on battery power too."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// «Зарядить до 100 % один раз»: grey to start, accent while it runs («Заряжается до 100 % · 86 %»); tapping it again
/// cancels. Present whenever the controls are (dimmed when it cannot start) so applying a limit never resizes the page.
@MainActor struct ChargeOncePill: View {
    var model: TilveroModel
    var fillsWidth = true
    var body: some View {
        let running = model.isChargeOnceRunning
        Button { if running { model.cancelChargeOnce() } else { model.startChargeOnce() } } label: {
            Text(running ? L10n.text("Charging to 100%") + (model.snapshot.chargePercent.value.map { " · \($0)%" } ?? "") : L10n.text("Charge to 100% once"))
                .font(running ? .system(.subheadline, design: .rounded).weight(.semibold) : .subheadline.weight(.medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: fillsWidth ? .infinity : nil).padding(.vertical, 7).padding(.horizontal, fillsWidth ? 0 : 14)
                .foregroundStyle(running ? Color.white : Color.primary)
                .background(Capsule().fill(running ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            // Steady look: a read or an apply in flight ignores taps but never dims the pill (it used to blink on every limit change).
            .steadyControl(SteadyControlLook(offered: running || model.chargeOnceOffered, busy: model.isApplying || model.nativeCharge.isBusy))
            .accessibilityLabel(L10n.text(running ? "Cancel one-time charge" : "Charge to 100% once"))
            .accessibilityAddTraits(running ? .isSelected : [])
    }
}
