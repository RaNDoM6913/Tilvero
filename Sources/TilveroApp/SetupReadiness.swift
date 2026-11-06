/// Read-only setup facts supplied by the owning services. This model has no host,
/// preference, clock, permission or hardware access and cannot perform an action.
struct SetupReadinessInputs: Equatable, Sendable {
    var launchPolicy: SetupLaunchPolicy = .ordinaryControls
    var monitoring: SetupAvailability = .available
    var nativeCharge = SetupNativeChargeInputs()
    var helper = SetupHelperInputs()
    var fanAvailability: SetupAvailability = .unknown
    var helperPowerAvailability: SetupAvailability = .unknown
    var keyboardBacklight: SetupAvailability = .unknown
    var keepAwake: SetupAvailability = .available
    var sleepTimer: SetupAvailability = .available
    var closedLid = SetupClosedLidInputs()
    var historyEnabled = false
    var login: SetupRegistrationState = .unknown
    var updateChecks: SetupAvailability = .available
    var updates = SetupUpdateInputs()
    /// Presentation history only. A previous review never grants current authority.
    var hasReviewedSetup = false
}

enum SetupLaunchPolicy: Equatable, Sendable {
    case monitoringOnly, ordinaryControls, dedicatedLidTrial
}

enum SetupAvailability: Equatable, Sendable {
    case available, unknown, unavailable, unsupported
}

enum SetupRegistrationState: Equatable, Sendable {
    case unknown, notRegistered, enabled, requiresApproval, denied, unavailable
}

struct SetupNativeChargeInputs: Equatable, Sendable {
    var availability: SetupAvailability = .unknown
    var hasCompletePersistentState = false
    var currentOSQualified = false
    /// Must come from the existing safe qualification gate, never from setup itself.
    var canSafelyRequestValidation = false
}

struct SetupHelperInputs: Equatable, Sendable {
    var sameTeamTrustVerified = false
    var installedInApplications = false
    var registration: SetupRegistrationState = .unknown
    var connected = false
    /// Existing service gate, including busy/termination and capability checks.
    var canRequestRegistration = false
    var restorationRequired = false
}

struct SetupClosedLidInputs: Equatable, Sendable {
    var availability: SetupAvailability = .unknown
    /// Includes the dedicated signed trial host/helper and its exact trust checks.
    var trialPrepared = false
    var currentEnvironmentQualified = false
    var registration: SetupRegistrationState = .unknown
    var restorationRequired = false
}

struct SetupUpdateInputs: Equatable, Sendable {
    /// Distribution signing/feed/key preparation, separate from local helper signing.
    var distributionPrepared = false
    var hostEligible = false
    var controlsIdle = false
}

enum SetupFeature: String, CaseIterable, Identifiable, Sendable {
    case monitoring, nativeCharging, fans, helperPowerModes, keyboardBacklight
    case keepAwake, sleepTimer, closedLid, history, launchAtLogin, updateChecks, updateInstallation
    var id: Self { self }
}

enum SetupReadinessStatus: Equatable, Sendable {
    case ready, optional, needsOSApproval, needsValidation, unsupported, needsDeveloperPreparation
}

enum SetupReadinessReason: Equatable, Sendable {
    case available, optionalChoice, statusUnknown, monitoringSession, nativeStateUnknown
    case currentOSValidationRequired, hardwareUnsupported, capabilityUnavailable, hardwareValidationRequired
    case signedBuildRequired, installationRequired, helperNotRegistered, approvalRequired, approvalDenied
    case helperConnectionUnverified, restorationRequired, dedicatedTrialRequired
    case updateDistributionRequired, updateHostIneligible, controlsBusy
}

enum SetupPermission: Equatable, Sendable {
    case none, helperApproval, loginItemApproval, closedLidApproval
}

/// Action descriptions only. Execution must remain an explicit, separately wired port.
/// No action means that setup must not offer to bypass the owning service's gate.
enum SetupAction: Equatable, Identifiable, Sendable {
    case refresh(SetupFeature)
    case viewRequirements(SetupFeature)
    case openApprovalSettings(SetupFeature)
    case registerHelper
    case enableLogin
    case setHistoryEnabled(Bool)
    case requestValidation(SetupFeature)

    var id: String {
        switch self {
        case .refresh(let feature): "refresh." + feature.rawValue
        case .viewRequirements(let feature): "requirements." + feature.rawValue
        case .openApprovalSettings(let feature): "approval." + feature.rawValue
        case .registerHelper: "registerHelper"
        case .enableLogin: "enableLogin"
        case .setHistoryEnabled(let enabled): "history." + String(enabled)
        case .requestValidation(let feature): "validation." + feature.rawValue
        }
    }
}

struct SetupReadinessItem: Equatable, Identifiable, Sendable {
    let feature: SetupFeature
    let status: SetupReadinessStatus
    let reason: SetupReadinessReason
    let permission: SetupPermission
    let actions: [SetupAction]
    var id: SetupFeature { feature }
}

