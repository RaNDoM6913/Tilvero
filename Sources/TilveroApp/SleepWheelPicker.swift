import SwiftUI
import Combine

enum SleepWheelMode: Equatable {
    case duration, until
}
enum SleepWheelValue: Equatable {
    case duration(Int), until(Date)
}

/// A local draft editor. Its owner decides what confirmation and service action
/// follow a commit; opening or scrolling this view never changes a sleep mode.
@MainActor struct SleepWheelPicker: View {
    let mode: SleepWheelMode
    let onCommit: (SleepWheelValue) -> Void
    let onCancel: () -> Void
    private let calendar: Calendar
    @State private var hours: Int
    @State private var minutes: Int
    @State private var selectedDay: Date
    @State private var now = Date()
    @State private var completed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private var isCompact: Bool { mode == .duration }

    init(mode: SleepWheelMode, initialMinutes: Int, initialDate: Date,
         onCommit: @escaping (SleepWheelValue) -> Void, onCancel: @escaping () -> Void) {
        self.mode = mode
        self.onCommit = onCommit
        self.onCancel = onCancel
        let calendar = Calendar.current
        self.calendar = calendar
        let duration = min(1440, max(0, initialMinutes))
        _hours = State(initialValue: mode == .duration ? duration / 60 : calendar.component(.hour, from: initialDate))
        _minutes = State(initialValue: mode == .duration ? duration % 60 : calendar.component(.minute, from: initialDate))
        _selectedDay = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StudioText(mode == .duration ? L10n.text("Custom duration") : L10n.text("Until"), id: "sleep.wheel.title")
                    .font(.system(size: 14, weight: .semibold))
                if mode == .until {
                    DatePicker("", selection: $selectedDay, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).fixedSize()
                        .accessibilityLabel(L10n.language == "ru" ? "Дата окончания" : "End date")
                        .studioElement("sleep.wheel.date", label: "End date")
                    StudioText(untilTimeText, id: "sleep.wheel.time")
                        .font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(value(at: now) == nil ? Color.secondary : Color.primary)
                }
                Spacer(minLength: 8)
                if !isCompact {
                    Button(action: cancel) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("Cancel"))
                        .studioElement("sleep.wheel.close", label: "Cancel time picker")
                }
            }.frame(height: 20)

            if isCompact {
                VStack(spacing: 4) {
                    HStack(spacing: 12) {
                        Text(L10n.language == "ru" ? "Часы" : "Hours").frame(width: 100)
                        Text(L10n.language == "ru" ? "Минуты" : "Minutes").frame(width: 100)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 16)
                    wheels
                        .background { unifiedTray }
                }.frame(width: 220)
            } else {
                wheels.frame(maxWidth: .infinity).background { unifiedTray }
            }

            if value(at: now) == nil {
                StudioText(summary, id: "sleep.wheel.summary")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(value(at: now) == nil ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
            }

            actions.frame(height: isCompact ? 26 : 28)
        }
        .padding(12).frame(width: 244,
                           height: isCompact ? (value(at: now) == nil ? 260 : 236) : (value(at: now) == nil ? 244 : 220))
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { appeared = true } }
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .environment(\.locale, L10n.locale)
        .onChange(of: hours) { rollDay() }
        .onChange(of: minutes) { rollDay() }
        .onSubmit(commit).onExitCommand(perform: cancel)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .studioElement("sleep.wheel.editor", kind: "container", label: "Sleep time wheel picker")
    }

    @ViewBuilder private var actions: some View {
        if !isCompact {
            HStack(spacing: 8) {
                Button(action: cancel) { Text(L10n.text("Cancel")).lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(WheelCapsuleButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                    .studioElement("sleep.wheel.cancel", label: "Cancel time picker")
                Button(action: commit) {
                    Text(L10n.text("Apply")).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(WheelCapsuleButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(completed || value(at: now) == nil)
                .studioElement("sleep.wheel.apply", label: "Apply selected time")
            }
        } else {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.language == "ru" ? "Отмена" : "Cancel", action: cancel)
                    .buttonStyle(.borderless).controlSize(.small)
                    .frame(minHeight: 26)
                    .keyboardShortcut(.cancelAction)
                    .studioElement("sleep.wheel.cancel", label: "Cancel time picker")
                Button(L10n.text("Apply"), action: commit)
                    .buttonStyle(WheelCapsuleButtonStyle(prominent: true, expands: false))
                    .keyboardShortcut(.defaultAction)
                    .disabled(completed || value(at: now) == nil)
                    .studioElement("sleep.wheel.apply", label: "Apply selected time")
            }
            .font(.system(size: 13))
        }
    }

    private var wheelStyle: NativeDrumPicker.Style { .unified }

    private var wheels: some View {
        HStack(spacing: 12) {
            NativeDrumPicker(selection: hourSelection, range: mode == .duration ? 0...24 : 0...23,
                unit: L10n.text("h"), accessibilityName: L10n.language == "ru" ? "Часы" : "Hours",
                style: wheelStyle, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.hours", label: "Hours wheel")
            NativeDrumPicker(selection: minuteSelection, range: mode == .duration && hours == 24 ? 0...0 : 0...59,
                unit: L10n.text("min"), accessibilityName: L10n.language == "ru" ? "Минуты" : "Minutes",
                style: wheelStyle, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.minutes", label: "Minutes wheel")
        }.frame(width: 212, height: 126)
    }

    /// iOS/macOS 27 style: no tray, one neutral translucent capsule behind the selected row of both wheels.
    private var unifiedTray: some View {
        Capsule().fill(Color.primary.opacity(0.11)).frame(height: 42).padding(.horizontal, 4)
    }

    private var hourSelection: Binding<Int> {
        Binding(get: { hours }, set: { value in
            hours = min(mode == .duration ? 24 : 23, max(0, value))
            if mode == .duration && hours == 24 { minutes = 0 }
        })
    }
    private var minuteSelection: Binding<Int> {
        Binding(get: { mode == .duration && hours == 24 ? 0 : minutes }, set: { value in
            minutes = mode == .duration && hours == 24 ? 0 : min(59, max(0, value))
        })
    }

    private func value(at date: Date) -> SleepWheelValue? {
        if mode == .duration {
            let total = hours * 60 + minutes
            return (1...1440).contains(total) ? .duration(total) : nil
        }
        guard let target = Self.concreteDate(day: selectedDay, hour: hours, minute: minutes, calendar: calendar) else { return nil }
        let interval = target.timeIntervalSince(date)
        return interval.isFinite && interval > 0 && interval <= 86_400 ? .until(target) : nil
    }

    private var untilTimeText: String {
        // The wheels are 24-hour, so the time reads 24-hour in every language.
        guard case .until? = value(at: now) else { return "—" }
        return String(format: "%02d:%02d", hours, minutes)
    }

    /// The wheels pick a time of day; the date follows to the next occurrence (today, or tomorrow once it has passed).
    private func rollDay() {
        guard mode == .until else { return }
        let today = Date()
        if let candidate = Self.concreteDate(day: today, hour: hours, minute: minutes, calendar: calendar), candidate > today {
            selectedDay = candidate
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                  let candidate = Self.concreteDate(day: tomorrow, hour: hours, minute: minutes, calendar: calendar) {
            selectedDay = candidate
        }
    }

    private var summary: String {
        guard let selected = value(at: now) else {
            return mode == .duration
                ? (L10n.language == "ru" ? "Выберите от 1 до 1440 минут." : "Choose 1–1440 minutes.")
                : (L10n.language == "ru" ? "Выберите будущее время в пределах 24 часов." : "Choose a future time within 24 hours.")
        }
        switch selected {
        case .duration(let total):
            return "\(total / 60) " + L10n.text("h") + " " + "\(total % 60) " + L10n.text("min")
        case .until(let target):
            return KeepAwakePresentation.endTime(target, timeZone: calendar.timeZone)
        }
    }

    /// Reject skipped local times and preserve the chosen civil day. For a
    /// repeated hour, retain the offset of the concrete selected date when possible.
    static func concreteDate(day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let candidates = [Calendar.RepeatedTimePolicy.first, .last].compactMap { repeated in
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                matchingPolicy: .strict, repeatedTimePolicy: repeated, direction: .forward)
        }.filter { candidate in
            calendar.isDate(candidate, inSameDayAs: day)
                && calendar.component(.hour, from: candidate) == hour
                && calendar.component(.minute, from: candidate) == minute
        }
        let offset = calendar.timeZone.secondsFromGMT(for: day)
        return candidates.first(where: { calendar.timeZone.secondsFromGMT(for: $0) == offset }) ?? candidates.first
    }

    private func commit() {
        guard isEnabled, !completed, let selected = value(at: Date()) else { return }
        completed = true
        onCommit(selected)
    }
    private func cancel() {
        guard !completed else { return }
        completed = true
        onCancel()
    }
}

/// Explicit accent fill: the system prominent style turns grey whenever the hosting panel is not the key window,
/// which is how the quick-menu popover presents this picker.
private struct WheelCapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    var expands = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, expands ? 0 : 14)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: expands ? 28 : 26)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.10)))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}
