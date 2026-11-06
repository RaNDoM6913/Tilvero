// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
import ChargeBackends

/// Evidence for a finite persistent-setting contract, never physical cutoff,
/// temporary overrides, helper authorization, or every offered target.
struct NativeChargeAdmission: Codable {
    static let version = 4
    static let semanticContract = "PowerUI-v4-persistent-80-85-90-95-100"
    /// The persistent states a local validation exercises (every one written, read back and restored). 100 is how
    /// macOS stores "limit off": enabled false, target 100, no registered manual limit.
    static let persistentTargets = [80, 85, 90, 95, 100]
    static let unlimitedTarget = 100
    /// A configuration the scoped journal may hold: an enabled limit at a verified target, or the limit off.
    static func isValidState(_ configuration: NativeChargeConfiguration) -> Bool {
        configuration.target == unlimitedTarget ? !configuration.enabled : configuration.enabled && persistentTargets.contains(configuration.target)
    }

    struct Scope: Equatable, Sendable {
        let environment: String
        let semanticContract: String
        let authorizedPersistentTargets: [Int]
        let optimizedCharging: Bool
        // Only a fully validated proof can construct production authority.
        fileprivate init(environment: String, optimizedCharging: Bool) {
            self.environment = environment; semanticContract = NativeChargeAdmission.semanticContract
            authorizedPersistentTargets = NativeChargeAdmission.persistentTargets
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
    /// One verified snapshot for every persistent target other than the baseline, in ascending target order.
    let stages: [NativeChargeSnapshot]
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
            && persistentTargets.allSatisfy(targets.contains)
    }

    /// A complete persistent state at `target`. By default a missing registry entry on battery power is accepted
    /// (`policyMatches`); validation evidence passes `strict: true` and then needs the registry to agree.
    static func isPersistent(_ value: NativeChargeSnapshot, target: Int, optimizedCharging: Bool, strict: Bool = false) -> Bool {
        let registryOK = strict ? value.registryAgrees : value.policyMatches
        if target == unlimitedTarget {
            return value.configuration == .init(enabled: false, target: unlimitedTarget, optimizedCharging: optimizedCharging)
                && registryOK && value.registeredManualLimit == nil && validOfferedTargets(value.supportedTargets)
        }
        return value.configuration == .init(enabled: true, target: target, optimizedCharging: optimizedCharging)
            && registryOK && (value.registeredManualLimit == target || (!strict && value.registeredManualLimit == nil && !value.registrationExpected))
            && validOfferedTargets(value.supportedTargets)
    }

    static func loadScope(from url: URL, environment: String) -> Scope? {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return validatedScope(value, environment: environment)
    }

    static func validatedScope(_ value: Self, environment: String) -> Scope? {
        guard value.version == version, value.environment == environment, !environment.isEmpty, environment != "unavailable",
              value.semanticContract == semanticContract, value.authorizedPersistentTargets == persistentTargets,
              validOfferedTargets(value.offeredTargets),
              value.offeredTargets == value.before.supportedTargets,
              value.stages.allSatisfy({ $0.supportedTargets == value.offeredTargets }),
              value.offeredTargets == value.restored.supportedTargets,
              value.baseline == value.before.configuration,
              persistentTargets.contains(value.baseline.target),
              isPersistent(value.before, target: value.baseline.target, optimizedCharging: value.baseline.optimizedCharging, strict: true),
              value.stages.map({ $0.configuration.target }) == persistentTargets.filter({ $0 != value.baseline.target }),
              value.stages.allSatisfy({ isPersistent($0, target: $0.configuration.target, optimizedCharging: value.baseline.optimizedCharging, strict: true) }),
              isPersistent(value.restored, target: value.baseline.target, optimizedCharging: value.baseline.optimizedCharging, strict: true),
              value.before.collectedAt <= (value.stages.first?.collectedAt ?? value.restored.collectedAt),
              zip(value.stages, value.stages.dropFirst()).allSatisfy({ $0.collectedAt <= $1.collectedAt }),
              (value.stages.last?.collectedAt ?? value.before.collectedAt) <= value.restored.collectedAt,
              value.restored.collectedAt <= value.completedAt,
              value.completedAt.timeIntervalSinceNow <= 5,
              value.before.collectedAt.timeIntervalSinceReferenceDate.isFinite,
              value.completedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return Scope(environment: environment, optimizedCharging: value.baseline.optimizedCharging)
    }

    static func load(from url: URL, environment: String) -> Bool { loadScope(from: url, environment: environment) != nil }
}
// tlv-origin:919104438672318b