struct SetupReadiness: Equatable, Sendable {
    let inputs: SetupReadinessInputs
    let items: [SetupReadinessItem]
    /// Missing telemetry and unavailable optional controls do not lock setup.
    var canContinueMonitoring: Bool { true }

    init(inputs: SetupReadinessInputs) {
        self.inputs = inputs
        items = SetupFeature.allCases.map { Self.evaluate($0, inputs: inputs) }
    }

    func item(for feature: SetupFeature) -> SetupReadinessItem {
        // Every known feature is always present, with stable identity.
        items.first { $0.feature == feature }!
    }

    private static func evaluate(_ feature: SetupFeature, inputs: SetupReadinessInputs) -> SetupReadinessItem {
        switch feature {
        case .monitoring:
            return availability(inputs.monitoring, feature: feature)
        case .nativeCharging:
            if inputs.nativeCharge.availability == .unsupported { return unsupported(feature) }
            guard inputs.launchPolicy == .ordinaryControls else { return monitoringSession(feature) }
            guard inputs.nativeCharge.availability == .available else {
                return row(feature, .needsValidation,
                    inputs.nativeCharge.availability == .unavailable ? .capabilityUnavailable : .nativeStateUnknown,
                    actions: [.refresh(feature), .viewRequirements(feature)])
            }
            guard inputs.nativeCharge.hasCompletePersistentState else {
                return row(feature, .needsValidation, .nativeStateUnknown,
                    actions: [.refresh(feature), .viewRequirements(feature)])
            }
            guard inputs.nativeCharge.currentOSQualified else {
                var actions: [SetupAction] = [.refresh(feature), .viewRequirements(feature)]
                if inputs.nativeCharge.canSafelyRequestValidation { actions.append(.requestValidation(feature)) }
                return row(feature, .needsValidation, .currentOSValidationRequired, actions: actions)
            }
            return row(feature, .ready, .available)
        case .fans:
            return helperReadiness(feature, capability: inputs.fanAvailability, inputs: inputs)
        case .helperPowerModes:
            return helperReadiness(feature, capability: inputs.helperPowerAvailability, inputs: inputs)
        case .keyboardBacklight:
            if inputs.keyboardBacklight == .unsupported { return unsupported(feature) }
            guard inputs.launchPolicy == .ordinaryControls else { return monitoringSession(feature) }
            return availability(inputs.keyboardBacklight, feature: feature)
        case .keepAwake, .sleepTimer:
            let available = feature == .keepAwake ? inputs.keepAwake : inputs.sleepTimer
            if available == .unsupported { return unsupported(feature) }
            guard inputs.launchPolicy != .monitoringOnly else { return monitoringSession(feature) }
            return availability(available, feature: feature)
        case .closedLid:
            return closedLidReadiness(inputs)
        case .history:
            return row(feature, inputs.historyEnabled ? .ready : .optional,
                inputs.historyEnabled ? .available : .optionalChoice,
                actions: [.setHistoryEnabled(!inputs.historyEnabled)])
        case .launchAtLogin:
            return loginReadiness(inputs.login)
        case .updateChecks:
            return availability(inputs.updateChecks, feature: feature)
        case .updateInstallation:
            guard inputs.updates.distributionPrepared else {
                return row(feature, .needsDeveloperPreparation, .updateDistributionRequired,
                    actions: [.viewRequirements(feature)])
            }
            guard inputs.updates.hostEligible else {
                return row(feature, .needsDeveloperPreparation, .updateHostIneligible,
                    actions: [.viewRequirements(feature)])
            }
            guard inputs.updates.controlsIdle else {
                return row(feature, .needsValidation, .controlsBusy,
                    actions: [.refresh(feature), .viewRequirements(feature)])
            }
            // This is host readiness only; the installer still admits each actual candidate.
            return row(feature, .ready, .available)
        }
    }

