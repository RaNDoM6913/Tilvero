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
        return ChargeByObservation(observedLimit: model.observedNativeLimit, percent: percent, isCharging: usable(snapshot.isCharging),
                                   externalPower: usable(snapshot.isExternalPower), adapterWatts: catalog("050"),
                                   fullEnergyWh: Self.fullEnergyWh(catalog: catalog), systemWatts: catalog("043"))
    }

    /// No provider publishes 034/033 (Wh), so the plan's energy comes from the full capacity (030, mAh) and the pack voltage (035).
    static func fullEnergyWh(catalog: (String) -> Double?) -> Double? {
        catalog("034") ?? ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: catalog("030"), packVolts: catalog("035")) ?? catalog("033")
    }

    func apply(limit: Int) async -> Bool {
        guard let model, !model.isApplying else { return false }
        let percent = model.snapshot.chargePercent.value
        do {
            // The service reads the battery itself (fresh) for its safety checks; the model's snapshot may be stale after a wake.
            try await model.nativeCharge.apply(limit, batteryPercent: percent, batteryFresh: true)
            await model.nativeCharge.refresh()
            return model.observedNativeLimit == limit || model.nativeCharge.pendingTarget == limit
        } catch { return false }
    }
}
