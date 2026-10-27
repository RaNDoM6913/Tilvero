import XCTest
import Foundation
import Darwin
@testable import TilveroApp
import PowerCore
import PowerPrivileged

@MainActor final class LiveControlTests: XCTestCase {
    func testUntrustedMonitoringNeverConnectsEnrollsOrClaimsControl() async throws {
        let fixture = makeFixture(trusted: false, registrationState: .notRegistered)
        await fixture.service.start(); await fixture.service.start()
        await fixture.service.observe(snapshot(98))
        XCTAssertFalse(fixture.service.canCharge); XCTAssertFalse(fixture.service.canRegister)
        XCTAssertFalse(fixture.service.canFans); XCTAssertTrue(fixture.service.acceptedTargets.isEmpty == false)
        do { try await fixture.service.registerHelper(); XCTFail("Untrusted registration must be refused.") } catch {}
        XCTAssertEqual(fixture.registration.registerCount, 0)
        let awaited1 = await fixture.transport.openCount
        XCTAssertEqual(awaited1, 0)
        let awaited2 = await fixture.transport.commands
        XCTAssertEqual(awaited2, [])
        cleanup(fixture.preferences)
    }
    func testMonitoringReleaseNeverUsesEvenTrustedEnabledHelper() async throws {
        let fixture = makeFixture(monitoringOnly: true, savedIntent: .ceiling(80))
        defer { cleanup(fixture.preferences) }
        await fixture.service.start()
        XCTAssertNil(fixture.service.requestedIntent)
        XCTAssertFalse(fixture.service.canRegister)
        XCTAssertFalse(fixture.service.canCharge)
        XCTAssertTrue(fixture.service.acceptedTargets.isEmpty)
        XCTAssertFalse(fixture.service.capabilities.contains { $0.readiness == .available })
        do { try await fixture.service.registerHelper(); XCTFail("Monitoring cannot enroll") } catch {}
        do { try await fixture.service.unregisterHelper(); XCTFail("Monitoring cannot manage services") } catch {}
        XCTAssertEqual(fixture.registration.registerCount, 0)
        XCTAssertEqual(fixture.registration.unregisterCount, 0)
        let count = await fixture.transport.openCount
        XCTAssertEqual(count, 0)
    }

    func testMonitoringReleaseQuitsAndSleepsWithoutTouchingExistingHelper() async throws {
        let fixture = makeFixture(monitoringOnly: true)
        defer { cleanup(fixture.preferences) }
        await fixture.service.start()
        let sleep = await fixture.service.prepareForSleep()
        let quit = await fixture.service.prepareForTermination()
        XCTAssertTrue(sleep)
        XCTAssertTrue(quit)
        let commands = await fixture.transport.commands
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(fixture.service.recoveryRequired)
    }

