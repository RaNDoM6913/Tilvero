import XCTest
@testable import TilveroApp

@MainActor final class SetupActionCoordinatorTests: XCTestCase {
    func testConstructionAndRefreshNeverInvokeActionPorts() async {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        XCTAssertEqual(fixture.reads, 0)
        XCTAssertTrue(fixture.effects.isEmpty)

        fixture.inputs.nativeCharge.canSafelyRequestValidation = true
        let readiness = await coordinator.refresh()
        XCTAssertEqual(readiness.inputs, fixture.inputs)
        XCTAssertEqual(fixture.reads, 1)
        XCTAssertTrue(fixture.effects.isEmpty)
    }

    func testEachInvocationRechecksEligibilityInsteadOfRememberingPermission() async {
        let fixture = Fixture()
        fixture.inputs.login = .notRegistered
        let coordinator = fixture.coordinator()
        let first = await coordinator.perform(.enableLogin)
        XCTAssertEqual(first.outcome, .performed)
        XCTAssertEqual(fixture.effects, ["login"])

        fixture.inputs.login = .denied
        fixture.inputs.hasReviewedSetup = true
        let second = await coordinator.perform(.enableLogin)
        XCTAssertEqual(second.outcome, .unavailable)
        XCTAssertEqual(second.readiness.item(for: .launchAtLogin).reason, .approvalDenied)
        XCTAssertEqual(fixture.effects, ["login"])
        XCTAssertEqual(fixture.reads, 3)
    }

    func testEnabledLoginIsIdempotentAndNeverUsesATogglePort() async {
        let fixture = Fixture()
        fixture.inputs.login = .enabled
        let result = await fixture.coordinator().perform(.enableLogin)
        XCTAssertEqual(result.outcome, .alreadySatisfied)
        XCTAssertEqual(result.readiness.inputs.login, .enabled)
        XCTAssertTrue(fixture.effects.isEmpty)
    }

    func testHistoryUsesExplicitDesiredStateAndAlreadyEqualStateIsANoOp() async {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        let unchanged = await coordinator.perform(.setHistoryEnabled(false))
        XCTAssertEqual(unchanged.outcome, .alreadySatisfied)
        XCTAssertTrue(fixture.effects.isEmpty)

        let enabled = await coordinator.perform(.setHistoryEnabled(true))
        XCTAssertEqual(enabled.outcome, .performed)
        XCTAssertTrue(enabled.readiness.inputs.historyEnabled)
        XCTAssertEqual(fixture.effects, ["history.true"])
    }

    func testHelperTrustCapabilityRestorationAndLaunchPolicyCannotBeBypassed() async {
        var cases: [SetupReadinessInputs] = []
        var inputs = Fixture.eligibleInputs()
        inputs.helper.sameTeamTrustVerified = false; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.helper.installedInApplications = false; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.helper.canRequestRegistration = false; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.helper.restorationRequired = true; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.fanAvailability = .unknown; inputs.helperPowerAvailability = .unknown; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.helper.registration = .denied; cases.append(inputs)
        inputs = Fixture.eligibleInputs()
        inputs.launchPolicy = .monitoringOnly; cases.append(inputs)
        for current in cases {
            let fixture = Fixture(inputs: current)
            let result = await fixture.coordinator().perform(.registerHelper)
            XCTAssertEqual(result.outcome, .unavailable)
            XCTAssertTrue(fixture.effects.isEmpty)
        }
    }

    func testEligibleHelperDispatchRefreshesActualApprovalStatus() async {
        let fixture = Fixture()
        fixture.afterEffect = { fixture.inputs.helper.registration = .requiresApproval }
        let result = await fixture.coordinator().perform(.registerHelper)
        XCTAssertEqual(result.outcome, .performed)
        XCTAssertEqual(result.readiness.item(for: .fans).status, .needsOSApproval)
        XCTAssertEqual(fixture.effects, ["helper"])
        XCTAssertEqual(fixture.reads, 2)
    }

    func testValidationRequiresFreshSafeGateAndOnlyNativeChargingHasAPort() async {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        fixture.inputs.nativeCharge.canSafelyRequestValidation = false
        var result = await coordinator.perform(.requestValidation(.nativeCharging))
        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertTrue(fixture.effects.isEmpty)

        fixture.inputs.nativeCharge.canSafelyRequestValidation = true
        fixture.inputs.nativeCharge.hasCompletePersistentState = false
        result = await coordinator.perform(.requestValidation(.nativeCharging))
        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertTrue(fixture.effects.isEmpty)

        fixture.inputs.nativeCharge.hasCompletePersistentState = true
        result = await coordinator.perform(.requestValidation(.nativeCharging))
        XCTAssertEqual(result.outcome, .performed)
        XCTAssertEqual(result.readiness.item(for: .nativeCharging).status, .needsValidation,
                       "A returned request does not fabricate qualification")
        XCTAssertEqual(fixture.effects, ["nativeValidation"])

        for feature in SetupFeature.allCases where feature != .nativeCharging {
            result = await coordinator.perform(.requestValidation(feature))
            XCTAssertEqual(result.outcome, .unavailable)
        }
        XCTAssertEqual(fixture.effects, ["nativeValidation"])
    }

