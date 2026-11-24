// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import ChargeBackends

/// macOS Optimized Battery Charging inside Tilvero: the same switch as System Settings › Battery, the «macOS is holding
/// the charge» state, and the «until tomorrow» pause a planned charge uses so macOS does not keep the battery at 80 %
/// past the time the user asked for. Every write is read back; what is shown is only what macOS reports.
@MainActor final class OptimizedChargingService: ObservableObject {
    /// What macOS reported last; nil while unread or unreadable (the row is then hidden, never guessed).
    @Published private(set) var state: OptimizedChargingState?
    /// The value a switch flip asked for, until macOS confirms it (the switch shows it meanwhile).
    @Published private(set) var requested: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var failure: String?

    private let transport: any OptimizedChargingTransport
    let allowed: Bool
    init(transport: any OptimizedChargingTransport, allowed: Bool) {
        self.transport = transport; self.allowed = allowed
    }

    var isAvailable: Bool { allowed && state != nil }
    /// What the switch shows: a pending request, else the confirmed state.
    var shownEnabled: Bool { requested ?? state?.enabled ?? false }

    func refresh() async {
        guard allowed, !isBusy else { return }
        state = try? await transport.read()
    }

    /// The switch. True only when macOS reads back the asked value.
    @discardableResult func setEnabled(_ enabled: Bool) async -> Bool {
        guard allowed, !isBusy else { return false }
        isBusy = true; requested = enabled; failure = nil
        defer { isBusy = false; requested = nil }
        try? await transport.setEnabled(enabled)
        let readback = try? await transport.read()
        state = readback ?? state
        guard readback?.enabled == enabled else {
            failure = "macOS did not change Optimized Battery Charging."
            return false
        }
        return true
    }

    /// For a planned charge: macOS's own «until tomorrow» pause, only when Optimized Charging is on (it turns itself back on).
    /// Nothing happens when it is off or unreadable. Never shows a prompt.
    @discardableResult func pauseForPlannedCharge() async -> Bool {
        guard allowed, !isBusy else { return false }
        if state == nil { state = try? await transport.read() }
        guard state?.enabled == true else { return false }
        isBusy = true; defer { isBusy = false }
        try? await transport.pauseUntilTomorrow()
        state = (try? await transport.read()) ?? state
        return state?.holding == false
    }
}

import SwiftUI

/// «Оптимизированная зарядка» with its switch (the System Settings one). In the window it also says when macOS is holding
/// the charge and until when it plans to finish. Hidden when macOS does not report the setting.
@MainActor struct OptimizedChargingRow: View {
    @ObservedObject var service: OptimizedChargingService
    var showsHold: Bool

    var body: some View {
        if service.isAvailable {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.text("Optimized charging")).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    SectionInfoButton(title: L10n.text("Optimized charging"), paragraphs: OptimizedChargingText.infoKeys.map(L10n.text),
                                      id: "optimized-charging-info")
                    Spacer(minLength: 8)
                    Toggle(L10n.text("Optimized charging"), isOn: Binding(get: { service.shownEnabled },
                                                                          set: { value in Task { await service.setEnabled(value) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(service.isBusy)
                        .accessibilityIdentifier("optimized-charging-switch")
                }
                if showsHold, let state = service.state, let line = OptimizedChargingText.holdLine(state) {
                    Label(line, systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let failure = service.failure {
                    Text(L10n.text(failure)).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// «Оптимизированная зарядка выключится до утра» under an armed charge-by plan, only while it is on.
@MainActor struct OptimizedChargingPlanNote: View {
    @ObservedObject var service: OptimizedChargingService
    var body: some View {
        if service.state?.enabled == true {
            Label(L10n.text("Optimized charging pauses until morning"), systemImage: "bolt.badge.clock")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
        }
    }
}

/// Texts of the optimized charging row (pure, testable).
enum OptimizedChargingText {
    static let infoKeys = [
        "The same switch as in System Settings › Battery. macOS learns your routine and may hold the battery at 80 % until shortly before you usually unplug.",
        "Charge by time pauses it until tomorrow, so the battery is full by the time you set. macOS turns it back on by itself.",
    ]
    /// «macOS придерживает заряд · полная к ≈ 11:19» while macOS holds the charge; nil otherwise. The time is macOS's own plan.
    static func holdLine(_ state: OptimizedChargingState) -> String? {
        guard state.enabled, state.holding else { return nil }
        let base = L10n.text("macOS is holding the charge")
        guard let by = state.fullChargeBy, by.timeIntervalSince(state.collectedAt) > 0 else { return base }
        return base + " · " + L10n.text("full by") + " ≈ " + by.formatted(.dateTime.hour().minute().locale(L10n.locale))
    }
}
