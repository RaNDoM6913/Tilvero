// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Immutable for this process. No preference or later UI action promotes a
/// monitoring session into a controller session.
struct AppLaunchPolicy: Equatable {
    static let knownBundleIdentifiers: Set<String> = [
        "local.tilvero.prototype", "io.github.random6913.tilvero", "local.tilvero.lab", "local.tilvero.lidtrial"
    ]
    private enum Reason: Equatable { case release, requested, sibling, leaseUnavailable, simulation }
    private let reason: Reason?
    private let lidTrialOnly: Bool
    var monitoringOnly: Bool { reason != nil }
    /// The lid trial never admits charging, fans or the ordinary privileged helper.
    /// Awake and the dedicated lid service still honor the original launch policy.
    var ordinaryHardwarePolicy: Self {
        lidTrialOnly && !monitoringOnly ? Self(reason: .release, lidTrialOnly: true) : self
    }
    var monitoringReasonKey: String? {
        switch reason {
        case .release: "This build runs a monitoring-only session."
        case .requested: "Monitoring-only session was selected at launch."
        case .sibling: "Another Tilvero is running. This session monitors only; reopen it after the other app quits to use controls."
        case .leaseUnavailable: "Exclusive control is unavailable. This session monitors only; reopen it when the other controller has finished."
        case .simulation: nil // Existing simulation labeling remains authoritative.
        case nil: nil
        }
    }

    static func resolve(metadata: [String: Any], arguments: [String] = [], runningBundleIdentifiers: Set<String> = []) -> Self {
        let trial = metadata["CFBundleIdentifier"] as? String == ReleaseIdentity.lidTrialBundleIdentifier
        func policy(_ reason: Reason?) -> Self { Self(reason: reason, lidTrialOnly: trial) }
        if metadata["TilveroReleaseMode"] as? String == "monitoring" { return policy(.release) }
        if arguments.contains("--monitor-only") { return policy(.requested) }
        if arguments.contains("--demo") { return policy(.simulation) }
        if !knownBundleIdentifiers.isDisjoint(with: runningBundleIdentifiers) { return policy(.sibling) }
        return policy(nil)
    }

    static func current(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments) -> Self {
        resolve(metadata: bundle.infoDictionary ?? [:], arguments: arguments)
    }

    func tighteningForUnavailableController() -> Self {
        monitoringOnly ? self : Self(reason: .leaseUnavailable, lidTrialOnly: lidTrialOnly)
    }
}