    func testPendingLowerTargetEmitsNoWriteUntilFreshNaturalDischarge() async throws {
        let fixture = makeFixture()
        await fixture.service.start(); await fixture.service.observe(snapshot(98))
        try await fixture.service.submit(.setCeiling(percent: 80))
        XCTAssertEqual(fixture.service.chargeState.pendingTarget, 80)
        XCTAssertEqual(fixture.service.chargeState.appliedTarget, 100)
        let awaited3 = await fixture.transport.commands.contains { if case .applyCharge = $0 { true } else { false } }
        XCTAssertFalse(awaited3)
        await fixture.service.observe(snapshot(70))
        XCTAssertEqual(fixture.service.chargeState.appliedTarget, 80)
        XCTAssertNil(fixture.service.chargeState.pendingTarget)
        XCTAssertEqual(fixture.service.chargeState.phase, .managed)
        XCTAssertTrue(fixture.service.hasOwnedSettings)
        cleanup(fixture.preferences)
    }
    func testIndependentReadbackMismatchNeverClaimsAppliedRequest() async throws {
        let fixture = makeFixture()
        await fixture.transport.setReadbackMismatch(true)
        await fixture.service.start(); await fixture.service.observe(snapshot(70))
        do { try await fixture.service.submit(.setCeiling(percent: 90)); XCTFail("Mismatched readback must fail.") } catch {}
        XCTAssertEqual(fixture.service.chargeState.phase, .fault)
        XCTAssertNotEqual(fixture.service.chargeState.appliedTarget, 90)
        XCTAssertTrue(fixture.service.recoveryRequired)
        XCTAssertFalse(fixture.service.canCharge)
        cleanup(fixture.preferences)
    }
    func testRelaunchLoadsIntentWithoutReassertingHardware() async throws {
        let fixture = makeFixture(savedIntent: .ceiling(80))
        await fixture.service.start(); await fixture.service.observe(snapshot(70))
        XCTAssertEqual(fixture.service.requestedIntent, .ceiling(80))
        XCTAssertEqual(fixture.service.chargeState.requested, .ceiling(80))
        XCTAssertEqual(fixture.service.chargeState.appliedTarget, 100)
        XCTAssertEqual(fixture.service.chargeState.phase, .observing)
        XCTAssertTrue(fixture.service.needsExplicitReapply)
        let awaited4 = await fixture.transport.commands.contains { $0.isMutation }
        XCTAssertFalse(awaited4)
        cleanup(fixture.preferences)
    }
    func testTerminationRestoresBeforeInvalidatingTransport() async throws {
        let fixture = makeFixture(owned: [.charging])
        await fixture.service.start()
        XCTAssertTrue(fixture.service.hasOwnedSettings)
        let awaited5 = await fixture.service.prepareForTermination()
        XCTAssertTrue(awaited5)
        XCTAssertFalse(fixture.service.hasOwnedSettings)
        let events = await fixture.transport.events
        XCTAssertEqual(events.suffix(2), ["restoreAll", "invalidate"])
        cleanup(fixture.preferences)
    }
    func testFailedRestorationPreventsUnregisterAndTermination() async throws {
        let fixture = makeFixture(owned: [.charging])
        await fixture.transport.setRestoreFailure(true)
        await fixture.service.start()
        do { try await fixture.service.unregisterHelper(); XCTFail("Unregister cannot erase recovery obligations.") } catch {}
        XCTAssertEqual(fixture.registration.unregisterCount, 0)
        let awaited6 = await fixture.service.prepareForTermination()
        XCTAssertFalse(awaited6)
        XCTAssertTrue(fixture.service.recoveryRequired)
        XCTAssertTrue(fixture.service.hasOwnedSettings)
        let awaited7 = await fixture.transport.events.contains("invalidate")
        XCTAssertFalse(awaited7)
        cleanup(fixture.preferences)
    }
    func testProfileReportsPartialFailureAndPreservesIndependentSuccess() async throws {
        let fixture = makeFixture(energyQualified: false)
        await fixture.service.start(); await fixture.service.observe(snapshot(70))
        let result = await fixture.service.applyProfile(.init(name: "Fixture", chargeTarget: 80, mode: .low), source: .battery)
        XCTAssertNil(result.charge); XCTAssertNotNil(result.powerMode); XCTAssertNil(result.fans)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(fixture.service.chargeState.appliedTarget, 80)
        let awaited8 = await fixture.transport.commands.contains { if case .setEnergyMode = $0 { true } else { false } }
        XCTAssertFalse(awaited8)
        cleanup(fixture.preferences)
    }
    func testFanCurveIsDelegatedToHelperLoopWithoutOptimisticManagedState() async throws {
        let fixture = makeFixture(fansQualified: true)
        await fixture.service.start()
        let curve = try FanCurve(points: [.init(celsius: 40, rpm: 2000), .init(celsius: 80, rpm: 5000)])
        try await fixture.service.setFanPolicy(.curve(curve))
        XCTAssertEqual(fixture.service.fanState.phase, .acquiring)
        XCTAssertEqual(fixture.service.fanState.requested, .curve(curve))
        let awaited9 = await fixture.transport.commands.contains(.setFanPolicy(.curve(curve)))
        XCTAssertTrue(awaited9)
        let awaited10 = await fixture.transport.commands.contains { if case .setFanRPM = $0 { true } else { false } }
        XCTAssertFalse(awaited10)
        cleanup(fixture.preferences)
    }
    func testStaleCachedLevelDoesNotCausePendingWrite() async throws {
        let fixture = makeFixture()
        await fixture.service.start()
        await fixture.service.observe(snapshot(70, stale: true))
        try await fixture.service.submit(.setCeiling(percent: 80))
        XCTAssertEqual(fixture.service.chargeState.pendingTarget, 80)
        let awaited11 = await fixture.transport.commands.contains { $0.isMutation }
        XCTAssertFalse(awaited11)
        cleanup(fixture.preferences)
    }
    func testRegistrationIsExplicitAndUnavailableHardwareCannotEnroll() async throws {
        let fixture = makeFixture(registrationState: .notRegistered, chargeQualified: false)
        await fixture.service.start()
        XCTAssertFalse(fixture.service.canRegister)
        XCTAssertEqual(fixture.registration.registerCount, 0)
        cleanup(fixture.preferences)
        let supported = makeFixture(registrationState: .notRegistered)
        await supported.service.start()
        XCTAssertTrue(supported.service.canRegister)
        XCTAssertEqual(supported.registration.registerCount, 0)
        try await supported.service.registerHelper()
        XCTAssertEqual(supported.registration.registerCount, 1)
        XCTAssertTrue(supported.service.connected)
        cleanup(supported.preferences)
    }

