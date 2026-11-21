// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

enum AwakePillRequest: Equatable {
    case duration(Int), until(Date), untilStopped
}
enum SleepPillSelection: Equatable {
    case preset(Int), custom, until, untilStopped
}
enum SleepPillConfirmation: Equatable {
    case endAwake(UInt32), endTimer(UUID?)
    var title: String {
        switch self {
        case .endAwake: L10n.text("End Keep Awake and start the sleep timer?")
        case .endTimer: L10n.text("Cancel the sleep timer and start Keep Awake?")
        }
    }
    var action: String {
        switch self {
        case .endAwake: L10n.text("End Keep Awake and start")
        case .endTimer: L10n.text("Cancel timer and start Keep Awake")
        }
    }
    var explanation: String {
        return L10n.text("Confirm switching the active sleep mode first.")
    }
}
enum SleepPillActionError: LocalizedError, Equatable {
    case blocked, invalidDuration, confirmation(SleepPillConfirmation)
    var errorDescription: String? {
        switch self {
        case .blocked: L10n.language == "ru" ? "Сейчас сеанс нельзя изменить. Проверьте его состояние." : "This session cannot be changed now. Check its state."
        case .invalidDuration: L10n.text("Enter 1–1440 minutes.")
        case .confirmation(let value): value.title
        }
    }
}

/// All mutations use the application's existing services. Applied projections
/// come from confirmed service state; neither a draft nor a pending dialog owns it.
@MainActor enum SleepPillActions {
    /// The applied Keep Awake session as a pill. A duration in `presets` (default: the quick menu's Keep Awake list) is
    /// that preset; any other duration is `.custom`, so the selection follows the applied duration, never the editor.
    static func awakeSelection(_ model: TilveroModel, presets: [Int]? = nil) -> SleepPillSelection? {
        let service = model.keepAwake
        guard service.isActive else { return nil }
        switch service.expiry {
        case .duration:
            guard let seconds = service.appliedPillDurationSeconds else { return nil }
            if seconds % 60 == 0, (presets ?? model.quickPresets.presets.keepAwake).contains(seconds / 60) {
                return .preset(seconds / 60)
            }
            return .custom
        case .until: return .until
        case .untilStopped: return .untilStopped
        case nil: return nil
        }
    }

    /// A running timer whose duration is not listed (custom, after «+5 мин», or its preset removed) selects «Своё».
    static func timerSelection(_ model: TilveroModel, presets: [Int]? = nil) -> SleepPillSelection? {
        guard let minutes = model.sleepTimer.activePillMinutes else { return nil }
        return (presets ?? model.quickPresets.presets.sleepTimer).contains(minutes) ? .preset(minutes) : .custom
    }

    static func canChooseAwake(_ model: TilveroModel) -> Bool {
        model.sleepPillActionsAllowed && model.keepAwake.isAvailable && !model.chargeModeActive
            && !(model.keepAwake.hasOwnedAssertion && !model.keepAwake.isActive)
    }
    static func canChooseTimer(_ model: TilveroModel) -> Bool {
        model.sleepPillActionsAllowed && model.canSelectSleepTimerDuration
            && !(model.keepAwake.hasOwnedAssertion && !model.keepAwake.isActive)
    }

    static func awakeDraftRequest(_ model: TilveroModel) throws -> AwakePillRequest {
        switch model.keepAwakeDraft {
        case .duration(let duration):
            if model.keepAwakeUsesCustomDuration {
                guard let minutes = SleepTimerInput.minutes(model.keepAwakeCustomMinutes) else {
                    throw SleepPillActionError.invalidDuration
                }
                return .duration(minutes)
            }
            return .duration(duration.rawValue)
        case .until(let target): return .until(target)
        case .untilStopped: return .untilStopped
        }
    }

    /// A switch-on is a start, never permission to replace an intervening session.
    /// Switch-off retains the assertion captured when the control was presented.
    static func setAwakeEnabled(_ model: TilveroModel, enabled: Bool, token: SleepControlToken?,
                                request: AwakePillRequest? = nil,
                                consent: SleepPillConfirmation? = nil) throws {
        if enabled {
            guard token == nil, !model.keepAwake.hasOwnedAssertion else { throw SleepPillActionError.blocked }
            try awake(model, request: try request ?? awakeDraftRequest(model), consent: consent)
        } else {
            guard let token, case .awake = token else { throw SleepPillActionError.blocked }
            try finish(model, token: token)
        }
    }

