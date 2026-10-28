import Foundation
import PowerUIBridge
import PowerCore

public struct NativeChargeConfiguration: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let target: Int
    public let optimizedCharging: Bool
    public init(enabled: Bool, target: Int, optimizedCharging: Bool) {
        self.enabled = enabled; self.target = target; self.optimizedCharging = optimizedCharging
    }
    /// OBC is observed, never owned or modified by this adapter.
    public func matchesManual(_ other: Self) -> Bool { enabled == other.enabled && target == other.target }
}
public struct NativeChargeSnapshot: Codable, Equatable, Sendable {
    public let configuration: NativeChargeConfiguration
    public let supportedTargets: [Int]
    public let registeredManualLimit: Int?
    public let policyReadbackAvailable: Bool
    public let collectedAt: Date
    public init(configuration: NativeChargeConfiguration, supportedTargets: [Int], registeredManualLimit: Int?, policyReadbackAvailable: Bool = true, collectedAt: Date = Date()) {
        self.configuration = configuration; self.supportedTargets = supportedTargets
        self.registeredManualLimit = registeredManualLimit; self.policyReadbackAvailable = policyReadbackAvailable; self.collectedAt = collectedAt
    }
    public var isFresh: Bool { let age = Date().timeIntervalSince(collectedAt); return age >= -5 && age <= 65 }
    public var policyMatches: Bool {
        policyReadbackAvailable && (configuration.enabled ? registeredManualLimit == configuration.target : registeredManualLimit == nil)
    }
}
public protocol NativeChargeTransport: Sendable {
    func read() async throws -> NativeChargeSnapshot
    func setLimit(_ target: Int) async throws
    func setEnabled(_ enabled: Bool) async throws
}

/// Actor serialization keeps user-space calls off the UI thread and prevents
/// a second mutation while a slow XPC operation is still in flight.
public actor PowerUIChargeClient: NativeChargeTransport {
    public init() {}
    public func read() async throws -> NativeChargeSnapshot {
        let value = try autoreleasepool {
            var error: NSError?
            let value = TVNativeChargeRead(&error)
            if let error { throw error }
            return value
        }
        guard let raw = value, let enabled = raw["enabled"] as? Bool, let target = raw["target"] as? Int,
              let optimized = raw["optimizedCharging"] as? Bool, let targets = raw["targets"] as? [Int],
              (80...100).contains(target), targets == targets.sorted(), Set(targets).count == targets.count,
              !targets.isEmpty, targets.allSatisfy({ (80...100).contains($0) }) else { throw PolicyError.readbackMismatch }
        let limits = try? SystemChargeLimitParser.parse(BoundedProcess.read(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"]))
        return .init(configuration: .init(enabled: enabled, target: target, optimizedCharging: optimized), supportedTargets: targets,
                     registeredManualLimit: limits?.manualLimit,
                     policyReadbackAvailable: limits != nil && limits?.manualLimitIsConflicting == false)
    }
    public func setLimit(_ target: Int) async throws {
        guard (80...100).contains(target) else { throw PolicyError.unsupportedTarget }
        try autoreleasepool {
            var error: NSError?
            let success = TVNativeChargeSetLimit(UInt8(target), &error)
            if let error { throw error }
            guard success else { throw PolicyError.readbackMismatch }
        }
    }
    public func setEnabled(_ enabled: Bool) async throws {
        try autoreleasepool {
            var error: NSError?
            let success = TVNativeChargeSetEnabled(enabled, &error)
            if let error { throw error }
            guard success else { throw PolicyError.readbackMismatch }
        }
    }
}