    func testOneShotRelaunchRetainsPriorIntentWithoutReapplyingIt() async throws {
        let fixture = makeFixture()
        await fixture.service.start(); await fixture.service.observe(snapshot(70))
        try await fixture.service.submit(.setCeiling(percent: 80))
        try await fixture.service.submit(.chargeToFullOnce)
        let reopened = LiveControlService(preferences: fixture.preferences, trustVerified: true, registration: fixture.registration,
            makeTransport: { fixture.transport }, discovery: { LiveControlDiscovery(capabilities: []) }, clock: { 100 })
        XCTAssertEqual(reopened.requestedIntent, .ceiling(80))
        XCTAssertTrue(reopened.needsExplicitReapply)
        cleanup(fixture.preferences)
    }
    func testDivergentFanReadbackCannotRemainManaged() async throws {
        let fixture = makeFixture(fansQualified: true)
        await fixture.transport.setManagedFanMismatch(true)
        await fixture.service.start()
        do { try await fixture.service.setFanPolicy(.manual(["0": 2000])); XCTFail("Actual RPM divergence must fail.") } catch {}
        XCTAssertNotEqual(fixture.service.fanState.phase, .managed)
        XCTAssertTrue(fixture.service.recoveryRequired)
        cleanup(fixture.preferences)
    }

    func testAcceptedCurveStartsHeartbeatBeforeFirstHardwareAcquisition() async throws {
        let fixture = try await makeControllerFixture(heartbeatEnabled: true)
        defer { cleanup(fixture.preferences); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.service.start()
        try await fixture.service.setFanPolicy(curvePolicy())
        XCTAssertFalse(fixture.service.hasOwnedSettings)
        XCTAssertEqual(fixture.service.fanState.phase, .acquiring)
        let heartbeat = expectation(description: "Accepted pending curve receives its lease heartbeat")
        await fixture.transport.observeHeartbeat { heartbeat.fulfill() }
        fixture.clock.set(20)
        await fulfillment(of: [heartbeat], timeout: 7)
        fixture.clock.set(26)
        await fixture.controller.tickFanPolicy(now: 26, activeUserID: 501)
        let state = try await fixture.controller.readState(now: 26)
        XCTAssertEqual(state.fanPolicyState?.phase, .managed)
        XCTAssertEqual(state.ownedResources, [.fans])
        _ = try await fixture.service.restoreAll()
    }

    func testExplicitFanSubmissionRefreshesIndependentHelperObservation() async throws {
        let fixture = try await makeControllerFixture()
        defer { cleanup(fixture.preferences); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.service.start()
        fixture.clock.set(20)
        try await fixture.service.setFanPolicy(.manual(["0": 3000]))
        let commands = await fixture.transport.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.readState, .setFanPolicy(.manual(["0": 3000]))])
        XCTAssertEqual(fixture.service.fanState.phase, .managed)
        XCTAssertEqual(fixture.service.fanObservation?.sampledContinuousSeconds, 20)
        _ = try await fixture.service.restoreAll()
    }