    private static func helperReadiness(_ feature: SetupFeature, capability: SetupAvailability,
                                        inputs: SetupReadinessInputs) -> SetupReadinessItem {
        if capability == .unsupported { return unsupported(feature) }
        guard inputs.launchPolicy == .ordinaryControls else { return monitoringSession(feature) }
        let helper = inputs.helper
        guard !helper.restorationRequired else {
            return row(feature, .needsValidation, .restorationRequired, permission: .helperApproval,
                actions: [.refresh(feature), .viewRequirements(feature)])
        }
        guard helper.sameTeamTrustVerified else {
            return row(feature, .needsDeveloperPreparation, .signedBuildRequired, permission: .helperApproval,
                actions: [.viewRequirements(feature)])
        }
        guard helper.installedInApplications else {
            return row(feature, .needsDeveloperPreparation, .installationRequired, permission: .helperApproval,
                actions: [.viewRequirements(feature)])
        }
        guard capability == .available else {
            return row(feature, .needsValidation,
                capability == .unavailable ? .capabilityUnavailable : .hardwareValidationRequired,
                permission: .helperApproval, actions: [.refresh(feature), .viewRequirements(feature)])
        }
        switch helper.registration {
        case .enabled:
            return helper.connected
                ? row(feature, .ready, .available, permission: .helperApproval)
                : row(feature, .needsValidation, .helperConnectionUnverified, permission: .helperApproval,
                    actions: [.refresh(feature)])
        case .requiresApproval, .denied:
            return approval(feature, registration: helper.registration, permission: .helperApproval)
        case .notRegistered:
            guard helper.canRequestRegistration else {
                return row(feature, .needsValidation, .capabilityUnavailable, permission: .helperApproval,
                    actions: [.refresh(feature), .viewRequirements(feature)])
            }
            return row(feature, .optional, .helperNotRegistered, permission: .helperApproval,
                actions: [.registerHelper, .refresh(feature), .viewRequirements(feature)])
        case .unknown, .unavailable:
            return row(feature, .needsValidation,
                helper.registration == .unknown ? .statusUnknown : .capabilityUnavailable,
                permission: .helperApproval, actions: [.refresh(feature)])
        }
    }

    private static func closedLidReadiness(_ inputs: SetupReadinessInputs) -> SetupReadinessItem {
        let feature = SetupFeature.closedLid
        let lid = inputs.closedLid
        if lid.availability == .unsupported { return unsupported(feature) }
        guard inputs.launchPolicy != .monitoringOnly else { return monitoringSession(feature) }
        guard !lid.restorationRequired else {
            return row(feature, .needsValidation, .restorationRequired, permission: .closedLidApproval,
                actions: [.refresh(feature), .viewRequirements(feature)])
        }
        guard lid.trialPrepared else {
            return row(feature, .needsDeveloperPreparation, .dedicatedTrialRequired,
                permission: .closedLidApproval, actions: [.viewRequirements(feature)])
        }
        guard lid.availability == .available, lid.currentEnvironmentQualified else {
            return row(feature, .needsValidation, .hardwareValidationRequired,
                permission: .closedLidApproval, actions: [.refresh(feature), .viewRequirements(feature)])
        }
        switch lid.registration {
        case .enabled:
            return row(feature, .ready, .available, permission: .closedLidApproval)
        case .requiresApproval, .denied:
            return approval(feature, registration: lid.registration, permission: .closedLidApproval)
        case .unknown, .notRegistered, .unavailable:
            // Dedicated enrollment is owned by the trial, never the ordinary helper action.
            return row(feature, .needsValidation, .statusUnknown, permission: .closedLidApproval,
                actions: [.refresh(feature), .viewRequirements(feature)])
        }
    }

    private static func loginReadiness(_ registration: SetupRegistrationState) -> SetupReadinessItem {
        let feature = SetupFeature.launchAtLogin
        switch registration {
        case .enabled:
            return row(feature, .ready, .available, permission: .loginItemApproval)
        case .notRegistered:
            return row(feature, .optional, .optionalChoice, permission: .loginItemApproval,
                actions: [.enableLogin])
        case .requiresApproval, .denied:
            return approval(feature, registration: registration, permission: .loginItemApproval)
        case .unknown, .unavailable:
            return row(feature, .needsValidation,
                registration == .unknown ? .statusUnknown : .capabilityUnavailable,
                permission: .loginItemApproval, actions: [.refresh(feature)])
        }
    }

    private static func approval(_ feature: SetupFeature, registration: SetupRegistrationState,
                                 permission: SetupPermission) -> SetupReadinessItem {
        row(feature, .needsOSApproval, registration == .denied ? .approvalDenied : .approvalRequired,
            permission: permission, actions: [.openApprovalSettings(feature), .refresh(feature)])
    }

    private static func availability(_ value: SetupAvailability, feature: SetupFeature) -> SetupReadinessItem {
        switch value {
        case .available: row(feature, .ready, .available)
        case .unsupported: unsupported(feature)
        case .unknown: row(feature, .needsValidation, .statusUnknown, actions: [.refresh(feature)])
        case .unavailable: row(feature, .needsValidation, .capabilityUnavailable, actions: [.refresh(feature)])
        }
    }

    private static func unsupported(_ feature: SetupFeature) -> SetupReadinessItem {
        row(feature, .unsupported, .hardwareUnsupported)
    }

    private static func monitoringSession(_ feature: SetupFeature) -> SetupReadinessItem {
        row(feature, .needsValidation, .monitoringSession, actions: [.viewRequirements(feature)])
    }

    private static func row(_ feature: SetupFeature, _ status: SetupReadinessStatus,
                            _ reason: SetupReadinessReason, permission: SetupPermission = .none,
                            actions: [SetupAction] = []) -> SetupReadinessItem {
        .init(feature: feature, status: status, reason: reason, permission: permission, actions: actions)
    }

}
