// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore

/// Feeds the charge-by plan with the model's readings and applies limits through the slider's own verified path.
@MainActor final class ModelChargeByEnvironment: ChargeByEnvironment {
    private weak var model: TilveroModel?
    init(model: TilveroModel) { self.model = model }

    func observation() -> ChargeByObservation {
        guard let model else { return ChargeByObservation() }
        let snapshot = model.snapshot
        func usable(_ reading: TelemetryReading<Bool>) -> Bool? { reading.availability == .available && reading.freshness != .stale ? reading.value : nil }
        func catalog(_ id: String) -> Double? { snapshot.catalog.first { $0.id == id }?.value?.doubleValue }
        let percent = snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness != .stale ? snapshot.chargePercent.value.map(Double.init) : nil
        return ChargeByObservation(observedLimit: model.nativeCharge.reportedLimit, percent: percent, isCharging: usable(snapshot.isCharging),
                                   externalPower: usable(snapshot.isExternalPower), adapterWatts: catalog("050"),
                                   fullEnergyWh: Self.fullEnergyWh(catalog: catalog), systemWatts: catalog("043"),
                                   systemTimeToFullSeconds: catalog("069").flatMap { $0 > 0 ? $0 : nil })
    }

    /// No provider publishes 034/033 (Wh), so the plan's energy comes from the full capacity (030, mAh) and the pack voltage (035).
    static func fullEnergyWh(catalog: (String) -> Double?) -> Double? {
        catalog("034") ?? ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: catalog("030"), packVolts: catalog("035")) ?? catalog("033")
    }

    func pauseOptimizedCharging() async -> Bool { await model?.optimizedCharging.pauseForPlannedCharge() != .failed }

    func apply(limit: Int, expected: Int?) async -> ChargeByApplyResult {
        guard let model, !model.isDemo else { return .notWritten }
        // The user's own change (the slider, charge once) has the model: it goes first, this tick waits for the next one.
        guard !model.isApplying else { return .deferred }
        let leftover = model.nativeCharge.unresolvedSessionID
        do {
            // The service reads the limit fresh, refuses a changed one, writes and reads back: no further refresh is needed
            // (a later read failure must not turn a confirmed write into a reported failure). A user's release that claims
            // the model while this apply waits behind a background read wins: the service is never taken from it.
            try await model.nativeCharge.apply(limit, expectedCurrent: expected, yields: { [weak model] in model?.isApplying ?? true })
            return .confirmed
        } catch NativeChargeServiceError.changedElsewhere {
            return .changedElsewhere
        } catch {
            // Only a write this call dispatched can land late, and it leaves a session of its own on disk. Anything else
            // wrote nothing.
            if let session = model.nativeCharge.unresolvedSessionID, session != leftover { return .failed }
            // Momentary refusals: another apply or the user's own change holds the service, or the interface is not granted
            // yet (nothing read since launch). A gate still pending past its deadline is not momentary.
            let native = model.nativeCharge
            if let refusal = error as? NativeChargeServiceError,
               (refusal == .unavailable && !native.isMonitoringOnly) || (refusal == .busy && !native.operationPending) { return .deferred }
            return .notWritten
        }
    }
}
