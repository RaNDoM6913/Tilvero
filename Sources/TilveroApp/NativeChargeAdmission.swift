// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
import ChargeBackends

/// The finite persistent-setting contract of the native charge limit: the levels macOS offers in System Settings, how a
/// valid stored state looks, and when the live interface grants the limit. Never physical cutoff, temporary overrides or
/// helper authorization.
enum NativeChargeAdmission {
    /// Part of every session journal: a journal written under another contract is never acted on.
    static let semanticContract = "PowerUI-v4-persistent-80-85-90-95-100"
    /// The persistent levels (as in System Settings). 100 is how macOS stores "limit off": enabled false, target 100, no
    /// registered manual limit.
    static let persistentTargets = [80, 85, 90, 95, 100]
    static let unlimitedTarget = 100

    /// Owner decision 2026-11-26: the limit is always usable, at any charge level and after every macOS update, without a
    /// separate validation run. Authority comes from the live interface itself: a fresh read through the checked PowerUI
    /// bridge that offers every persistent level and holds a valid state. Every write is still journaled first and read back.
    static func grants(_ value: NativeChargeSnapshot) -> Bool {
        value.isFresh && validOfferedTargets(value.supportedTargets) && isValidState(value.configuration)
    }

    /// The same Mac and charge contract, whatever the macOS version between them ("model / OS / contract"): a session
    /// journal stays readable across a macOS update. Other formats (fixtures) compare exactly.
    static func sameMachine(_ a: String, _ b: String) -> Bool {
        let x = a.components(separatedBy: " / "), y = b.components(separatedBy: " / ")
        guard x.count == 3, y.count == 3 else { return a == b }
        return x[0] == y[0] && x[2] == y[2] && !x[0].isEmpty
    }

    /// A configuration Tilvero recognises: an enabled limit at a persistent level, or the limit off.
    static func isValidState(_ configuration: NativeChargeConfiguration) -> Bool {
        configuration.target == unlimitedTarget ? !configuration.enabled : configuration.enabled && persistentTargets.contains(configuration.target)
    }

    /// A stored state the registry confirms: fresh, a valid state, the offered levels and `policyMatches` (the registry on
    /// AC; on battery power the stored setting itself).
    static func isConfirmed(_ value: NativeChargeSnapshot) -> Bool {
        grants(value) && value.policyMatches
    }

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
}
// tlv-origin:919104438672318b