    /// Enable is fresh start intent. Disable can retry this session's retained
    /// hold, but cannot cancel an intervening timer or a submitted sleep request.
    static func setTimerEnabled(_ model: TilveroModel, enabled: Bool, token: SleepControlToken?,
                                minutes: Int? = nil, custom: Bool? = nil,
                                consent: SleepPillConfirmation? = nil) throws {
        let service = model.sleepTimer
        if enabled {
            guard token == nil, !service.isActive, !service.isHoldingAwake else { throw SleepPillActionError.blocked }
            guard let minutes = minutes ?? SleepTimerInput.minutes(model.sleepTimerMinutes) else {
                throw SleepPillActionError.invalidDuration
            }
            try timer(model, minutes: minutes, custom: custom ?? model.sleepTimerUsesCustom, consent: consent)
        } else {
            guard case .timer(let id) = token, service.sessionID == id,
                  service.needsHoldRelease || service.isEditable || service.phase == .preparing else {
                throw SleepPillActionError.blocked
            }
            service.cancel()
            if service.needsHoldRelease { throw KeepAwakeError.releaseFailed }
        }
    }

    static func timer(_ model: TilveroModel, minutes: Int, custom: Bool = false,
                      consent: SleepPillConfirmation? = nil) throws {
        guard (1...1440).contains(minutes) else { throw SleepPillActionError.invalidDuration }
        guard canChooseTimer(model) else { throw SleepPillActionError.blocked }
        if let id = model.keepAwake.ownedAssertionID {
            let needed = SleepPillConfirmation.endAwake(id)
            guard consent == needed else { throw SleepPillActionError.confirmation(needed) }
        }
        try model.selectSleepTimer(minutes: minutes, replacingAwake: model.keepAwake.hasOwnedAssertion)
        model.sleepTimerUsesCustom = custom
    }

    static func awake(_ model: TilveroModel, request: AwakePillRequest,
                      consent: SleepPillConfirmation? = nil) throws {
        switch request {
        case .duration(let minutes):
            guard (1...1440).contains(minutes) else { throw SleepPillActionError.invalidDuration }
        case .until(let target):
            let interval = target.timeIntervalSinceNow
            guard interval.isFinite, interval > 0, interval <= 86_400 else { throw KeepAwakeError.invalidDuration }
        case .untilStopped: break
        }
        guard canChooseAwake(model) else { throw SleepPillActionError.blocked }
        if model.sleepTimer.isActive {
            let needed = SleepPillConfirmation.endTimer(model.sleepTimer.sessionID)
            guard consent == needed else { throw SleepPillActionError.confirmation(needed) }
        }
        if model.keepAwake.hasOwnedAssertion {
            if request == .untilStopped, model.keepAwake.expiry == .untilStopped { return }
            if case .duration(let minutes) = request, model.keepAwake.expiry != .untilStopped {
                try model.keepAwake.replaceDuration(seconds: minutes * 60)
                setDraft(model, request: request)
                return
            }
            // Choosing another kind of session (until stopped, a clock time, or back to a duration) is the user's
            // intent: the current hold is stopped and the new one starts at once, with no question.
            try model.keepAwake.stop()
            guard !model.keepAwake.hasOwnedAssertion else { throw SleepPillActionError.blocked }
        }
        setDraft(model, request: request)
        try model.startKeepAwakeDraft(replacingSleepTimer: model.sleepTimer.isActive)
    }

    private static func setDraft(_ model: TilveroModel, request: AwakePillRequest) {
        switch request {
        case .duration(let minutes):
            model.keepAwakeDuration = KeepAwakeDuration(rawValue: minutes)!
        case .until(let target): model.keepAwakeDraft = .until(target)
        case .untilStopped: model.keepAwakeDraft = .untilStopped
        }
    }
}

/// The duration rows' four-column grid (cell 73.5 pt in the 312 pt popover content).
enum SleepPillGrid {
    static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
}

/// One preset pill as data. The pill row sits in a one-second `TimelineView`, but a `ForEach` over constants is not
/// re-run by the tick: the selection and the countdown travel in the element so a changed second is a changed element.
struct SleepPillItem: Identifiable, Equatable {
    let minutes: Int
    let countdown: String?
    var id: Int { minutes }
    static func items(of presets: [Int], applied: SleepPillSelection?, countdown: String) -> [SleepPillItem] {
        presets.map { SleepPillItem(minutes: $0, countdown: applied == .preset($0) ? countdown : nil) }
    }
}

