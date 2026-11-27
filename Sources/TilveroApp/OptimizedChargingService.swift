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
        // A failure stays only until macOS reports the setting again.
        if state != nil { failure = nil }
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

    enum PauseResult: Equatable { case notNeeded, paused, failed }
    /// For a planned charge: macOS's own «until tomorrow» pause, only when Optimized Charging is on (it turns itself back on).
    /// Decided on a fresh read (never a cached one); nothing happens when it is off or unreadable. Never shows a prompt.
    /// A setting last known to be on that cannot be paused now (busy, unreadable, refused) is a failure, never "not needed".
    @discardableResult func pauseForPlannedCharge() async -> PauseResult {
        guard allowed else { return .notNeeded }
        let knownOn = (requested ?? state?.enabled) == true
        guard !isBusy else { return knownOn ? .failed : .notNeeded }
        isBusy = true; defer { isBusy = false }
        guard let fresh = try? await transport.read() else { return knownOn ? .failed : .notNeeded }
        state = fresh
        guard fresh.enabled else { return .notNeeded }
        do { try await transport.pauseUntilTomorrow() } catch {
            state = (try? await transport.read()) ?? state
            return .failed
        }
        let after = try? await transport.read()
        state = after ?? state
        // Not proof the pause holds until tomorrow (PowerUI reports no such state): only that macOS accepted it and is not
        // holding the charge right now. An unknown hold counts as failed.
        return after?.holding == false ? .paused : .failed
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

/// «Оптимизированная зарядка отключится до завтра» under an armed charge-by plan (the caller shows it only then), only while it is on.
@MainActor struct OptimizedChargingPlanNote: View {
    @ObservedObject var service: OptimizedChargingService
    var body: some View {
        if service.state?.enabled == true {
            Label(L10n.text("Optimized charging pauses until tomorrow"), systemImage: "bolt.badge.clock")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
        }
    }
}

/// Texts of the optimized charging row (pure, testable).
enum OptimizedChargingText {
    static let infoKeys = [
        "The System Settings › Battery switch. macOS may hold the battery at 80 % until shortly before you usually unplug.",
        "Charge by time pauses it until tomorrow so the battery is full on time; macOS turns it back on.",
    ]
    /// «macOS придерживает заряд · полный заряд к ≈ 11:19» while macOS holds the charge; nil otherwise. The time is macOS's own plan.
    static func holdLine(_ state: OptimizedChargingState) -> String? {
        guard state.enabled, state.holding == true else { return nil }
        guard let by = state.fullChargeBy, by.timeIntervalSince(state.collectedAt) > 0 else { return L10n.text("macOS is holding the charge") }
        return L10n.text("macOS is holding the charge · full by ≈ %@")
            .replacingOccurrences(of: "%@", with: by.formatted(.dateTime.hour().minute().locale(L10n.locale)))
    }
}
