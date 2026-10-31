import SwiftUI
import PowerCore

enum SleepPage: String, CaseIterable, Identifiable {
    case timer, awake, reports
    var id: String { rawValue }
    var title: String {
        L10n.text(self == .timer ? "Sleep timer" : self == .awake ? "Keep Awake" : "Reports")
    }
}
enum SleepTimerInputError: LocalizedError {
    case invalid, conflictingMode
    var errorDescription: String? {
        L10n.text(self == .invalid ? "Enter 1–1440 minutes." : "Confirm switching the active sleep mode first.")
    }
}
enum SleepTimerInput {
    static func minutes(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (1...1440).contains(value) else { return nil }
        return value
    }
    static func endTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeStyle = .short
        let suffix = Calendar.current.isDateInTomorrow(date) ? ", " + L10n.text("tomorrow") : ""
        return L10n.text("Sleep at") + " " + formatter.string(from: date) + suffix
    }
}

struct SleepTimerPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(enabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor struct SleepControlsPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    @State private var quickPage: SleepPage = .timer
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            Picker(L10n.text("Sleep"), selection: compact ? $quickPage : $model.selectedSleepPage) {
                ForEach(compact ? [.timer, .awake] : SleepPage.allCases) { item in Text(item.title).tag(item) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 480, alignment: .leading)
            let page = compact ? quickPage : model.selectedSleepPage
            switch page {
            case .timer:
                if compact { SleepTimerPanel(model: model, compact: true) }
                else {
                    ProductSurface { SleepTimerPanel(model: model) }.frame(maxWidth: 560)
                    VStack(alignment: .leading, spacing: 9) {
                        Label(L10n.text("Music and video do not extend the timer."), systemImage: "play.rectangle")
                        Label(L10n.text("Keeps your Mac awake until the timer ends."), systemImage: "moon")
                    }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("How the timer works")) {
                        Text(L10n.text("Tilvero prevents idle system sleep until the timer ends, then releases its hold and requests sleep. The display may turn off. Closing the lid, manual sleep and macOS safety actions still work. A quiet warning appears one minute before. Cancel or quit releases the hold. The timer never restarts after waking or reopening Tilvero."))
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }.frame(maxWidth: 560).font(.system(size: 12))
                }
            case .awake:
                if compact { KeepAwakePanel(model: model, compact: true) }
                else { ProductSurface { KeepAwakePanel(model: model) }.frame(maxWidth: 560) }
            case .reports: SleepReportPanel(model: model)
            }
        }.onAppear {
            if compact { quickPage = model.keepAwake.hasOwnedAssertion ? .awake : .timer }
        }
    }
}

