// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerUIBridge
import PowerCore

/// macOS Optimized Battery Charging as the System Settings switch shows it, plus whether it holds the charge right now.
public struct OptimizedChargingState: Equatable, Sendable {
    public let enabled: Bool
    /// macOS is holding the battery (usually at 80 %) and plans to finish later.
    public let holding: Bool
    /// When macOS plans to have the battery full, if it has a plan.
    public let fullChargeBy: Date?
    public let collectedAt: Date
    public init(enabled: Bool, holding: Bool, fullChargeBy: Date?, collectedAt: Date = Date()) {
        self.enabled = enabled; self.holding = holding; self.fullChargeBy = fullChargeBy; self.collectedAt = collectedAt
    }
}

/// The three operations Tilvero uses: read, the switch itself, and macOS's own «until tomorrow» pause.
public protocol OptimizedChargingTransport: Sendable {
    func read() async throws -> OptimizedChargingState
    func setEnabled(_ enabled: Bool) async throws
    func pauseUntilTomorrow() async throws
}

/// The live PowerUI client (user space, the same service System Settings uses). Never used by default tests.
public actor PowerUIOptimizedChargingClient: OptimizedChargingTransport {
    public init() {}
    public func read() async throws -> OptimizedChargingState {
        let raw = try autoreleasepool { () throws -> [String: Any]? in
            var error: NSError?
            let value = TVOptimizedChargingRead(&error)
            if let error { throw error }
            return value
        }
        guard let raw, let enabled = raw["enabled"] as? Bool, let holding = raw["holding"] as? Bool else { throw PolicyError.readbackMismatch }
        return OptimizedChargingState(enabled: enabled, holding: enabled && holding, fullChargeBy: raw["deadline"] as? Date)
    }
    public func setEnabled(_ enabled: Bool) async throws {
        try autoreleasepool {
            var error: NSError?
            let success = TVOptimizedChargingSetEnabled(enabled, &error)
            if let error { throw error }
            guard success else { throw PolicyError.readbackMismatch }
        }
    }
    public func pauseUntilTomorrow() async throws {
        try autoreleasepool {
            var error: NSError?
            let success = TVOptimizedChargingPauseUntilTomorrow(&error)
            if let error { throw error }
            guard success else { throw PolicyError.readbackMismatch }
        }
    }
}

/// For builds and test runs that must never reach PowerUI: every call fails, so nothing is shown and nothing is written.
public struct UnavailableOptimizedChargingTransport: OptimizedChargingTransport {
    public init() {}
    public func read() async throws -> OptimizedChargingState { throw PolicyError.unavailable }
    public func setEnabled(_ enabled: Bool) async throws { throw PolicyError.unavailable }
    public func pauseUntilTomorrow() async throws { throw PolicyError.unavailable }
}
