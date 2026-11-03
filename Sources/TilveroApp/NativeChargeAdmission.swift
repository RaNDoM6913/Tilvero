import Foundation
import Darwin
import ChargeBackends

/// Evidence for a finite persistent-setting contract, never physical cutoff,
/// temporary overrides, helper authorization, or every offered target.
struct NativeChargeAdmission: Codable {
    static let version = 2
    static let semanticContract = "PowerUI-v2-persistent-pair90-95"
    static let persistentPair = [90, 95]

    struct Scope: Equatable, Sendable {
        let environment: String
        let semanticContract: String
        let authorizedPersistentTargets: [Int]
        let optimizedCharging: Bool
        // Only a fully validated proof can construct production authority.
        fileprivate init(environment: String, optimizedCharging: Bool) {
            self.environment = environment; semanticContract = NativeChargeAdmission.semanticContract
            authorizedPersistentTargets = NativeChargeAdmission.persistentPair
            self.optimizedCharging = optimizedCharging
        }
    }

    let version: Int
    let environment: String
    let semanticContract: String
    let authorizedPersistentTargets: [Int]
    let offeredTargets: [Int]
    let baseline: NativeChargeConfiguration
    let before: NativeChargeSnapshot
    let changed: NativeChargeSnapshot
    let restored: NativeChargeSnapshot
    let completedAt: Date

    static var currentEnvironment: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 && size < 256 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes) + " / " + ProcessInfo.processInfo.operatingSystemVersionString + " / " + semanticContract
    }

    static func validOfferedTargets(_ targets: [Int]) -> Bool {
        (1...21).contains(targets.count) && targets.allSatisfy { (80...100).contains($0) }
            && zip(targets, targets.dropFirst()).allSatisfy { $0 < $1 }
            && persistentPair.allSatisfy(targets.contains)
    }

    static func isPersistent(_ value: NativeChargeSnapshot, target: Int, optimizedCharging: Bool) -> Bool {
        value.configuration == .init(enabled: true, target: target, optimizedCharging: optimizedCharging)
            && value.policyMatches && value.registeredManualLimit == target && validOfferedTargets(value.supportedTargets)
    }

    static func loadScope(from url: URL, environment: String) -> Scope? {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return validatedScope(value, environment: environment)
    }

    static func validatedScope(_ value: Self, environment: String) -> Scope? {
        guard value.version == version, value.environment == environment, !environment.isEmpty, environment != "unavailable",
              value.semanticContract == semanticContract, value.authorizedPersistentTargets == persistentPair,
              validOfferedTargets(value.offeredTargets),
              value.offeredTargets == value.before.supportedTargets,
              value.offeredTargets == value.changed.supportedTargets,
              value.offeredTargets == value.restored.supportedTargets,
              value.baseline == value.before.configuration,
              isPersistent(value.before, target: 90, optimizedCharging: value.baseline.optimizedCharging),
              isPersistent(value.changed, target: 95, optimizedCharging: value.baseline.optimizedCharging),
              isPersistent(value.restored, target: 90, optimizedCharging: value.baseline.optimizedCharging),
              value.before.collectedAt <= value.changed.collectedAt,
              value.changed.collectedAt <= value.restored.collectedAt,
              value.restored.collectedAt <= value.completedAt,
              value.completedAt.timeIntervalSinceNow <= 5,
              value.before.collectedAt.timeIntervalSinceReferenceDate.isFinite,
              value.completedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return Scope(environment: environment, optimizedCharging: value.baseline.optimizedCharging)
    }

    static func load(from url: URL, environment: String) -> Bool { loadScope(from: url, environment: environment) != nil }
}