@MainActor struct SleepDurationPill: View {
    let title: String
    let selected: Bool
    var countdown: String? = nil
    let id: String
    let captionID: String
    var accessibilityTitle: String? = nil
    var selectedHelp: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sleepPillsLayout) private var layout
    private var helpTitle: String {
        guard selected else { return accessibilityTitle ?? title }
        return selectedHelp ?? (L10n.language == "ru" ? "Изменить, продлить или завершить" : "Edit, extend or end session")
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if let countdown {
                    StudioText(countdown, id: id + ".countdown")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.white)
                } else {
                    StudioText(title, id: captionID)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Color.white : Color.primary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(minWidth: layout.pillWidth, maxWidth: layout.pillWidth ?? .infinity, minHeight: 26).padding(.vertical, 5)
            .background(selected ? layout.selectedFill : Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityValue(countdown.map { L10n.text("Time remaining") + ": " + $0 } ?? "")
        .help(helpTitle)
        .accessibilityIdentifier(id).studioElement(id, label: title)
    }
}

/// A header row (title, shortcuts, switch) whose layout depends on the width: `ViewThatFits` tries the roomy variant and
/// falls back to the compact one. A switch inside the variants is a different view in each, so every swap (starting a
/// session adds the end time and shortcuts) rebuilt the `NSSwitch` mid-click: the on/off animation was cut and the
/// thumb jumped. The real switch therefore lives in an overlay outside `ViewThatFits`; each variant only reserves the
/// switch's space with an invisible twin (`SwitchSlot`) so the fitting decision stays exact.
@MainActor struct SwitchHeaderRow<Variant: View, Control: View>: View {
    let height: CGFloat
    let variant: (_ compact: Bool, _ slot: SwitchSlot) -> Variant
    let control: Control
    init(height: CGFloat, @ViewBuilder variant: @escaping (_ compact: Bool, _ slot: SwitchSlot) -> Variant, @ViewBuilder control: () -> Control) {
        self.height = height; self.variant = variant; self.control = control()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            variant(false, SwitchSlot())
            variant(true, SwitchSlot())
        }
        .frame(height: height)
        .overlay(alignment: .trailing) { control }
    }
}

/// The size of a regular switch, without the switch: invisible, not focusable, not announced.
@MainActor struct SwitchSlot: View {
    var body: some View {
        Toggle("", isOn: .constant(false)).toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
            .hidden().accessibilityHidden(true).allowsHitTesting(false)
    }
}

