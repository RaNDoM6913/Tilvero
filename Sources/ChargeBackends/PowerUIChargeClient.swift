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

/// Read-only observations from a failed complete-state read. These values never
/// describe a writable configuration or a restorable charging baseline.
public struct NativeChargeReadFailure: Error, LocalizedError, Sendable {
    public let supportedTargets: [Int]
    public let currentTarget: Int?
    public let rawManualState: UInt64?
    public let diagnosticStoredTarget: Int?
    /// Reader time only; the diagnostic source's own freshness is unknown.
    public let collectedAt: Date
    public static let currentTargetSource = "PowerUI.getMCLLimitWithError"
    public static let diagnosticStoredTargetSource = "PowerUI.powerLogStatus.chargeLimitTargetSoC"
    public static let diagnosticStoredTargetFreshness = "unknown"

    public init?(supportedTargets: [Int], currentTarget: Int? = nil, rawManualState: UInt64? = nil,
                 diagnosticStoredTarget: Int? = nil, collectedAt: Date = Date()) {
        guard (1...21).contains(supportedTargets.count),
              supportedTargets.allSatisfy({ (80...100).contains($0) }),
              zip(supportedTargets, supportedTargets.dropFirst()).allSatisfy({ $0 < $1 }),
              currentTarget.map({ supportedTargets.contains($0) }) ?? true,
              diagnosticStoredTarget.map({ supportedTargets.contains($0) }) ?? true else { return nil }
        self.supportedTargets = supportedTargets
        self.currentTarget = currentTarget; self.rawManualState = rawManualState
        self.diagnosticStoredTarget = diagnosticStoredTarget; self.collectedAt = collectedAt
    }
    /// Freshness applies only to an independently validated current reading.
    /// It never establishes freshness of the optional diagnostic source.
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(collectedAt)
        return currentTarget != nil && age >= -5 && age <= 65
    }
    public var errorDescription: String? {
        "macOS returned an unrecognized charging state. Apply remains unavailable until the native state is confirmed."
    }
}

/// Actor serialization keeps user-space calls off the UI thread and prevents
/// a second mutation while a slow XPC operation is still in flight.
public actor PowerUIChargeClient: NativeChargeTransport {
    public init() {}
    nonisolated static func readError(_ error: NSError) -> any Error {
        guard error.domain == "Tilvero.NativeCharge", error.code == 5,
              let raw = error.userInfo["supportedTargets"] as? [NSNumber],
              (1...21).contains(raw.count) else { return error }
        var targets: [Int] = []
        for value in raw {
            let number = value.doubleValue
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), number.isFinite,
                  (80...100).contains(number), number.rounded(.towardZero) == number else { return error }
            targets.append(Int(number))
        }
        return NativeChargeReadFailure(supportedTargets: targets,
            currentTarget: optionalTarget(error.userInfo["currentTarget"], supportedTargets: targets),
            rawManualState: optionalUnsignedInteger(error.userInfo["rawManualState"]),
            diagnosticStoredTarget: optionalTarget(error.userInfo["diagnosticStoredTarget"], supportedTargets: targets)) ?? error
    }
    private nonisolated static func optionalTarget(_ metadata: Any?, supportedTargets: [Int]) -> Int? {
        guard let value = metadata as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, let target = Int(exactly: number), supportedTargets.contains(target),
              value.decimalValue == Decimal(target) else { return nil }
        return target
    }
    private nonisolated static func optionalUnsignedInteger(_ metadata: Any?) -> UInt64? {
        guard let value = metadata as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        // Preserve the complete UInt64 domain before considering floating point.
        // A Double representation of UInt64.max rounds up beyond that domain.
        if let exact = UInt64(value.stringValue), value.decimalValue == NSNumber(value: exact).decimalValue { return exact }
        let number = value.doubleValue
        guard number.isFinite, let exact = UInt64(exactly: number),
              value.decimalValue == NSNumber(value: exact).decimalValue else { return nil }
        return exact
    }
    public func read() async throws -> NativeChargeSnapshot {
        let value = try autoreleasepool {
            var error: NSError?
            let value = TVNativeChargeRead(&error)
            if let error { throw Self.readError(error) }
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
