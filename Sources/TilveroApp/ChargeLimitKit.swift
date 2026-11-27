// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ChargeBackends

/// The charge-limit editor shared by the quick menu's Charge page and the window's Charging page: one set of rules and
/// one set of pieces (slider over the levels macOS offers that applies on release, one-time full charge, info text), laid
/// out by each surface. Both surfaces read and write the same model state, so they always agree.
enum ChargeLimitKit {
    /// What the limit tile offers.
    enum Mode: Equatable, Sendable {
        /// Slider over the levels macOS offers.
        case slider
        /// Native control found, but its state is not changeable by Tilvero right now: the reported value, read-only.
        case unavailable
        /// No native control, or monitoring only: the macOS limit as a read-only row.
        case readOnly
    }

    static func mode(isDemo: Bool, usesNativeCharge: Bool, canShowControls: Bool, hasTargets: Bool) -> Mode {
        if isDemo { return canShowControls && hasTargets ? .slider : .readOnly }
        guard usesNativeCharge else { return .readOnly }
        return canShowControls && hasTargets ? .slider : .unavailable
    }

    /// A fresh state macOS reports but Tilvero does not change (its temporary charge to full: disabled with a target) is
    /// shown read-only, as it is before the interface was granted; the slider returns once macOS reports a valid state.
    @MainActor static func mode(_ model: TilveroModel) -> Mode {
        let preference = model.nativeCharge.presentation().currentPreference
        let validState = model.isDemo || preference.map(NativeChargeAdmission.isValidState) ?? true
        return mode(isDemo: model.isDemo, usesNativeCharge: model.usesNativeCharge,
                    canShowControls: model.canShowChargeControls && validState, hasTargets: !targets(model).isEmpty)
    }

    /// Charge once and charge by time act only where the slider does; in the read-only state they are not drawn at all
    /// (no dead controls), except while one of them runs, so its cancel stays reachable.
    @MainActor static func showsChargeOnce(_ model: TilveroModel) -> Bool {
        !model.isDemo && model.usesNativeCharge && (mode(model) == .slider || model.isChargeOnceRunning)
    }
    @MainActor static func showsChargeBy(_ model: TilveroModel, armed: Bool) -> Bool {
        !model.isDemo && model.usesNativeCharge && (mode(model) == .slider || armed)
    }

    /// Levels the slider offers: the verified persistent targets (100 means no limit); the simulation's own in DEMO.
    @MainActor static func targets(_ model: TilveroModel) -> [Int] {
        model.isDemo ? model.acceptedTargets.sorted() : model.nativeCharge.authorizedPersistentTargets.sorted()
    }

    /// The limit macOS holds now (100 when the limit is off), nil until read.
    static func current(_ preference: NativeChargeConfiguration?) -> Int? {
        preference.map { $0.enabled ? $0.target : NativeChargeAdmission.unlimitedTarget }
    }

    /// The one formatter of the macOS limit: «80 %», «100 %» when the limit is off, nil when nothing fresh was read.
    static func text(_ preference: NativeChargeConfiguration?, language: String = L10n.language) -> String? {
        current(preference).map { percent($0, language: language) }
    }

    /// What macOS reports, for the read-only header: the fresh setting, else the readable current target of an
    /// incomplete read; nil when nothing was read.
    @MainActor static func reported(_ model: TilveroModel) -> Int? {
        current(model.nativeCharge.presentation().currentPreference) ?? model.nativeCharge.currentReportedTarget
    }

    /// The level the editor shows (simulation): the user's own choice while it is applied, else the draft, else the value.
    static func shown(chosen: Int?, draft: Int?, preference: NativeChargeConfiguration?) -> Int? {
        chosen ?? draft ?? current(preference)
    }

    /// The level the editor shows. Native: the slider's own in-progress choice, else what macOS reports (off = 100), else
    /// nothing; never the model's draft or a journal's last value. DEMO keeps its draft.
    @MainActor static func shown(chosen: Int?, model: TilveroModel) -> Int? {
        if model.isDemo { return shown(chosen: chosen, draft: model.draftTarget, preference: nil) }
        return chosen ?? current(model.nativeCharge.presentation().currentPreference)
    }

