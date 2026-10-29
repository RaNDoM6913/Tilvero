import AppKit
import SwiftUI
import KeyboardBackends

@MainActor struct KeyboardBacklightPanel: View {
    @ObservedObject var service: KeyboardBacklightService
    var body: some View {
        ProductSurface {
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
                            .disabled(service.isBusy).accessibilityIdentifier("keyboard-backlight-toggle")
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
                            Button(L10n.text("Turn on")) { Task { await service.setEnabled(true) } }
                            Button(L10n.text("Turn off")) { Task { await service.setEnabled(false) } }
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
