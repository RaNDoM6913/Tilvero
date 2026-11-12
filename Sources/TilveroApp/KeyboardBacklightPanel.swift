// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import KeyboardBackends

@MainActor struct KeyboardBacklightPanel: View {
    @ObservedObject var service: KeyboardBacklightService
    var body: some View {
        ProductSurface(studioID: "keyboard.editor") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(L10n.text("Keyboard backlight"), systemImage: "keyboard")
                        .font(.headline)
                    Spacer()
                    if service.isBusy { ProgressView().controlSize(.small) }
                    if service.isAvailable, let enabled = service.isEnabled {
                        Toggle(L10n.text("Keyboard backlight"), isOn: Binding(get: { enabled }, set: { value in
                            Task { await service.setEnabled(value) }
                        })).labelsHidden().toggleStyle(.switch)
                            .disabled(service.isBusy).accessibilityIdentifier("keyboard-backlight-toggle").studioElement("keyboard-backlight-toggle", label: "keyboard-backlight-toggle")
                    }
                    Button { Task { await service.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help(L10n.text("Refresh keyboard backlight"))
                        .accessibilityLabel(L10n.text("Refresh keyboard backlight"))
                        .disabled(service.isBusy)
                }
                if let observation = service.observation {
                    Text(L10n.text("macOS brightness setting") + ": " + observation.brightness.formatted(.percent.locale(L10n.locale).precision(.fractionLength(0))))
                        .font(.subheadline).monospacedDigit()
                    if service.isEnabled == nil {
                        Text(L10n.text("macOS has dimmed or suppressed the backlight. The setting does not confirm illuminated keys."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            StudioActionButton(L10n.text("Turn on"), id: "action.turn-on") { Task { await service.setEnabled(true) } }
                            StudioActionButton(L10n.text("Turn off"), id: "action.turn-off") { Task { await service.setEnabled(false) } }
                        }.disabled(service.isBusy)
                    }
                    Text(L10n.text(observation.automaticBrightness ? "Automatic keyboard brightness remains enabled in macOS." : "Automatic keyboard brightness is disabled in macOS."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Source") + ": macOS · " + observation.observedAt.formatted(.dateTime.hour().minute().second().locale(L10n.locale)))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !service.isBusy {
                    Text(L10n.text(service.error == .disabledInSimulation ? "Keyboard controls are unavailable in this build or simulation." : "Keyboard backlight state is unavailable."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = service.error, error != .disabledInSimulation {
                    Text(L10n.text(error.localizedDescription)).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("Turning on restores the last nonzero brightness; without a previous reading it requests 25%."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.refresh() }
        }
    }
}

/// Quick-menu row: on/off and brightness. Only user gestures write; opening the panel only reads.
@MainActor struct KeyboardBacklightQuickRow: View {
    @ObservedObject var service: KeyboardBacklightService
    @State private var draft = 0.0
    @State private var editing = false
    /// Set in the same turn as the release, so not even one frame shows the old reading before the service takes over.
    @State private var settling: Double?

    /// What the slider and the figure show: the drag, then the requested level until the write has settled, then the reading.
    private func shown(_ observation: KeyboardBacklightObservation) -> Double {
        editing ? draft : (settling ?? service.pendingBrightness ?? observation.brightness)
    }

    var body: some View {
        Group {
            if service.isAvailable, let observation = service.observation {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L10n.text("Keyboard backlight"), systemImage: "keyboard")
                        Spacer()
                        Toggle(L10n.text("Keyboard backlight"), isOn: Binding(get: { service.pendingEnabled ?? service.isEnabled ?? (observation.brightness > 0) },
                                                                                  set: { value in Task { await service.setEnabled(value) } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(service.isBusy)
                            .accessibilityIdentifier("quick-keyboard-backlight-toggle")
                            .studioElement("quick.keyboard.toggle", label: "Keyboard backlight switch")
                    }.font(.system(size: 13, weight: .medium))
                    HStack(spacing: 6) {
                        Image(systemName: "light.min").foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: Binding(get: { shown(observation) }, set: { draft = $0 }), in: 0...1,
                               onEditingChanged: { began in
                                   if began { draft = observation.brightness; editing = true }
                                   else { editing = false; let value = draft; settling = value; Task { await service.setBrightness(value); settling = nil } }
                               })
                            .allowsHitTesting(!service.isBusy)   // no visual change while a write settles (disabling dimmed the slider)
                            .accessibilityLabel(L10n.text("Keyboard backlight brightness"))
                            .accessibilityValue(Text(shown(observation).formatted(.percent.precision(.fractionLength(0)))))
                            .studioElement("quick.keyboard.slider", label: "Keyboard backlight brightness")
                        Image(systemName: "light.max").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(shown(observation).formatted(.percent.locale(L10n.locale).precision(.fractionLength(0))))
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.primary).frame(width: 46, alignment: .trailing)
                    }
                    if let error = service.error {
                        Text(L10n.text(error.localizedDescription)).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task { await service.refresh() }
    }
}