    func testExplicitFanRefreshDoesNotReviveStaleSensorEvidence() async throws {
        let fixture = try await makeControllerFixture()
        defer { cleanup(fixture.preferences); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.service.start()
        fixture.clock.set(20)
        await fixture.hardware.retainObservation(at: 10)
        do { try await fixture.service.setFanPolicy(curvePolicy()); XCTFail("A helper read must preserve the sensor source clock.") } catch {}
        let commands = await fixture.transport.commands
        XCTAssertEqual(commands.last, .readState)
        XCTAssertFalse(commands.contains { if case .setFanPolicy = $0 { true } else { false } })
        let writes = await fixture.hardware.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testExplicitFanRefreshRequiresObservationInCurrentHelperReply() async throws {
        let fixture = try await makeControllerFixture()
        defer { cleanup(fixture.preferences); try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.service.start()
        await fixture.hardware.omitObservation()
        do { try await fixture.service.setFanPolicy(.manual(["0": 3000])); XCTFail("A fresh cached sample does not replace this explicit read's missing evidence.") } catch {}
        let commands = await fixture.transport.commands
        XCTAssertEqual(commands.last, .readState)
        XCTAssertFalse(commands.contains { if case .setFanPolicy = $0 { true } else { false } })
        let writes = await fixture.hardware.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testCancellingAcceptedCurveBeforeFirstTickPreventsLaterAcquisition() async throws {
        for restoreAll in [false, true] {
            let fixture = try await makeControllerFixture()
            defer { cleanup(fixture.preferences); try? FileManager.default.removeItem(at: fixture.directory) }
            await fixture.service.start()
            try await fixture.service.setFanPolicy(curvePolicy())
            XCTAssertFalse(fixture.service.hasOwnedSettings)
            if restoreAll { _ = try await fixture.service.restoreAll() }
            else { try await fixture.service.setFanPolicy(.systemAuto) }
            fixture.clock.set(11)
            await fixture.controller.tickFanPolicy(now: 11, activeUserID: 501)
            let state = try await fixture.controller.readState(now: 11)
            XCTAssertTrue(state.ownedResources.isEmpty)
            XCTAssertNotEqual(state.fanPolicyState?.phase, .managed)
            let writes = await fixture.hardware.writeCount
            XCTAssertEqual(writes, 0, "Cancelling pending policy must prevent the first helper tick from acquiring hardware.")
            let commands = await fixture.transport.commands
            XCTAssertTrue(commands.contains(restoreAll ? .restoreAll : .releaseFans))
        }
    }

    private func curvePolicy() throws -> FanPolicy {
        .curve(try FanCurve(points: [.init(celsius: 40, rpm: 2000), .init(celsius: 80, rpm: 5000)]))
    }
    private struct ControllerFixture {
        let directory: URL
        let preferences: UserDefaults
        let service: LiveControlService
        let controller: PrivilegedController
        let transport: ControllerFixtureTransport
        let hardware: ControllerFixtureHardware
        let clock: ControllerFixtureClock
    }
    private func makeControllerFixture(heartbeatEnabled: Bool = false) async throws -> ControllerFixture {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-facade-controller-\(UUID())")
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
        let clock = ControllerFixtureClock()
        let hardware = ControllerFixtureHardware(clock: clock)
        let controller = PrivilegedController(hardware: hardware, journal: journal, bootID: "fixture")
        let transport = ControllerFixtureTransport(controller: controller, clock: clock)
        let preferences = UserDefaults(suiteName: "TilveroControllerTests.\(UUID())")!
        let registration = FixtureHelperRegistration(state: .enabled)
        let service = LiveControlService(preferences: preferences, trustVerified: true, registration: registration,
            makeTransport: { transport }, discovery: { LiveControlDiscovery(capabilities: await hardware.capabilities(), fanObservation: try? await hardware.fanObservation()) },
            clock: { clock.now() }, heartbeatEnabled: heartbeatEnabled)
        return ControllerFixture(directory: directory, preferences: preferences, service: service, controller: controller,
            transport: transport, hardware: hardware, clock: clock)
    }

    private struct Fixture {
        let service: LiveControlService
        let transport: FixtureHelperTransport
        let registration: FixtureHelperRegistration
        let preferences: UserDefaults
    }
    private func makeFixture(monitoringOnly: Bool = false, trusted: Bool = true, registrationState: HelperInstallationState = .enabled,
                             chargeQualified: Bool = true, energyQualified: Bool = false, fansQualified: Bool = false,
                             owned: [OwnedResource] = [], savedIntent: ChargeIntent? = nil) -> Fixture {
        let preferences = UserDefaults(suiteName: "TilveroLiveTests.\(UUID().uuidString)")!
        if let savedIntent { preferences.set(try! JSONEncoder().encode(savedIntent), forKey: "liveRequestedChargeIntent") }
        let capabilities = [ControlCapability(backend: "native-powerui", readiness: chargeQualified ? .available : .unverified,
            reason: "Fixture only", acceptedTargets: chargeQualified ? Array(80...100) : [], validationReference: "fixture-only"),
            ControlCapability(backend: "pmset-lowpowermode", readiness: energyQualified ? .available : .unverified, reason: "Fixture only"),
            ControlCapability(backend: "smc-standard-fan", readiness: fansQualified ? .available : .unavailable, reason: "Fixture only")]
        let fanObservation = fansQualified ? FanObservation(descriptors: [.init(id: "0", minimumRPM: 1200, maximumRPM: 6000)],
            actualRPM: ["0": 2000], targetRPM: ["0": 2000], autoMode: ["0": true], sensorTemperature: 60,
            sensorFresh: true, sampledContinuousSeconds: 100) : nil
        let transport = FixtureHelperTransport(capabilities: capabilities, fanObservation: fanObservation, owned: owned)
        let registration = FixtureHelperRegistration(state: registrationState)
        let service = LiveControlService(preferences: preferences, trustVerified: trusted, registration: registration,
            makeTransport: { transport }, discovery: { LiveControlDiscovery(capabilities: capabilities, fanObservation: fanObservation) }, clock: { 100 }, monitoringOnly: monitoringOnly)
        return Fixture(service: service, transport: transport, registration: registration, preferences: preferences)
    }
    private func snapshot(_ percent: Int, stale: Bool = false) -> BatterySnapshot {
        BatterySnapshot(chargePercent: .init(value: percent, source: "Fixture", availability: stale ? .temporarilyUnavailable : .available, freshness: stale ? .stale : .fresh),
            isCharging: .init(value: false, source: "Fixture"), isExternalPower: .init(value: true, source: "Fixture"))
    }
    private func cleanup(_ preferences: UserDefaults) { preferences.removeObject(forKey: "liveRequestedChargeIntent"); preferences.removeObject(forKey: "livePriorOneShotChargeIntent") }
}

@MainActor private final class FixtureHelperRegistration: LiveHelperRegistrationDriving {
    var state: HelperInstallationState
    var registerCount = 0, unregisterCount = 0
    init(state: HelperInstallationState) { self.state = state }
    func register() async throws { registerCount += 1; state = .enabled }
    func unregister(afterVerifiedRestoration verified: Bool) async throws {
        guard verified else { throw LiveControlError.recoveryRequired }; unregisterCount += 1; state = .notRegistered
    }
}
private actor FixtureHelperTransport: LiveHelperTransport {
    private let capabilities: [ControlCapability]
    private var fanObservation: FanObservation?
    private var fanState: FanPolicyState?
    private var owned: [OwnedResource]
    private var target = 100
    private var mismatch = false, restoreFailure = false, managedFanMismatch = false
    private(set) var commands: [HelperCommand] = []
    private(set) var events: [String] = []
    private(set) var openCount = 0
    init(capabilities: [ControlCapability], fanObservation: FanObservation?, owned: [OwnedResource]) {
        self.capabilities = capabilities; self.fanObservation = fanObservation; self.owned = owned
    }
    func setReadbackMismatch(_ value: Bool) { mismatch = value }
    func setRestoreFailure(_ value: Bool) { restoreFailure = value }
    func setManagedFanMismatch(_ value: Bool) { managedFanMismatch = value }
    func openSession() -> HelperReply { openCount += 1; return .init(accepted: true, sessionToken: UUID()) }
    func submit(_ command: HelperCommand) -> HelperReply {
        commands.append(command)
        switch command {
        case .applyCharge(let value):
            target = mismatch ? 81 : value
            if !owned.contains(.charging) { owned.append(.charging) }
        case .releaseCharge: owned.removeAll { $0 == .charging }; target = 100
        case .restoreAll:
            events.append("restoreAll")
            if !restoreFailure { owned = []; target = 100 }
        case .setFanPolicy(let policy):
            if !owned.contains(.fans) { owned.append(.fans) }
            var state = FanPolicyState(); state.requested = policy; state.phase = .acquiring
            if managedFanMismatch {
                state.phase = .managed; state.appliedRPM = ["0": 2000]
                fanObservation = FanObservation(descriptors: fanObservation!.descriptors, actualRPM: ["0": 5000],
                    targetRPM: ["0": 2000], autoMode: ["0": false], sensorTemperature: 60, sensorFresh: true, sampledContinuousSeconds: 100)
            }
            fanState = state
        case .releaseFans: owned.removeAll { $0 == .fans }; fanState = FanPolicyState()
        default: break
        }
        let acquiring: Bool = { if case .setFanPolicy = command { !managedFanMismatch } else { false } }()
        return HelperReply(accepted: true, configurationVerified: !acquiring && !restoreFailure, reason: "Fixture only",
            capabilities: capabilities, observedSettings: [.charging: .nativeCharge(featureState: 1, limit: target)],
            chargeObservation: .init(percent: 70, externalPower: true, fresh: true, effectiveTarget: target),
            fanObservation: fanObservation, ownedResources: owned, recoveryRequired: restoreFailure,
            fanPolicyState: fanState)
    }
    func invalidate() { events.append("invalidate") }
}

private final class ControllerFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 10
    func now() -> Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}
private actor ControllerFixtureTransport: LiveHelperTransport {
    let controller: PrivilegedController
    let clock: ControllerFixtureClock
    let peer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
    private var token: UUID?
    private var generation: UInt64 = 0
    private var heartbeatObserver: (@Sendable () -> Void)?
    private(set) var commands: [HelperCommand] = []
    init(controller: PrivilegedController, clock: ControllerFixtureClock) { self.controller = controller; self.clock = clock }
    func openSession() async throws -> HelperReply {
        let reply = try await controller.openSession(peer: peer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
        token = reply.sessionToken; return reply
    }
    func submit(_ command: HelperCommand) async throws -> HelperReply {
        guard let token else { throw PrivilegeError.wrongSession }
        generation += 1; commands.append(command)
        let data = try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: generation, command: command))
        let reply = try await controller.perform(data, peer: peer, activeUserID: 501, now: clock.now())
        if command == .heartbeat { heartbeatObserver?(); heartbeatObserver = nil }
        return reply
    }
    func observeHeartbeat(_ observer: @escaping @Sendable () -> Void) { heartbeatObserver = observer }
    func invalidate() async { await controller.disconnect(peer: peer) }
}
private actor ControllerFixtureHardware: PrivilegedHardware {
    private let clock: ControllerFixtureClock
    private var retainedSampleTime: Double?
    private var observationMissing = false
    private var target = 0
    private var automatic = true
    private(set) var writeCount = 0
    init(clock: ControllerFixtureClock) { self.clock = clock }
    func capabilities() -> [ControlCapability] { [.init(backend: "smc-standard-fan", readiness: .available, reason: "Injected fixture only")] }
    func qualify(_ resource: OwnedResource) throws { guard resource == .fans else { throw PolicyError.unavailable } }
    func chargeObservation() throws -> ChargeObservation { throw PolicyError.unavailable }
    func fanObservation() throws -> FanObservation {
        guard !observationMissing else { throw PolicyError.unavailable }
        return .init(descriptors: [.init(id: "0", minimumRPM: 1200, maximumRPM: 6000)], actualRPM: ["0": target == 0 ? 1500 : target],
            targetRPM: ["0": target], autoMode: ["0": automatic], sensorTemperature: 60, sensorFresh: true,
            sampledContinuousSeconds: retainedSampleTime ?? clock.now())
    }
    func retainObservation(at time: Double) { retainedSampleTime = time }
    func omitObservation() { observationMissing = true }
    func read(_ resource: OwnedResource) throws -> HardwareSetting {
        guard resource == .fans else { throw PolicyError.unavailable }; return automatic ? .fanAuto : .fanRPM(["0": target])
    }
    func write(_ setting: HardwareSetting, resource: OwnedResource) throws { throw PolicyError.invalidPolicy }
    func writeFanRegister(_ register: FanRegister, value: FanRegisterValue) throws {
        writeCount += 1
        switch (register, value) {
        case (.target(fanID: "0"), let .rpm(rpm)): target = rpm
        case (.automatic(fanID: "0"), let .automatic(auto)): automatic = auto
        default: throw PolicyError.invalidPolicy
        }
    }
}
