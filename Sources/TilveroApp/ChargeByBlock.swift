// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// The quick Charge page's "Charge by time" block: the chosen time as a pill (opens the same wheel as the sleep
/// timer's "Until"), the level as the overview's capsule strip with 100 as its own button, one status line. The
/// explanations live in the info popover.
@MainActor struct ChargeByBlock: View {
    @ObservedObject var model: TilveroModel
    @ObservedObject var service: ChargeByService
    @State private var showsWheel = false

    private static let strip = [85, 90, 95]
    private var limit: Int? { model.observedNativeLimit }
    /// Levels above the user's limit; the strip never offers a level the limit already allows.
    private var levels: [Int] {
        let allowed = Set(model.nativeCharge.authorizedPersistentTargets)
        return [85, 90, 95, 100].filter { level in allowed.contains(level) && (limit.map { level > $0 } ?? true) }
    }
    private var selected: Int { service.state?.target ?? service.draftTarget }
    private var armedPhase: Bool { service.state?.phase == .armed }

    var body: some View {
        // Always present with the controls (dimmed while no level lies above the limit) so changing the limit never resizes the page.
        if model.canShowChargeControls, model.usesNativeCharge {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                titleRow
                levelRow
                statusLines
            }
            .studioElement("charge.by", kind: "container", label: "Charge by time")
            .onAppear { if !levels.contains(service.draftTarget) { service.draftTarget = levels.last ?? 100 } }
            .onChange(of: limit) { _, _ in if !service.isArmed, !levels.contains(service.draftTarget) { service.draftTarget = levels.last ?? 100 } }
        }
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: 6) {
            StudioText(L10n.text("Charge by time"), id: "charge.by.title").font(.system(size: 14, weight: .semibold)).fixedSize()
            SectionInfoButton(title: L10n.text("Charge by time"), paragraphs: [
                L10n.text("Your Mac keeps its charge limit and Tilvero lifts it just in time, so the battery reaches the chosen level 10 minutes before the time you set."),
                L10n.text("While the Mac sleeps it wakes on a schedule, lifts the limit and goes back to sleep. This needs one permission; without it the limit is lifted when the Mac is about to sleep."),
                L10n.text("The start is an estimate from the adapter's power and what the Mac draws. Your previous limit returns when you unplug the adapter."),
            ], id: "charge-by-info")
            Spacer(minLength: 8)
            timePill
        }
    }

    private var timePill: some View {
        let active = service.isArmed
        return Button { service.message = nil; showsWheel = true } label: {
            StudioText(active ? Self.dayText(service.state!.deadline) : L10n.text("Pick a time"), id: "charge.by.time")
                .font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(service.isWorking || model.isApplying || (!active && (chargeOnceBlocks || levels.isEmpty)))
        .opacity(active || !levels.isEmpty ? 1 : 0.45)
        .popover(isPresented: $showsWheel, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { popover }
        .accessibilityLabel(L10n.text("Charge by time"))
        .studioElement("charge.by.pill", label: "Charge by time")
    }
    private var chargeOnceBlocks: Bool { model.chargeOnce.isActive }

    @ViewBuilder private var popover: some View {
        VStack(spacing: 10) {
            if service.state?.phase != .charging {
                SleepWheelPicker(mode: .until, initialMinutes: 30, initialDate: service.state?.deadline ?? Self.defaultDeadline(),
                    onCommit: { value in
                        showsWheel = false
                        guard case .until(let date) = value else { return }
                        Task { if service.isArmed { await service.setDeadline(date) } else { await service.arm(deadline: date, target: selected) } }
                    }, onCancel: { showsWheel = false })
            }
            if service.isArmed {
                Button { showsWheel = false; Task { await service.cancel() } } label: {
                    Text(L10n.text("Cancel plan")).font(.subheadline.weight(.medium)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Capsule().fill(Color.red.opacity(0.12))).contentShape(Capsule())
                }.buttonStyle(.plain).padding(.horizontal, 12)
            }
        }
        .frame(width: 244).padding(.vertical, 10)
    }

    // MARK: Level row

    private var levelRow: some View {
        let editable = service.state?.phase != .charging && !service.isWorking
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Self.strip, id: \.self) { level in
                    let on = levels.contains(level)
                    Button { choose(level) } label: {
                        Text("\(level)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(selected == level && on ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(selected == level && on ? Color.accentColor : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).disabled(!on).opacity(on ? 1 : 0.4)
                        .accessibilityLabel("\(level)%").accessibilityAddTraits(selected == level ? .isSelected : [])
                }
            }.padding(3).background(Color.primary.opacity(0.07), in: Capsule())
            let full = levels.contains(100)
            Button { choose(100) } label: {
                Text("100").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(selected == 100 && full ? Color.white : Color.primary)
                    .frame(width: 84, height: 32)
                    .background(Capsule().fill(selected == 100 && full ? Color.accentColor : Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
            }.buttonStyle(.plain).disabled(!full).opacity(full ? 1 : 0.4)
                .accessibilityLabel("100%").accessibilityAddTraits(selected == 100 ? .isSelected : [])
        }
        .disabled(!editable).opacity(editable ? 1 : 0.6)
    }
    private func choose(_ level: Int) {
        service.draftTarget = level
        if armedPhase { Task { await service.setTarget(level) } }
    }

    // MARK: Status

    @ViewBuilder private var statusLines: some View {
        if let line = status {
            Label { Text(line.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: line.symbol) }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(line.warning ? Color.orange : Color.primary)
        }
        if service.isArmed, !service.wakePermitted {
            Button { Task { _ = await service.installWakePermission() } } label: {
                Text(L10n.text("Allow charging during sleep…")).font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(Color.primary)
                    .background(Capsule().fill(Color.primary.opacity(0.07))).contentShape(Capsule())
            }.buttonStyle(.plain).studioElement("charge.by.permission", label: "Allow charging during sleep")
        }
    }

    struct Line: Equatable { var symbol: String; var text: String; var warning: Bool }
    var status: Line? {
        if let message = service.message { return Line(symbol: "exclamationmark.triangle", text: L10n.text(message), warning: true) }
        guard let state = service.state else { return nil }
        let ready = Self.clock(state.deadline.addingTimeInterval(-ChargeByPlanner.reserveSeconds))
        let observation = model.chargeByObservation
        if state.phase == .charging {
            if let plan = service.plan, !plan.reachesTarget {
                return Line(symbol: "exclamationmark.triangle", text: Self.fill("May not make it: about {level}% by {ready}", ["level": "\(Int(plan.expectedPercentAtReady.rounded()))", "ready": ready]), warning: true)
            }
            return Line(symbol: "bolt", text: Self.fill("Charging to {level}% · ready by {ready}", ["level": "\(state.target)", "ready": ready]), warning: false)
        }
        if observation.externalPower == false {
            return Line(symbol: "powerplug", text: Self.fill("Connect the adapter: without it the charge will not be ready by {time}", ["time": ready]), warning: true)
        }
        if let plan = service.plan, !plan.reachesTarget {
            return Line(symbol: "exclamationmark.triangle", text: Self.fill("May not make it: about {level}% by {ready}", ["level": "\(Int(plan.expectedPercentAtReady.rounded()))", "ready": ready]), warning: true)
        }
        if service.wakePermitted, !service.wakeConfirmed, state.startAt > Date().addingTimeInterval(ChargeByRule.wakeLead + 30) {
            return Line(symbol: "exclamationmark.triangle", text: L10n.text("The wake was not scheduled; the charge starts when the Mac goes to sleep"), warning: true)
        }
        return Line(symbol: "bolt.badge.clock", text: Self.fill("Starts at {start} · {level}% by {ready}", ["start": Self.clock(state.startAt), "level": "\(state.target)", "ready": ready]), warning: false)
    }

    // MARK: Text helpers

    static func fill(_ key: String, _ values: [String: String]) -> String {
        values.reduce(L10n.text(key)) { $0.replacingOccurrences(of: "{" + $1.key + "}", with: $1.value) }
    }
    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    static func dayText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) { day = L10n.text("Today") }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { day = L10n.text("Tomorrow") }
        else { day = date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)) }
        return day + " " + clock(date)
    }
    /// The next 08:00 that is at least an hour away.
    static func defaultDeadline(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var next = calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(8 * 3600)
        if next.timeIntervalSince(now) < 3600 { next = next.addingTimeInterval(86_400) }
        return next
    }
}