    func testNavigationUsesOnlyItsOwnPortAndRejectsStaleApprovalLink() async {
        let fixture = Fixture()
        fixture.inputs.login = .requiresApproval
        let coordinator = fixture.coordinator()
        let approval = await coordinator.perform(.openApprovalSettings(.launchAtLogin))
        XCTAssertEqual(approval.outcome, .performed)
        let requirements = await coordinator.perform(.viewRequirements(.closedLid))
        XCTAssertEqual(requirements.outcome, .performed)
        let refresh = await coordinator.perform(.refresh(.nativeCharging))
        XCTAssertEqual(refresh.outcome, .performed)
        XCTAssertEqual(fixture.effects, ["approval.launchAtLogin", "requirements.closedLid"])

        fixture.inputs.login = .enabled
        let stale = await coordinator.perform(.openApprovalSettings(.launchAtLogin))
        XCTAssertEqual(stale.outcome, .unavailable)
        XCTAssertEqual(fixture.effects, ["approval.launchAtLogin", "requirements.closedLid"])
    }

    func testFailureStillRefreshesStatusAndKeepsFailureVisible() async {
        let fixture = Fixture()
        fixture.inputs.login = .notRegistered
        fixture.afterEffect = {
            fixture.inputs.login = .requiresApproval
            throw FixtureError.denied
        }
        let result = await fixture.coordinator().perform(.enableLogin)
        guard case .failed(let message) = result.outcome else { return XCTFail("Must retain action error") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(result.readiness.inputs.login, .requiresApproval)
        XCTAssertEqual(result.readiness.item(for: .launchAtLogin).status, .needsOSApproval)
        XCTAssertEqual(fixture.reads, 2)
        XCTAssertEqual(fixture.effects, ["login"])
    }

    func testConcurrentInvocationCannotDispatchASecondEffect() async {
        let fixture = Fixture()
        fixture.inputs.login = .notRegistered
        let coordinator = fixture.coordinator()
        var nested: SetupActionCoordinator.Result?
        fixture.duringEffect = { nested = await coordinator.perform(.registerHelper) }
        let result = await coordinator.perform(.enableLogin)
        XCTAssertEqual(result.outcome, .performed)
        XCTAssertEqual(nested?.outcome, .busy)
        XCTAssertEqual(fixture.effects, ["login"])
        XCTAssertEqual(fixture.reads, 3, "Even busy attempts return current read-only readiness")
    }

    private enum FixtureError: Error { case denied }

    @MainActor private final class Fixture {
        var inputs: SetupReadinessInputs
        var effects: [String] = []
        var reads = 0
        var afterEffect: (() throws -> Void)?
        var duringEffect: (() async -> Void)?

        init(inputs: SetupReadinessInputs = Fixture.eligibleInputs()) { self.inputs = inputs }

        static func eligibleInputs() -> SetupReadinessInputs {
            var inputs = SetupReadinessInputs()
            inputs.nativeCharge = .init(availability: .available, hasCompletePersistentState: true,
                currentOSQualified: false, canSafelyRequestValidation: true)
            inputs.helper = .init(sameTeamTrustVerified: true, installedInApplications: true,
                registration: .notRegistered, connected: false, canRequestRegistration: true)
            inputs.fanAvailability = .available
            inputs.helperPowerAvailability = .available
            return inputs
        }

        func effect(_ name: String) async throws {
            effects.append(name)
            await duringEffect?()
            try afterEffect?()
        }

        func coordinator() -> SetupActionCoordinator {
            SetupActionCoordinator(ports: .init(
                readInputs: { self.reads += 1; return self.inputs },
                viewRequirements: { try await self.effect("requirements." + $0.rawValue) },
                openApprovalSettings: { try await self.effect("approval." + $0.rawValue) },
                registerHelper: { try await self.effect("helper") },
                enableLogin: { try await self.effect("login") },
                setHistoryEnabled: {
                    try await self.effect("history." + String($0))
                    self.inputs.historyEnabled = $0
                },
                requestNativeChargeValidation: { try await self.effect("nativeValidation") }
            ))
        }
    }
}
