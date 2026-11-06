// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore
import PowerPrivileged
import ServiceManagement

/// Setup only enables login. The Settings toggle keeps its own behavior.
@MainActor struct SetupLoginPort {
    let readStatus: () -> SetupRegistrationState
    let register: () throws -> Void
    let openApprovalSettings: () -> Void

    func enable() throws {
        switch readStatus() {
        case .enabled: return
        case .notRegistered: try register()
        default: throw SetupRuntimeError.actionUnavailable
        }
    }

    static var native: Self {
        Self(readStatus: {
            switch SMAppService.mainApp.status {
            case .enabled: .enabled
            case .notRegistered: .notRegistered
            case .requiresApproval: .requiresApproval
            case .notFound: .unavailable
            @unknown default: .unknown
            }
        }, register: { try SMAppService.mainApp.register() },
           openApprovalSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}

enum SetupRuntimeError: LocalizedError {
    case actionUnavailable
    var errorDescription: String? { "This setup action is no longer available." }
}

enum SetupRuntime {
    static let reviewedKey = "setupReviewed.v1"

    static func launchPolicy(_ policy: AppLaunchPolicy) -> SetupLaunchPolicy {
        if policy.monitoringOnly { return .monitoringOnly }
        return policy.ordinaryHardwarePolicy.monitoringOnly ? .dedicatedLidTrial : .ordinaryControls
    }

    static func availability(_ readiness: BackendReadiness?) -> SetupAvailability {
        switch readiness {
        case .available: .available
        case .unavailable: .unavailable
        case .unknown, .needsAuthorization, .unverified, nil: .unknown
        }
    }

    static func registration(_ state: HelperInstallationState) -> SetupRegistrationState {
        switch state {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound, .unavailable: .unavailable
        }
    }

    static func updates(bundle: Bundle, eligiblePolicy: Bool, controlsIdle: () -> Bool) -> SetupUpdateInputs {
        let configuration = UpdateInstallConfiguration(info: bundle.infoDictionary ?? [:])
        guard configuration.blockers.isEmpty else { return SetupUpdateInputs() }
        let eligible = eligiblePolicy && UpdateInstallHostFacts.inspect(bundle: bundle, configuration: configuration)
            .blockers(configuration: configuration).isEmpty
        return SetupUpdateInputs(distributionPrepared: true, hostEligible: eligible,
                                 controlsIdle: eligible && controlsIdle())
    }
}