@MainActor struct SleepTimerPillsPanel: View {
    private struct WheelCommit {
        let identity: PopoverCloseIdentity
        let value: SleepWheelValue
    }
    var model: TilveroModel
    /// False in the main window, which shows Sleep at charge and the lid switch in their own tiles.
    var showsCompanions = true
    /// Draft presets for the editor's passive preview; `nil` reads the saved ones.
    var presets: QuickPresets? = nil
    @State private var showsWheel = false
    @State private var wheelPresentationID = UUID()
    @State private var committedWheelValue: WheelCommit?
    @State private var activeControlToken: SleepControlToken?
    @State private var error: String?
    private enum PendingAction {
        case request(minutes: Int, custom: Bool), enable(minutes: Int, custom: Bool)
    }
    @State private var pending: PendingAction?
    @State private var consent: SleepPillConfirmation?
    @State private var confirms = false
    private var service: SleepTimerService { model.sleepTimer }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            masterRow
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
                let list = (presets ?? model.quickPresets.presets).sleepTimer
                let selection = SleepPillActions.timerSelection(model, presets: list)
                let countdown = KeepAwakePresentation.countdown(service.remainingSeconds)
                // Four columns: up to four cells is one row, five to eight two rows, «Своё» always last. The row count
                // follows the configuration only, so the popover height never changes with the state.
                LazyVGrid(columns: SleepPillGrid.columns, spacing: 6) {
                    // The elements carry the selection and the countdown: a ForEach over constants is not re-evaluated
                    // by the tick, so the preset pills' text used to refresh only when something else invalidated them.
                    ForEach(SleepPillItem.items(of: list, applied: selection, countdown: countdown)) { item in
                        pill(PresetLabel.duration(item.minutes), selection: .preset(item.minutes), applied: selection,
                             countdown: item.countdown, id: "timer.preset.\(item.minutes)",
                             accessibilityTitle: PresetLabel.spokenDuration(item.minutes)) { apply(minutes: item.minutes, custom: false) }
                    }
                    pill(L10n.text("Custom timer time"), selection: .custom, applied: selection, countdown: countdown, id: "timer.custom") {
                        wheelPresentationID = UUID(); committedWheelValue = nil
                        showsWheel = true; error = nil
                    }
                    .background { wheelAnchor }
                }
            }
            if service.needsHoldRelease {
                Text(L10n.text("The timer’s awake hold still needs to be released.")).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                StudioActionButton(L10n.text("Release timer hold"), id: "sleep-timer-release-hold") { service.cancel() }
            } else if service.isActive {
                if SleepPillActions.controlToken(model, awake: false) == nil {
                    HStack {
                        Spacer(minLength: 6)
                        StudioActionButton(L10n.text("Cancel timer"), id: "sleep-timer-cancel") { service.cancel(); error = nil }
                            .disabled(!service.isEditable && service.phase != .preparing)
                    }
                }
                if !service.isEditable {
                    Text(L10n.text(service.phase == .preparing ? "Preparing for sleep…" : service.phase == .requesting ? "Requesting sleep…" : "Sleep requested; waiting for the system…"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if service.activePillMinutes == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
                        Text(L10n.text("Time remaining") + ": " + KeepAwakePresentation.countdown(service.remainingSeconds))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let message = error ?? service.problemMessage {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let diagnostic = service.diagnostic {
                DisclosureGroup(L10n.text("Details")) { Text(L10n.text(diagnostic)).font(.caption).textSelection(.enabled) }.font(.caption)
            }
            if !service.isAvailable {
                Text(L10n.text("Sleep timer is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
            }
            if showsCompanions { Divider().padding(.vertical, 2); SleepAtChargePanel(model: model, presets: presets) }
            // Its own switch, like Keep Awake's (the permission is shared): a running timer continues with the lid closed.
            if showsCompanions, model.lidSleep.isAvailable {
                Divider().padding(.vertical, 2)
                LidSleepOverrideRow(model: model, mode: .scheduledSleep)
            }
        }
        .studioElement("timer.editor", kind: "container", label: "Sleep timer editor")
        .onChange(of: ObjectIdentifier(model)) { _, _ in
            committedWheelValue = nil; wheelPresentationID = UUID(); showsWheel = false
            activeControlToken = nil; pending = nil; consent = nil; confirms = false; error = nil
        }
        .confirmationDialog(consent?.title ?? "", isPresented: $confirms, titleVisibility: .visible) {
            Button(consent?.action ?? L10n.text("Apply")) {
                switch pending {
                case .request(let minutes, let custom): apply(minutes: minutes, custom: custom, consent: consent)
                case .enable(let minutes, let custom): setEnabled(true, token: nil, minutes: minutes, custom: custom, consent: consent)
                case nil: break
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil; consent = nil }
        } message: { Text(consent?.explanation ?? "") }
    }
    private var masterRow: some View {
        // A running timer's header is crowded (chips, end clock and switch): in a wide clock format ("10:18 PM") the info
        // button gives way, so the switch always stays inside the row.
        let token = service.isActive ? service.sessionID.map(SleepControlToken.timer) : nil
        let canStop = token != nil && (service.needsHoldRelease || service.isEditable || service.phase == .preparing)
        return SwitchHeaderRow(height: 32) { compact, slot in
            masterRowContent(showsInfo: !compact, token: token, slot: slot)
        } control: {
            // A failed release keeps the switch on. Acquisition failures without a
            // session UUID retain the explicit recovery action instead of inventing one.
            Toggle(L10n.text("Sleep timer"), isOn: Binding(
                get: { service.isActive },
                set: { setEnabled($0, token: token) }))
                .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
                .disabled(service.isActive ? !canStop : !SleepPillActions.canChooseTimer(model))
                .accessibilityIdentifier("sleep-timer-master")
                .studioElement("timer.master", label: "Sleep timer master switch")
        }
        .studioElement("timer.header", kind: "container", label: "Sleep timer controls")
    }
    private func masterRowContent(showsInfo: Bool, token: SleepControlToken?, slot: SwitchSlot) -> some View {
        HStack(spacing: 3) {
            StudioText(L10n.text("Sleep timer"), id: "timer.heading")
                .font(.system(size: 14, weight: .semibold)).fixedSize()
            if showsInfo {
                SectionInfoButton(title: L10n.text("Sleep timer"), paragraphs: [
                    L10n.text("Choose a time to start immediately."),
                    L10n.text("Keeps Mac awake until the timer ends, then requests sleep."),
                ], id: "sleep-timer-info")
            }
            Spacer(minLength: 0)
            if service.isActive, !service.needsHoldRelease, let end = service.endDate {
                HStack(spacing: 2) {
                    addChip(5, token: token); addChip(15, token: token)
                }
                Text(SleepTimerInput.clock(end)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .studioElement("timer.endClock", label: "Sleep time")
            }
            slot
        }
    }
    /// "+5 min" / "+15 min" next to the end time of a running timer. Fifteen uses the verified extension; five restarts with the longer total.
    private func addChip(_ minutes: Int, token: SleepControlToken?) -> some View {
        let enabled = token != nil && canAdd(minutes, token: token)
        return Button { addMinutes(minutes, token: token) } label: {
            Text("+\(minutes) " + L10n.text("min")).font(.system(size: 10.5, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                .foregroundStyle(Color.primary).padding(.horizontal, 4).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.07))).contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .accessibilityLabel("+\(minutes) " + L10n.text("min"))
        .studioElement("timer.add.\(minutes)", label: "Add \(minutes) minutes")
    }
    private func canAdd(_ minutes: Int, token: SleepControlToken?) -> Bool {
        guard let token else { return false }
        if minutes == 15 { return SleepPillActions.canExtend(model, token: token, minutes: 15) }
        return model.sleepPillActionsAllowed && service.isEditable && service.remainingSeconds > 0 && service.remainingSeconds <= 86_400 - minutes * 60
    }
    private func addMinutes(_ minutes: Int, token: SleepControlToken?) {
        guard let token, canAdd(minutes, token: token) else { return }
        if minutes == 15 {
            do { try SleepPillActions.extend(model, token: token, minutes: 15); error = nil } catch { self.error = error.localizedDescription }
        } else {
            apply(minutes: min(1440, (service.remainingSeconds + 59) / 60 + minutes), custom: true)
        }
    }
    private func pill(_ title: String, selection: SleepPillSelection, applied: SleepPillSelection?, countdown: String?,
                      id: String, accessibilityTitle: String? = nil, action: @escaping () -> Void) -> some View {
        let selected = applied == selection
        return SleepDurationPill(title: title, selected: selected,
            countdown: selected ? countdown : nil,
            id: id, captionID: id + ".caption", accessibilityTitle: accessibilityTitle, action: {
                // Tapping the running pill ends the timer (like the Overview Keep Awake strip); the others start it.
                if selected { setEnabled(false, token: SleepPillActions.controlToken(model, awake: false)) }
                else { action() }
            })
            .disabled(!selected && !SleepPillActions.canChooseTimer(model))
    }
    private var wheelAnchor: some View {
        let identity = PopoverCloseIdentity(owner: ObjectIdentifier(model), presentation: wheelPresentationID)
        return Color.clear
            .popover(isPresented: $showsWheel, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                SleepWheelPicker(mode: .duration,
                    initialMinutes: service.activePillMinutes ?? SleepTimerInput.minutes(model.sleepTimerMinutes) ?? 30,
                    initialDate: service.endDate ?? Date().addingTimeInterval(1800),
                    onCommit: { value in
                        guard identity.presentation == wheelPresentationID else { return }
                        committedWheelValue = WheelCommit(identity: identity, value: value); showsWheel = false
                    },
                    onCancel: {
                        guard identity.presentation == wheelPresentationID else { return }
                        committedWheelValue = nil; showsWheel = false
                    })
                    .studioSubpresentation("timer.wheel")
                    .background {
                        PopoverCloseObserver(identity: identity) {
                            guard identity.owner == ObjectIdentifier(model), identity.presentation == wheelPresentationID,
                                  let committed = committedWheelValue, committed.identity == identity else { return }
                            committedWheelValue = nil
                            if case .duration(let minutes) = committed.value { apply(minutes: minutes, custom: true) }
                        }.allowsHitTesting(false)
                    }
            }
            .allowsHitTesting(false)
    }
    private func apply(minutes: Int, custom: Bool, consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.timer(model, minutes: minutes, custom: custom, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            pending = .request(minutes: minutes, custom: custom); consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
    private func setEnabled(_ enabled: Bool, token: SleepControlToken?, minutes: Int? = nil, custom: Bool? = nil,
                            consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.setTimerEnabled(model, enabled: enabled, token: token,
                minutes: minutes, custom: custom, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            guard let captured = minutes ?? SleepTimerInput.minutes(model.sleepTimerMinutes) else { return }
            pending = .enable(minutes: captured, custom: custom ?? model.sleepTimerUsesCustom)
            consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor struct KeepAwakePillsPanel: View {
    var model: TilveroModel
    /// False in the main window, which shows Keep awake until charge and the lid switch in their own tiles.
    var showsCompanions = true
    @Environment(\.sleepPillsLayout) private var layout
    /// Draft presets for the editor's passive preview; `nil` reads the saved ones.
    var presets: QuickPresets? = nil
    @State private var wheelMode: SleepWheelMode?
    @State private var committedWheelValue: SleepWheelValue?
    @State private var error: String?
    private enum PendingAction {
        case request(AwakePillRequest), enable(AwakePillRequest)
    }
    @State private var pending: PendingAction?
    @State private var consent: SleepPillConfirmation?
    @State private var confirms = false
    private var service: KeepAwakeService { model.keepAwake }
    private var columns: [GridItem] {
        layout.pillWidth.map { Array(repeating: GridItem(.fixed($0), spacing: 6), count: 7) + [GridItem(.flexible(minimum: $0), alignment: .leading)] }
            ?? SleepPillGrid.columns
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            masterRow
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
                let list = awakeList
                let applied = SleepPillActions.awakeSelection(model, presets: list)
                let countdown = KeepAwakePresentation.countdown(service.remainingSeconds)
                LazyVGrid(columns: columns, spacing: 6) {
                    // Elements carry the state so the tick re-evaluates them (see SleepTimerPillsPanel).
                    ForEach(SleepPillItem.items(of: list, applied: applied, countdown: countdown)) { item in
                        pill(PresetLabel.duration(item.minutes), option: .preset(item.minutes), applied: applied, countdown: item.countdown,
                             raw: item.minutes, accessibilityTitle: PresetLabel.spokenDuration(item.minutes)) {
                            apply(.duration(item.minutes))
                        }
                    }
                    pill("∞", option: .untilStopped, applied: applied, countdown: countdown, raw: 0,
                         accessibilityTitle: L10n.text("Until stopped")) { apply(.untilStopped) }
                    pill(L10n.text("Until…"), option: .until, applied: applied, countdown: countdown, raw: -2) { wheelMode = .until; error = nil }
                        .background { wheelAnchor(mode: .until) }
                }
            }
            if SleepPillActions.awakeSelection(model, presets: awakeList) == .custom {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
                    StudioText(KeepAwakePresentation.countdown(service.remainingSeconds), id: "awake.custom.countdown")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if service.hasOwnedAssertion, !service.isActive {
                Text(L10n.text("Check session")).font(.caption).foregroundStyle(.orange)
            }
            if let message = error ?? service.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !service.isAvailable {
                Text(L10n.text("Keep Awake is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
            }
            if showsCompanions {
                Divider().padding(.vertical, 2)
                SleepAtChargePanel(model: model, mode: .keepAwake, presets: presets)
                Divider().padding(.vertical, 2)
                ClosedLidExplanationView(model: model)
            }
        }
        .studioElement("awake.editor", kind: "container", label: "Keep Awake editor")
        .confirmationDialog(consent?.title ?? "", isPresented: $confirms, titleVisibility: .visible) {
            Button(consent?.action ?? L10n.text("Apply")) {
                switch pending {
                case .request(let request): apply(request, consent: consent)
                case .enable(let request): setEnabled(true, token: nil, request: request, consent: consent)
                case nil: break
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil; consent = nil }
        } message: { Text(consent?.explanation ?? "") }
    }
    private var masterRow: some View {
        // The end time sits right of the title when it fits next to the shortcuts; otherwise it is left out.
        let token = service.ownedAssertionID.map(SleepControlToken.awake)
        return SwitchHeaderRow(height: 32) { compact, slot in
            masterRowContent(showsEnd: !compact, token: token, slot: slot)
        } control: {
            Toggle(L10n.text("Keep Awake"), isOn: Binding(
                get: { service.hasOwnedAssertion },
                set: { setEnabled($0, token: token) }))
                .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
                .disabled(!service.hasOwnedAssertion && !SleepPillActions.canChooseAwake(model))
                .accessibilityIdentifier("keep-awake-master")
                .studioElement("awake.master", label: "Keep Awake master switch")
        }
        .studioElement("awake.header", kind: "container", label: "Keep Awake controls")
    }
    private func masterRowContent(showsEnd: Bool, token: SleepControlToken?, slot: SwitchSlot) -> some View {
        HStack(spacing: 6) {
            StudioText(L10n.text("Keep Awake"), id: "awake.heading")
                .font(.system(size: 14, weight: .semibold)).fixedSize()
            SectionInfoButton(title: L10n.text("Keep Awake"), paragraphs: [
                L10n.text("Choose a time to start immediately."),
                L10n.text("The display can turn off. Closing the lid or choosing Sleep still works."),
            ], id: "keep-awake-info")
            if showsEnd, service.isActive, let end = service.endDate {
                Text(KeepAwakePresentation.endTime(end)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().monospacedDigit()
            }
            Spacer(minLength: 8)
            if service.isActive, let token {
                extensionButton(15, token: token)
                extensionButton(60, token: token)
            }
            slot
        }
    }
    private func extensionButton(_ minutes: Int, token: SleepControlToken) -> some View {
        let title = minutes == 15 ? "+15 " + L10n.text("min") : "+1 " + L10n.text("h")
        let accessibilityTitle = L10n.language == "ru"
            ? "Продлить сеанс на " + (minutes == 15 ? "15 минут" : "1 час")
            : "Extend session by " + (minutes == 15 ? "15 minutes" : "1 hour")
        return Button {
            do { try SleepPillActions.extend(model, token: token, minutes: minutes); error = nil }
            catch { self.error = error.localizedDescription }
        } label: {
            StudioText(title, id: "awake.extend.\(minutes).caption")
                .font(.system(size: 12, weight: .medium)).fixedSize()
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!SleepPillActions.canExtend(model, token: token, minutes: minutes))
        .accessibilityLabel(accessibilityTitle).help(accessibilityTitle)
        .accessibilityIdentifier("awake.extend.\(minutes)")
        .studioElement("awake.extend.\(minutes)", label: accessibilityTitle)
    }
    private var awakeList: [Int] { (presets ?? model.quickPresets.presets).keepAwake }
    private func pill(_ title: String, option: SleepPillSelection, applied: SleepPillSelection?, countdown: String?,
                      raw: Int, accessibilityTitle: String? = nil, action: @escaping () -> Void) -> some View {
        let selected = applied == option
        let token = service.ownedAssertionID.map(SleepControlToken.awake)
        return SleepDurationPill(title: title, selected: selected,
            countdown: selected && option != .untilStopped ? countdown : nil,
            id: "keep-awake-option-\(raw)", captionID: "awake.option.\(raw).caption",
            accessibilityTitle: accessibilityTitle, selectedHelp: endSessionLabel, action: {
                if selected { setEnabled(false, token: token) }
                else { action() }
            })
            .disabled(!selected && !SleepPillActions.canChooseAwake(model))
    }
    private var endSessionLabel: String { L10n.language == "ru" ? "Завершить сеанс" : "End session" }
    private func wheelAnchor(mode: SleepWheelMode) -> some View {
        Color.clear
            .popover(isPresented: Binding(get: { wheelMode == mode }, set: { if !$0 && wheelMode == mode { wheelMode = nil } }),
                     attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                SleepWheelPicker(mode: mode, initialMinutes: initialWheelMinutes,
                    initialDate: initialWheelDate,
                    onCommit: { committedWheelValue = $0; wheelMode = nil },
                    onCancel: { committedWheelValue = nil; wheelMode = nil })
                    .studioSubpresentation("awake.wheel." + (mode == .duration ? "duration" : "until"))
                    .onDisappear {
                        guard let value = committedWheelValue else { return }
                        committedWheelValue = nil
                        switch value {
                        case .duration(let minutes): apply(.duration(minutes))
                        case .until(let date): apply(.until(date))
                        }
                    }
            }
            .allowsHitTesting(false)
    }
    private var initialWheelMinutes: Int {
        if let seconds = service.appliedPillDurationSeconds { return min(1440, max(1, (seconds + 59) / 60)) }
        return SleepTimerInput.minutes(model.keepAwakeCustomMinutes) ?? model.keepAwakeDuration.rawValue
    }
    private var initialWheelDate: Date {
        if case .until(let target) = service.expiry { return target }
        if case .until(let target) = model.keepAwakeDraft { return target }
        return Date().addingTimeInterval(1800)
    }
    private func apply(_ request: AwakePillRequest, consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.awake(model, request: request, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            pending = .request(request); consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
    private func setEnabled(_ enabled: Bool, token: SleepControlToken?, request: AwakePillRequest? = nil,
                            consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.setAwakeEnabled(model, enabled: enabled, token: token, request: request, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            guard let captured = try? request ?? SleepPillActions.awakeDraftRequest(model) else { return }
            pending = .enable(captured); consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
}

/// "Sleep at charge" block under the sleep timer: a switch plus level pills. Picking a level arms it at once
/// (like the timer's pills); the same pill again, or the switch, cancels it.
@MainActor struct SleepAtChargePanel: View {
    /// `.sleep`: stay awake until the level, then sleep (under the sleep timer). `.keepAwake`: stay awake until the
    /// level, then only stop holding (under Keep Awake).
    enum Mode { case sleep, keepAwake }
    var model: TilveroModel
    var mode: Mode = .sleep
    /// Draft presets for the editor's passive preview; `nil` reads the saved ones.
    var presets: QuickPresets? = nil
    @State private var error: String?
    private var service: SleepAtChargeService { mode == .sleep ? model.sleepAtCharge : model.keepAwakeUntilCharge }
    private var prefix: String { mode == .sleep ? "charge-sleep" : "charge-awake" }
    private var title: String { L10n.text(mode == .sleep ? "Sleep at charge" : "Keep awake until charge") }
    private var levels: [Int] {
        let value = presets ?? model.quickPresets.presets
        return mode == .sleep ? value.sleepAtCharge : value.awakeUntilCharge
    }
    private var choice: Int {
        get { mode == .sleep ? model.sleepAtChargeChoice : model.keepAwakeUntilChargeChoice }
    }
    private func remember(_ target: Int) {
        if mode == .sleep { model.sleepAtChargeChoice = target } else { model.keepAwakeUntilChargeChoice = target }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StudioText(title, id: prefix + ".heading")
                    .font(.system(size: 14, weight: .semibold)).fixedSize()
                SectionInfoButton(title: title, paragraphs: [
                    L10n.text(mode == .sleep ? "Keeps Mac awake until the charge drops to the level (up to 24 h), then requests sleep."
                                             : "Keeps Mac awake until the charge drops to the level (up to 24 h), then stops holding it; the Mac sleeps as usual."),
                    L10n.text("Levels at or above the current charge are unavailable. Cancelled by sleep or quitting Tilvero."),
                ], id: prefix + "-info")
                Spacer(minLength: 8)
                Toggle(title, isOn: Binding(get: { service.isArmed }, set: setEnabled))
                    .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
                    .disabled(!service.isArmed && !service.canChooseTarget)
                    .help(service.blockedBy().map { L10n.text("Turn off first") + ": " + $0 } ?? "")
                    .accessibilityIdentifier(mode == .sleep ? "sleep-at-charge-master" : "keep-awake-until-charge-master")
                    .studioElement(prefix + ".master", label: title + " master switch")
            }
            .frame(height: 32)
            HStack(spacing: 6) {
                ForEach(levels, id: \.self) { target in
                    SleepAtChargePill(title: PresetLabel.level(target), selected: service.target == target,
                                      enabled: service.target == target || canArm(target), id: prefix + ".preset.\(target)",
                                      accessibilityTitle: PresetLabel.spokenLevel(target)) {
                        choose(target)
                    }
                }
            }
            status
            if !service.isAvailable {
                Text(L10n.text("Sleep at charge is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .studioElement(prefix + ".editor", kind: "container", label: title + " editor")
    }

    @ViewBuilder private var status: some View {
        // Only trouble is worth a line; the level and the wait for battery power live in the info popover.
        if !service.isArmed, let message = error ?? service.problemMessage {
            Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func canArm(_ target: Int) -> Bool { service.canArm(target: target) }

    private func choose(_ target: Int) {
        error = nil
        if service.target == target { service.disarm(); return }
        do { try service.arm(target: target); remember(target) }
        catch { self.error = error.localizedDescription }
    }

    private func setEnabled(_ on: Bool) {
        error = nil
        guard on else { service.disarm(); return }
        // The remembered level, or the highest one still below the present charge.
        let choice = self.choice
        let target = canArm(choice) ? choice : levels.first(where: canArm)
        guard let target else { error = SleepAtChargeError.alreadyReached.localizedDescription; return }
        choose(target)
    }
}

@MainActor struct SleepAtChargePill: View {
    let title: String
    let selected: Bool
    let enabled: Bool
    let id: String
    var accessibilityTitle: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sleepPillsLayout) private var layout
    var body: some View {
        Button(action: action) {
            StudioText(title, id: id + ".caption")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1).frame(minWidth: layout.pillWidth, maxWidth: layout.pillWidth ?? .infinity, minHeight: 26).padding(.vertical, 5)
                .background(selected ? layout.selectedFill : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityIdentifier(id).studioElement(id, label: title)
    }
}
