import XCTest
@testable import TilveroApp

final class SetupReadinessTests: XCTestCase {
    func testConstructionAndRepeatedReadsOnlyEvaluateSuppliedValues() {
        let inputs = SetupReadinessInputs()
        let first = SetupReadiness(inputs: inputs)
        let second = SetupReadiness(inputs: inputs)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.canContinueMonitoring)
        XCTAssertEqual(first.item(for: .monitoring).status, .ready)
        XCTAssertEqual(first.items.count, SetupFeature.allCases.count)
        // Inputs contain values only: no service, callback, clock, preference or host probe.
        XCTAssertEqual(first.inputs, inputs)
    }

    func testMonitoringRemainsUsableWithEveryOptionalControlBlocked() {
        var inputs = SetupReadinessInputs()
        inputs.launchPolicy = .monitoringOnly
        inputs.nativeCharge.availability = .unsupported
        inputs.fanAvailability = .unsupported
        inputs.keyboardBacklight = .unavailable
        let readiness = SetupReadiness(inputs: inputs)
        XCTAssertTrue(readiness.canContinueMonitoring)
        XCTAssertEqual(readiness.item(for: .monitoring).status, .ready)
        XCTAssertEqual(readiness.item(for: .nativeCharging).status, .unsupported)
        XCTAssertEqual(readiness.item(for: .keepAwake).reason, .monitoringSession)
        XCTAssertFalse(readiness.item(for: .keepAwake).actions.contains(.requestValidation(.keepAwake)))
    }

    func testIncompleteStateAndOldOSQualificationNeverBecomeReady() {
        var inputs = qualifiedInputs()
        inputs.nativeCharge.hasCompletePersistentState = false
        var readiness = SetupReadiness(inputs: inputs)
        XCTAssertEqual(readiness.item(for: .nativeCharging).status, .needsValidation)
        XCTAssertEqual(readiness.item(for: .nativeCharging).reason, .nativeStateUnknown)
        XCTAssertFalse(readiness.item(for: .nativeCharging).actions.contains(.requestValidation(.nativeCharging)))

        inputs.nativeCharge.hasCompletePersistentState = true
        inputs.nativeCharge.currentOSQualified = false
        inputs.nativeCharge.canSafelyRequestValidation = false
        readiness = SetupReadiness(inputs: inputs)
        XCTAssertEqual(readiness.item(for: .nativeCharging).reason, .currentOSValidationRequired)
        XCTAssertFalse(readiness.item(for: .nativeCharging).actions.contains(.requestValidation(.nativeCharging)))
        inputs.nativeCharge.canSafelyRequestValidation = true
        XCTAssertTrue(SetupReadiness(inputs: inputs).item(for: .nativeCharging).actions.contains(.requestValidation(.nativeCharging)))
    }

    func testHelperApprovalCannotReplaceTrustOrResourceQualification() {
        var inputs = qualifiedInputs()
        inputs.helper.registration = .enabled
        inputs.helper.sameTeamTrustVerified = false
        var row = SetupReadiness(inputs: inputs).item(for: .fans)
        XCTAssertEqual(row.status, .needsDeveloperPreparation)
        XCTAssertFalse(row.actions.contains(.registerHelper))

        inputs.helper.sameTeamTrustVerified = true
        inputs.fanAvailability = .unknown
        row = SetupReadiness(inputs: inputs).item(for: .fans)
        XCTAssertEqual(row.status, .needsValidation)
        XCTAssertFalse(row.actions.contains(.registerHelper))

        inputs.fanAvailability = .available
        inputs.helper.registration = .requiresApproval
        row = SetupReadiness(inputs: inputs).item(for: .fans)
        XCTAssertEqual(row.status, .needsOSApproval)
        XCTAssertTrue(row.actions.contains(.openApprovalSettings(.fans)))
        XCTAssertFalse(row.actions.contains(.registerHelper))
    }

    func testHelperEnrollmentIsOfferedOnlyWithVerifiedSupportedPrerequisites() {
        var inputs = qualifiedInputs()
        inputs.helper.registration = .notRegistered
        XCTAssertTrue(SetupReadiness(inputs: inputs).item(for: .fans).actions.contains(.registerHelper))
        inputs.helper.installedInApplications = false
        XCTAssertFalse(SetupReadiness(inputs: inputs).item(for: .fans).actions.contains(.registerHelper))
        inputs.helper.installedInApplications = true
        inputs.fanAvailability = .unknown
        XCTAssertFalse(SetupReadiness(inputs: inputs).item(for: .fans).actions.contains(.registerHelper))
        inputs.fanAvailability = .available
        inputs.helper.canRequestRegistration = false
        XCTAssertFalse(SetupReadiness(inputs: inputs).item(for: .fans).actions.contains(.registerHelper))
    }

    func testLoginAndHistoryAreIndependentOptionalChoices() {
        var inputs = qualifiedInputs()
        inputs.login = .notRegistered
        inputs.historyEnabled = false
        let readiness = SetupReadiness(inputs: inputs)
        XCTAssertEqual(readiness.item(for: .launchAtLogin).status, .optional)
        XCTAssertEqual(readiness.item(for: .history).status, .optional)
        XCTAssertTrue(readiness.canContinueMonitoring)
        inputs.login = .requiresApproval
        XCTAssertEqual(SetupReadiness(inputs: inputs).item(for: .launchAtLogin).status, .needsOSApproval)
        XCTAssertTrue(SetupReadiness(inputs: inputs).canContinueMonitoring)
    }

    func testOrdinaryFeaturesDoNotAcquirePrivacyOrHelperPermissions() {
        let readiness = SetupReadiness(inputs: qualifiedInputs())
        for feature in [SetupFeature.monitoring, .nativeCharging, .keyboardBacklight, .keepAwake, .sleepTimer, .history, .updateChecks] {
            XCTAssertEqual(readiness.item(for: feature).permission, .none, "\(feature) does not request blanket TCC or helper authority")
            XCTAssertFalse(readiness.item(for: feature).actions.contains(.registerHelper))
        }
    }

    func testFanlessHardwareAndDeniedApprovalRemainDifferent() {
        var inputs = qualifiedInputs()
        inputs.fanAvailability = .unsupported
        inputs.helper.registration = .denied
        let fanless = SetupReadiness(inputs: inputs).item(for: .fans)
        XCTAssertEqual(fanless.status, .unsupported)
        XCTAssertFalse(fanless.actions.contains(.openApprovalSettings(.fans)))
        inputs.fanAvailability = .available
        let denied = SetupReadiness(inputs: inputs).item(for: .fans)
        XCTAssertEqual(denied.status, .needsOSApproval)
        XCTAssertEqual(denied.reason, .approvalDenied)
    }

    func testPastReviewCannotAuthorizeChangedCurrentState() {
        var inputs = qualifiedInputs()
        let before = SetupReadiness(inputs: inputs)
        XCTAssertEqual(before.item(for: .nativeCharging).status, .ready)
        inputs.hasReviewedSetup = true
        inputs.nativeCharge.currentOSQualified = false
        inputs.helper.registration = .requiresApproval
        let after = SetupReadiness(inputs: inputs)
        XCTAssertEqual(after.item(for: .nativeCharging).status, .needsValidation)
        XCTAssertEqual(after.item(for: .fans).status, .needsOSApproval)
        inputs.hasReviewedSetup = false
        XCTAssertEqual(after.items, SetupReadiness(inputs: inputs).items)
    }

    func testClosedLidRequiresItsOwnTrialAndQualification() {
        var inputs = qualifiedInputs()
        inputs.closedLid.trialPrepared = false
        XCTAssertEqual(SetupReadiness(inputs: inputs).item(for: .closedLid).status, .needsDeveloperPreparation)
        inputs.closedLid.trialPrepared = true
        inputs.closedLid.currentEnvironmentQualified = false
        XCTAssertEqual(SetupReadiness(inputs: inputs).item(for: .closedLid).status, .needsValidation)
        inputs.closedLid.currentEnvironmentQualified = true
        inputs.closedLid.registration = .requiresApproval
        XCTAssertEqual(SetupReadiness(inputs: inputs).item(for: .closedLid).status, .needsOSApproval)
    }

    func testUpdateDistributionBlockerIsNotAnOSPermission() {
        var inputs = qualifiedInputs()
        inputs.updates.distributionPrepared = false
        let row = SetupReadiness(inputs: inputs).item(for: .updateInstallation)
        XCTAssertEqual(row.status, .needsDeveloperPreparation)
        XCTAssertEqual(row.permission, .none)
        XCTAssertEqual(row.actions, [.viewRequirements(.updateInstallation)])
        XCTAssertEqual(SetupReadiness(inputs: inputs).item(for: .updateChecks).status, .ready)
    }

    private func qualifiedInputs() -> SetupReadinessInputs {
        var inputs = SetupReadinessInputs()
        inputs.nativeCharge = .init(availability: .available, hasCompletePersistentState: true,
            currentOSQualified: true, canSafelyRequestValidation: true)
        inputs.helper = .init(sameTeamTrustVerified: true, installedInApplications: true,
            registration: .enabled, connected: true, canRequestRegistration: true)
        inputs.fanAvailability = .available
        inputs.helperPowerAvailability = .available
        inputs.keyboardBacklight = .available
        inputs.closedLid = .init(availability: .available, trialPrepared: true,
            currentEnvironmentQualified: true, registration: .enabled)
        inputs.updates = .init(distributionPrepared: true, hostEligible: true, controlsIdle: true)
        return inputs
    }
}
