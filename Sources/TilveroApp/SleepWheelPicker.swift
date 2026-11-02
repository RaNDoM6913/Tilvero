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
            HStack {
                StudioText(mode == .duration ? L10n.text("Custom duration") : L10n.text("Until"), id: "sleep.wheel.title")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if !isCompact {
                    Button(action: cancel) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("Cancel"))
                        .studioElement("sleep.wheel.close", label: "Cancel time picker")
                }
            }.frame(height: 20)

            if mode == .until {
                DatePicker(L10n.language == "ru" ? "Дата" : "Date", selection: $selectedDay, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .accessibilityLabel(L10n.language == "ru" ? "Дата окончания" : "End date")
                    .studioElement("sleep.wheel.date", label: "End date")
                    .frame(height: 24, alignment: .leading)
            }

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
                wheels
            }

            if !isCompact || value(at: now) == nil {
                StudioText(summary, id: "sleep.wheel.summary")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(value(at: now) == nil ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: isCompact ? 16 : 30, maxHeight: isCompact ? 16 : 30, alignment: .leading)
            }

            actions.frame(height: 26)
        }
        .padding(12).frame(width: isCompact ? 244 : 300,
                           height: isCompact ? (value(at: now) == nil ? 260 : 236) : 368)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { appeared = true } }
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .environment(\.locale, L10n.locale)
        .onSubmit(commit).onExitCommand(perform: cancel)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .studioElement("sleep.wheel.editor", kind: "container", label: "Sleep time wheel picker")
    }

    @ViewBuilder private var actions: some View {
        if !isCompact {
            HStack {
                Button(L10n.text("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                    .studioElement("sleep.wheel.cancel", label: "Cancel time picker")
                Spacer(minLength: 8)
                Button(action: commit) {
                    Label(L10n.text("Apply"), systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .frame(minHeight: 26)
                    .keyboardShortcut(.defaultAction)
                    .disabled(completed || value(at: now) == nil)
                    .studioElement("sleep.wheel.apply", label: "Apply selected time")
            }
            .font(.system(size: 13))
        }
    }

    private var wheelStyle: NativeDrumPicker.Style {
        guard isCompact else { return .regular }
        return .unified
    }

    private var wheels: some View {
        HStack(spacing: isCompact ? 12 : 16) {
            NativeDrumPicker(selection: hourSelection, range: mode == .duration ? 0...24 : 0...23,
                unit: L10n.text("h"), accessibilityName: L10n.language == "ru" ? "Часы" : "Hours",
                style: wheelStyle, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.hours", label: "Hours wheel")
            NativeDrumPicker(selection: minuteSelection, range: mode == .duration && hours == 24 ? 0...0 : 0...59,
                unit: L10n.text("min"), accessibilityName: L10n.language == "ru" ? "Минуты" : "Minutes",
                style: wheelStyle, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.minutes", label: "Minutes wheel")
        }.frame(width: isCompact ? 212 : 276, height: isCompact ? 126 : 210)
    }

    private var unifiedTray: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.24), lineWidth: 1) }
                    .frame(height: 40).padding(.horizontal, 5)
            }
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(Color(nsColor: .separatorColor), lineWidth: 1) }
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
