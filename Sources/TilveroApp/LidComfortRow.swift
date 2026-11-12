// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// "Screen and sound" under the With lid closed switch (owner-chosen variant 5). Collapsed: title, info, the two levels
/// and a chevron. Tapping grows the quick menu in place and shows two full-width capsule sliders; tapping again folds it.
@MainActor struct LidComfortRow: View {
    @ObservedObject var model: TilveroModel
    @ObservedObject private var service: LidComfortService
    let mode: LidComfortMode
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: TilveroModel, mode: LidComfortMode, startsExpanded: Bool = false) {
        self.model = model; service = model.lidComfort; self.mode = mode; _expanded = State(initialValue: startsExpanded)
    }

    private var settings: LidComfortSettings { service.settings(for: mode) }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }

    var body: some View {
        if service.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                header
                if expanded {
                    LidComfortCapsule(icon: settings.dimDisplay ? "sun.max.fill" : "sun.max", name: L10n.text("Screen brightness"),
                                      level: settings.displayLevel, isOn: settings.dimDisplay,
                                      onToggle: { var next = settings; next.dimDisplay = $0; service.update(next, for: mode) },
                                      onCommit: { var next = settings; next.displayLevel = $0; service.update(next, for: mode) })
                        .transition(.opacity)
                    LidComfortCapsule(icon: settings.limitVolume ? "speaker.wave.2.fill" : "speaker.slash.fill", name: L10n.text("Volume"),
                                      level: settings.volumeLevel, isOn: settings.limitVolume,
                                      onToggle: { var next = settings; next.limitVolume = $0; service.update(next, for: mode) },
                                      onCommit: { var next = settings; next.volumeLevel = $0; service.update(next, for: mode) })
                        .transition(.opacity)
                }
            }
            .accessibilityIdentifier("lid-comfort-" + mode.rawValue)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L10n.text("Screen and sound")).font(.system(size: 14, weight: .semibold)).fixedSize()
            SectionInfoButton(title: L10n.text("When the lid is closed"), paragraphs: [
                L10n.text("When you close the lid, Tilvero turns the screen down and keeps the sound no louder than the levels you choose. A quieter setting is never raised."),
                L10n.text("When you open the lid, both return to what they were, unless you changed them meanwhile. The keyboard backlight turns off by itself. Keep Awake and the timer have separate settings."),
            ], id: "lid-comfort-info-" + mode.rawValue)
            Spacer(minLength: 8)
            if !expanded { summary.transition(.opacity) }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { expanded.toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? L10n.text("Expanded") : L10n.text("Collapsed"))
    }

    private var summary: some View {
        HStack(spacing: 10) {
            levelLabel(on: settings.dimDisplay, icon: "sun.max.fill", offIcon: "sun.max", text: percent(settings.displayLevel))
            levelLabel(on: settings.limitVolume, icon: "speaker.wave.2.fill", offIcon: "speaker.slash.fill", text: percent(settings.volumeLevel))
        }
    }
    private func levelLabel(on: Bool, icon: String, offIcon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? icon : offIcon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(on ? text : L10n.text("Off")).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }
}

/// A full-width capsule that is also the slider (5 % steps), with its own switch to the right.
@MainActor struct LidComfortCapsule: View {
    let icon: String
    let name: String
    let level: Double
    let isOn: Bool
    let onToggle: (Bool) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging: Double?
    private var shown: Double { dragging ?? level }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(isOn ? 0.09 : 0.05))
                    if isOn { Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: max(shown > 0 ? 40 : 0, proxy.size.width * shown)) }
                    HStack(spacing: 8) {
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(isOn && shown > 0.08 ? Color.primary : Color.secondary)
                        Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(isOn ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                        Text(isOn ? "\(Int((shown * 100).rounded())) %" : L10n.text("Off"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    }.padding(.horizontal, 14)
                }
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isOn, proxy.size.width > 0 else { return }
                        dragging = min(1, max(0, (value.location.x / proxy.size.width * 20).rounded() / 20))
                    }
                    .onEnded { _ in
                        if let dragging { onCommit(dragging) }
                        dragging = nil
                    })
            }
            .frame(height: 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(isOn ? "\(Int((shown * 100).rounded())) %" : L10n.text("Off"))
            .accessibilityAdjustableAction { direction in
                guard isOn else { return }
                let step = direction == .increment ? 0.05 : -0.05
                onCommit(min(1, max(0, ((level + step) * 20).rounded() / 20)))
            }
            Toggle(name, isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
        }
    }
}