@MainActor struct SleepTimerPanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    @State private var error: String?
    @State private var confirmsSwitch = false
    @State private var pendingSelection: (minutes: Int, custom: Bool)?
    @FocusState private var customFocused: Bool
    private var service: SleepTimerService { model.sleepTimer }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 16) {
            if service.needsHoldRelease {
                Label(L10n.text("The timer’s awake hold still needs to be released."), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Release timer hold")) { service.cancel() }.accessibilityIdentifier("sleep-timer-release-hold")
            } else {
                if !service.isActive { heading }
                choices
                if model.sleepTimerUsesCustom {
                    HStack {
                        Text(L10n.text("Custom duration"))
                        Spacer(minLength: 8)
                        TextField("1–1440", text: $model.sleepTimerMinutes).textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).frame(width: 72)
                            .accessibilityLabel(L10n.text("Sleep timer duration in minutes"))
                            .focused($customFocused).onSubmit { submitCustom() }
                            .onAppear { customFocused = true }
                            .disabled(!model.canSelectSleepTimerDuration)
                        Text(L10n.text("min")).foregroundStyle(.secondary)
                    }.font(.system(size: 12))
                    Text(L10n.text("Press Return to apply the custom time.")).font(.caption).foregroundStyle(.secondary)
                }
                if service.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in active }
                } else if compact {
                    Text(L10n.text("Choose a time to start immediately.")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Keeps Mac awake until the timer ends, then requests sleep."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("Quitting Tilvero cancels the timer."))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Divider()
                    Text(L10n.text("Choose a time to start immediately.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = (error ?? service.message).map(L10n.text) {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let diagnostic = service.diagnostic {
                DisclosureGroup(L10n.text("Details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
                    .font(.caption)
            }
            if !service.isAvailable {
                Text(L10n.text("Sleep timer is unavailable in this build or simulation."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(L10n.text("End Keep Awake and start the sleep timer?"), isPresented: $confirmsSwitch, titleVisibility: .visible) {
            Button(L10n.text("End Keep Awake and start")) { applySelection(replacing: true) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }
    private var heading: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Sleep after…")).font(.system(size: 15, weight: .semibold))
                Text(L10n.text("System sleep on a timer")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var choices: some View {
        HStack(spacing: 6) {
            ForEach([15, 30, 60], id: \.self) { minutes in
                choice("\(minutes) " + L10n.text("min"), selected: service.isActive && !model.sleepTimerUsesCustom && SleepTimerInput.minutes(model.sleepTimerMinutes) == minutes) {
                    select(minutes: minutes, custom: false)
                }
            }
            choice(L10n.text("Custom timer time"), selected: model.sleepTimerUsesCustom) {
                model.sleepTimerUsesCustom = true; error = nil; customFocused = true
            }
        }.disabled(!model.canSelectSleepTimerDuration)
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.09)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func select(minutes: Int, custom: Bool) {
        pendingSelection = (minutes, custom)
        if model.keepAwake.hasOwnedAssertion { confirmsSwitch = true }
        else { applySelection(replacing: false) }
    }
    private func submitCustom() {
        guard let minutes = SleepTimerInput.minutes(model.sleepTimerMinutes) else { error = L10n.text("Enter 1–1440 minutes."); return }
        select(minutes: minutes, custom: true)
    }
    private func applySelection(replacing: Bool) {
        guard let selection = pendingSelection else { return }
        do {
            try model.selectSleepTimer(minutes: selection.minutes, replacingAwake: replacing)
            model.sleepTimerUsesCustom = selection.custom; error = nil; customFocused = false; pendingSelection = nil
        }
        catch { self.error = error.localizedDescription }
    }
    private var active: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 12) {
            if compact {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 25)).foregroundStyle(Color.accentColor)
                    Text(L10n.text("Until Mac sleeps")).font(.subheadline).foregroundStyle(.secondary)
                    Text(KeepAwakePresentation.countdown(service.remainingSeconds))
                        .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                    deadline
                }.frame(maxWidth: .infinity).padding(.vertical, 4)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Sleep timer")).font(.system(size: 15, weight: .semibold)); deadline
                    }
                    Spacer(minLength: 8)
                    Text(KeepAwakePresentation.countdown(service.remainingSeconds))
                        .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Divider()
            }
            HStack(spacing: 8) {
                if !compact { Text(L10n.text("We’ll warn you one minute before.")).font(.system(size: 11)).foregroundStyle(.secondary) }
                Button("+15 " + L10n.text("min")) { do { try service.extend(); error = nil } catch { self.error = error.localizedDescription } }
                    .disabled(!service.canExtend).help(L10n.text("Maximum remaining duration is 24 hours."))
                    .accessibilityIdentifier("sleep-timer-extend")
                Spacer(minLength: 8)
                Button(L10n.text("Cancel timer")) { service.cancel(); error = nil }
                    .disabled(!service.isEditable && service.phase != .preparing).accessibilityIdentifier("sleep-timer-cancel")
            }.controlSize(compact ? .large : .regular)
            if service.phase == .preparing || service.phase == .requesting || service.phase == .accepted {
                Text(L10n.text(service.phase == .preparing ? "Preparing for sleep…" : service.phase == .requesting ? "Requesting sleep…" : "Sleep requested; waiting for the system…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if compact { Text(L10n.text("We’ll warn you one minute before.")).font(.caption).foregroundStyle(.secondary) }
            if service.isHoldingAwake {
                Text(L10n.text("Your Mac will not sleep from inactivity before the timer ends."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var deadline: some View {
        Group { if let end = service.endDate { Text(SleepTimerInput.endTime(end)).font(.system(size: 12)).foregroundStyle(.secondary) } }
    }
}

@MainActor struct SleepTimerActiveRow: View {
    @ObservedObject var model: TilveroModel
    var open: (@MainActor () -> Void)? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Button {
                    if let open { open() }
                    else { model.selectedSleepPage = .timer; model.selectedSection = .sleep; model.openDetails?() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.sleepTimer.needsHoldRelease ? L10n.text("Release timer hold") : L10n.text("Sleep in") + " " + KeepAwakePresentation.countdown(model.sleepTimer.remainingSeconds))
                                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                            if let end = model.sleepTimer.endDate { Text(SleepTimerInput.endTime(end)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(L10n.text("Cancel")) { model.sleepTimer.cancel() }
                    .buttonStyle(.borderless).disabled(!model.sleepTimer.needsHoldRelease && !model.sleepTimer.isEditable && model.sleepTimer.phase != .preparing)
            }
        }
    }
}
