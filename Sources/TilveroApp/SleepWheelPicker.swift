// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

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
    /// Outer width of the picker; the columns and wheels follow it.
    let width: CGFloat
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

    static let defaultWidth: CGFloat = 200

    init(mode: SleepWheelMode, initialMinutes: Int, initialDate: Date, width: CGFloat = SleepWheelPicker.defaultWidth,
         onCommit: @escaping (SleepWheelValue) -> Void, onCancel: @escaping () -> Void) {
        self.mode = mode
        self.width = width
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
                    StudioText(untilDateText, id: "sleep.wheel.date")
                        .font(.system(size: 13)).monospacedDigit()
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
                        Text(L10n.language == "ru" ? "Часы" : "Hours").frame(width: columnWidth)
                        Text(L10n.language == "ru" ? "Минуты" : "Minutes").frame(width: columnWidth)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(height: 16)
                    wheels
                        .background { unifiedTray }
                }.frame(width: width - 24)
            } else {
                wheels.frame(maxWidth: .infinity).background { unifiedTray }
            }

            actions.frame(height: 28)
        }
        // An invalid time (for example 0 h 0 min) shows no warning line: the disabled Apply button is the only sign, so the
        // picker never changes height.
        .padding(12).frame(width: width, height: isCompact ? 238 : 220)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { appeared = true } }
        .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
        .environment(\.locale, L10n.locale)
        .background { OutsideClickDismiss(onOutside: cancel) }
        .onChange(of: hours) { rollDay() }
        .onChange(of: minutes) { rollDay() }
        .onSubmit(commit).onExitCommand(perform: cancel)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .studioElement("sleep.wheel.editor", kind: "container", label: "Sleep time wheel picker")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: cancel) { Text(L10n.text("Cancel")).lineLimit(1).frame(maxWidth: .infinity) }
                .buttonStyle(WheelCapsuleButtonStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
                .studioElement("sleep.wheel.cancel", label: "Cancel time picker")
            Button(action: commit) { Text(L10n.text("Apply")).lineLimit(1).frame(maxWidth: .infinity) }
                .buttonStyle(WheelCapsuleButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(completed || value(at: now) == nil)
                .studioElement("sleep.wheel.apply", label: "Apply selected time")
        }
    }

    private var wheelStyle: NativeDrumPicker.Style { .unified }
    /// Each of the two wheels (and the label above it): the wheels area is `width - 32` wide with a 12 pt gap.
    private var columnWidth: CGFloat { (width - 32 - 12) / 2 }

    private var wheels: some View {
        HStack(spacing: 12) {
            NativeDrumPicker(selection: hourSelection, range: mode == .duration ? 0...24 : 0...23,
                unit: L10n.text("h"), accessibilityName: L10n.language == "ru" ? "Часы" : "Hours",
                style: wheelStyle, width: columnWidth, wraps: mode == .until, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.hours", label: "Hours wheel")
            NativeDrumPicker(selection: minuteSelection, range: mode == .duration && hours == 24 ? 0...0 : 0...59,
                unit: L10n.text("min"), accessibilityName: L10n.language == "ru" ? "Минуты" : "Minutes",
                style: wheelStyle, width: columnWidth, wraps: mode == .until, onSubmit: commit, onCancel: cancel)
                .studioElement("sleep.wheel.minutes", label: "Minutes wheel")
        }.frame(width: width - 32, height: 126)
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

    /// The end is always within 24 hours, so exactly one day is valid for a chosen time of day (its next
    /// occurrence). The day is therefore derived from the wheels and shown, never chosen separately.
    private var untilDateText: String {
        selectedDay.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale))
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.10)))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Closes a popover on any mouse press outside its window. The native transient behaviour was not reliably
/// triggered for the Keep Awake presentation, and an open picker must never linger after the user clicks away.
private struct OutsideClickDismiss: NSViewRepresentable {
    let onOutside: () -> Void
    func makeNSView(context: Context) -> OutsideClickView { OutsideClickView() }
    func updateNSView(_ view: OutsideClickView, context: Context) { view.onOutside = onOutside }
}

@MainActor final class OutsideClickView: NSView {
    var onOutside: () -> Void = {}
    private var local: Any?
    private var global: Any?
    private let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard window != nil else { return }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let self, let window = self.window, event.window !== window { self.fire() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
    }
    private func fire() { DispatchQueue.main.async { [weak self] in self?.onOutside() } }
    private func removeMonitors() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil
    }
    isolated deinit { removeMonitors() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