    /// The slider looks offered while macOS offers its levels and the current value is known and valid; momentary states (a
    /// read or an apply in flight) never dim it. The thumb is never drawn at a guessed level. Only an apply in flight
    /// ignores input: a background poll (a few milliseconds of `isBusy`) must never cut a drag short.
    @MainActor static func sliderLook(_ model: TilveroModel, targets: [Int]) -> SteadyControlLook {
        let preference = model.nativeCharge.presentation().currentPreference
        return SteadyControlLook(offered: model.isDemo || (targets.contains(where: model.nativeCharge.offersTarget)
                                                           && preference.map(NativeChargeAdmission.isValidState) == true),
                                 busy: model.isApplying)
    }

    /// The shown level is the one held now and nothing waits (the simulation's pending lower target): only then is it drawn
    /// as applied.
    static func isApplied(shown: Int?, current: Int?, pendingTarget: Int?) -> Bool {
        guard let shown, let current, pendingTarget == nil else { return false }
        return shown == current
    }

    /// «80 %» / "80%".
    static func percent(_ value: Int, language: String = L10n.language) -> String {
        language == "ru" ? "\(value) %" : "\(value)%"
    }

    /// The simulation's pending line: «Ожидает: 80 % после разряда ниже 80 %». Nil when nothing waits (the native limit
    /// never waits: a level below the charge is set at once).
    static func pendingText(pendingTarget: Int?, language: String = L10n.language) -> String? {
        guard let pendingTarget else { return nil }
        let level = percent(pendingTarget, language: language)
        return L10n.text("Pending: {level} after discharging below {level}").replacingOccurrences(of: "{level}", with: level)
    }

    @MainActor static func onBattery(_ model: TilveroModel) -> Bool {
        model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.value == false
    }
    /// The Optimized Charging switch is independent of the limit: shown wherever the OBC state is known (never in DEMO).
    static func showsOptimizedSwitch(isDemo: Bool, optimizedAvailable: Bool) -> Bool { !isDemo && optimizedAvailable }
    /// The native read or an apply is in flight (the spinner slot beside the value).
    @MainActor static func isWorking(_ model: TilveroModel, _ state: NativeChargePresentation) -> Bool {
        state.pendingPurpose != nil || model.isApplying
    }

    static let infoParagraphKeys = [
        "The same limit as macOS Battery settings: charging stops at the chosen level. Letting go of the slider applies it.",
        "A level below the current charge is set at once, as in System Settings: charging stops until the battery is below it.",
        "100% means no limit. Levels: 80%, 85%, 90%, 95% and 100%, as in System Settings.",
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
            // Applied, or refused visibly: the thumb returns to what macOS reports with one short reason.
            model.releaseChargeLimit(at: target)
            // Release the local choice once the model shows the same level (or has refused it).
            for _ in 0..<60 {
                if !model.isApplying && !model.nativeCharge.isBusy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled, !dragging { chosen = nil }
        }
    }
}

/// The native limit is found but Tilvero cannot change it right now (macOS reports a state it does not recognise, or the
/// levels are not offered): one line pointing to System Settings, with the existing action. Quiet before the first read.
@MainActor struct ChargeLimitUnavailableNote: View {
    var model: TilveroModel
    var body: some View {
        let native = model.nativeCharge
        if !native.notReadYet || native.incompleteObservation != nil {
            Text(L10n.text("Use System Settings › Battery to change this limit."))
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("Charging settings in macOS…")) { model.openBatterySettings() }
                .accessibilityIdentifier("action.charging-settings")
        }
    }
}

/// «Зарядить до 100 % один раз»: grey to start, accent while it runs («Заряжается до 100 % · 86 %»); tapping it again
/// cancels. Present with the slider (dimmed when it cannot start) so applying a limit never resizes the page; not drawn in
/// the read-only state unless it runs (`ChargeLimitKit.showsChargeOnce`).
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
