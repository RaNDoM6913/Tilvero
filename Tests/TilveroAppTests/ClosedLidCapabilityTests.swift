import XCTest
import Darwin
import ClosedLidControl
@testable import TilveroApp

@MainActor final class ClosedLidCapabilityTests: XCTestCase {
    func testLostStartReplyRemainsUnresolvedAndReconnectCanObserveRecovery() async throws {
        let port = LostLidReplyFixture()
        let service = ClosedLidService(testClientFactory: { port })
        await service.setEnabled(true, seconds: 120)
        XCTAssertTrue(service.needsRecovery, "A lost reply must not hide a possibly applied kernel operation")
        XCTAssertNotEqual(service.state.phase, .idle)
        XCTAssertFalse(service.state.configurationVerified)
        await service.refresh()
        XCTAssertEqual(service.state.phase, .restoreAcceptedAwaitingWitness)
        XCTAssertTrue(service.needsRecovery)
    }

    func testGenericRefusedReconnectCannotClearUnknownStartOutcome() async throws {
        let port = LostLidReplyFixture(genericRefusal: true)
        let service = ClosedLidService(testClientFactory: { port })
        await service.setEnabled(true, seconds: 120)
        XCTAssertTrue(service.needsRecovery)
        await service.refresh()
        XCTAssertTrue(service.needsRecovery, "A default idle refusal contains no proof that the unknown operation was restored")
        XCTAssertNotEqual(service.state.phase, .idle)
        XCTAssertFalse(service.state.configurationVerified)
    }

    func testExplicitMonitoringRestrictionAlsoDisablesFixtureAdmission() async {
        let service = ClosedLidService(mode: .fixtureMemory, allowed: false)
        XCTAssertFalse(service.isFixture)
        XCTAssertFalse(service.isLiveTrial)
        XCTAssertFalse(service.isAvailable)
        await service.setEnabled(true, seconds: 120)
        XCTAssertFalse(service.state.applicationAccepted)
        XCTAssertEqual(service.state.phase, .idle)
    }

    func testOrdinaryDefaultCannotSilentlyApplyMemoryState() async {
        let service = ClosedLidService()
        XCTAssertFalse(service.isFixture)
        XCTAssertFalse(service.isAvailable)
        await service.setEnabled(true, seconds: 120)
        XCTAssertEqual(service.state.phase, .idle)
        XCTAssertFalse(service.state.applicationAccepted)
        XCTAssertNotNil(service.failure)
        XCTAssertFalse(service.needsRecovery)
        let canTerminate = await service.prepareForTermination()
        XCTAssertTrue(canTerminate)
    }

    func testUnresolvedLidRestorationBlocksQuitBeforeReleasingAwakeOwner() async throws {
        let port = LostLidReplyFixture(genericRefusal: true)
        let service = ClosedLidService(testClientFactory: { port })
        let fixture = ClosedLidModelFixture(service: service)
        try fixture.model.startKeepAwakeDraft()
        let awakeOwner = fixture.model.keepAwake.ownedAssertionID
        await service.setEnabled(true, seconds: 120)
        let allowed = await fixture.model.prepareForTermination()
        XCTAssertFalse(allowed)
        XCTAssertEqual(fixture.model.keepAwake.ownedAssertionID, awakeOwner)
        fixture.cleanup()
    }

    private func session() async -> ClosedLidModelFixture {
        ClosedLidModelFixture()
    }

    func testRealControllerFixtureStartsWithoutClaimingConfigurationOrPhysicalProof() async throws {
        let lab = await session(); let model = lab.model
        try model.startKeepAwakeDraft()
        let awake = model.keepAwake.ownedAssertionID
        let timer = model.sleepTimer.sessionID
        model.closedLid.bind(model.keepAwake)
        await model.closedLid.setEnabled(true, seconds: 120)
        XCTAssertFalse(model.closedLid.isLiveTrial)
        XCTAssertEqual(model.closedLid.state.phase, .commandAccepted, model.closedLid.failure ?? "")
        XCTAssertTrue(model.closedLid.state.applicationAccepted)
        XCTAssertFalse(model.closedLid.state.configurationVerified)
        XCTAssertFalse(model.closedLid.state.behaviorObserved)
        XCTAssertEqual(model.keepAwake.ownedAssertionID, awake)
        XCTAssertEqual(model.sleepTimer.sessionID, timer)
        let restored = await model.closedLid.prepareForTermination()
        XCTAssertTrue(restored, model.closedLid.failure ?? "")
        XCTAssertEqual(model.closedLid.state.phase, .restored)
        XCTAssertEqual(model.keepAwake.ownedAssertionID, awake)
        await lab.stop()
    }

    func testRestoredSessionCanStartAgainWithoutReplacingOrdinaryAwakeOwner() async throws {
        let lab = await session(); let model = lab.model
        try model.startKeepAwakeDraft()
        let awakeOwner = model.keepAwake.ownedAssertionID
        let fixture = try await realLidFixture()
        let service = ClosedLidService(testClientFactory: { fixture.client })
        service.bind(model.keepAwake)
        await fixture.backend.emitOpenWitness()
        await service.setEnabled(true, seconds: 120)
        let firstLidSession = service.state.sessionID
        await service.setEnabled(false, seconds: 0)
        await fixture.backend.emitOpenWitness()
        _ = try await fixture.guardian.tick(activeUserID: UInt32(geteuid()))
        await service.refresh()
        XCTAssertEqual(service.state.phase, .restored)
        await service.setEnabled(true, seconds: 120)
        XCTAssertEqual(service.state.phase, .commandAccepted, service.failure ?? "")
        XCTAssertNotEqual(service.state.sessionID, firstLidSession)
        XCTAssertEqual(model.keepAwake.ownedAssertionID, awakeOwner)
        _ = await service.prepareForTermination()
        await lab.stop()
    }

    func testEndingExactAwakeOwnerRevokesHeldStartAndDropsLatePositiveReply() async throws {
        let lab = await session(); let model = lab.model
        try model.startKeepAwakeDraft()
        let fixture = try await realLidFixture()
        let held = LidReplyGate()
        let port = HeldLidReplyFixture(client: fixture.client, holdHeartbeat: false, gate: held)
        let service = ClosedLidService(testClientFactory: { port })
        service.bind(model.keepAwake)
        await fixture.backend.emitOpenWitness()
        let start = Task { await service.setEnabled(true, seconds: 120) }
        await held.waitUntilEntered()
        try model.keepAwake.stop()
        XCTAssertEqual(service.state.phase, .restorationRequired, "Exact owner loss must revoke authority synchronously")
        let allowed = await service.prepareForTermination()
        XCTAssertFalse(allowed, "An in-flight accepted command still requires recovery")
        await held.release()
        await start.value
        await service.refresh()
        XCTAssertNotEqual(service.state.phase, .commandAccepted, "A late start reply cannot restore owner authority")
        XCTAssertTrue(service.needsRecovery, "Recovery still needs a fresh post-clear witness")
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        await lab.stop()
    }

    func testEndingExactAwakeOwnerRevokesHeldHeartbeatAndDropsLatePositiveReply() async throws {
        let lab = await session(); let model = lab.model
        try model.startKeepAwakeDraft()
        let fixture = try await realLidFixture()
        let heartbeatClock = LidReplyGate()
        let held = LidReplyGate()
        let port = HeldLidReplyFixture(client: fixture.client, holdHeartbeat: true, gate: held)
        let service = ClosedLidService(testClientFactory: { port }, testHeartbeatSleep: {
            await heartbeatClock.enterAndWait()
            try Task.checkCancellation()
        })
        service.bind(model.keepAwake)
        await fixture.backend.emitOpenWitness()
        await service.setEnabled(true, seconds: 120)
        await heartbeatClock.waitUntilEntered()
        await heartbeatClock.release()
        await held.waitUntilEntered()
        try model.keepAwake.stop()
        XCTAssertEqual(service.state.phase, .restorationRequired, "Exact owner loss must revoke authority synchronously")
        let allowed = await service.prepareForTermination()
        XCTAssertFalse(allowed)
        let completed = expectation(description: "Held heartbeat finishes")
        let completion = service.$busy.dropFirst().filter { !$0 }.first().sink { _ in completed.fulfill() }
        await held.release()
        await fulfillment(of: [completed], timeout: 3)
        withExtendedLifetime(completion) {}
        await service.refresh()
        XCTAssertNotEqual(service.state.phase, .commandAccepted, "A late heartbeat cannot retain owner authority")
        XCTAssertTrue(service.needsRecovery)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        await lab.stop()
    }

    private func realLidFixture() async throws -> (client: ClosedLidMemoryClient, backend: ClamshellMemoryBackend, guardian: ClosedLidGuardian) {
        let clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
        let boot = "fixture-lifecycle-test"
        let backend = ClamshellMemoryBackend(clock: clock, bootID: boot)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("LidLifecycle-" + UUID().uuidString).path
        let journal = try ClosedLidJournal(directory: URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path), requiredOwner: UInt32(geteuid()))
        let controller = ClosedLidController(backend: backend, journal: journal, clock: clock, bootID: { boot })
        let guardian = ClosedLidGuardian(backend: backend, journal: journal, clock: clock, bootID: { boot })
        _ = try await guardian.tick(activeUserID: UInt32(geteuid()))
        return (ClosedLidMemoryClient(controller: controller), backend, guardian)
    }

    func testExplicitFixtureMemoryAwakeOwnerLossAfterApplyRestoresWithNewWitness() async throws {
        for _ in 0..<12 {
            let lab = await session(); let model = lab.model
            try model.startKeepAwakeDraft()
            let service = model.closedLid
            service.bind(model.keepAwake)
            await service.setEnabled(true, seconds: 120)
            XCTAssertEqual(service.state.phase, .commandAccepted)
            let restored = expectation(description: "Owner loss reconciles default memory restoration")
            let completion = service.$state.dropFirst().filter { $0.phase == .restored }.first().sink { _ in restored.fulfill() }
            try model.keepAwake.stop()
            await fulfillment(of: [restored], timeout: 3)
            withExtendedLifetime(completion) {}
            XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
            XCTAssertEqual(service.state.phase, .restored)
            XCTAssertFalse(service.needsRecovery)
            let allowed = await service.prepareForTermination()
            XCTAssertTrue(allowed)
            await lab.stop()
        }
    }

    func testExplicitFixtureMemoryRestoreRequiresStrictlyNewWitnessOnEveryCycle() async throws {
        for cycle in 0..<40 {
            let service = ClosedLidService(mode: .fixtureMemory)
            await service.setEnabled(true, seconds: 120)
            XCTAssertEqual(service.state.phase, .commandAccepted, "Cycle \(cycle): \(service.failure ?? "")")
            let restored = await service.prepareForTermination()
            XCTAssertTrue(restored, "Cycle \(cycle): \(service.state)")
            XCTAssertEqual(service.state.phase, .restored, "Cycle \(cycle)")
        }
    }

    func testOwnSleepPreparationRestoresLidBeforeAllowingTermination() async throws {
        let lab = await session(); let model = lab.model
        try model.startKeepAwakeDraft()
        model.closedLid.bind(model.keepAwake)
        await model.closedLid.setEnabled(true, seconds: 120)
        let allowed = await model.prepareForTermination()
        XCTAssertTrue(allowed, model.closedLid.failure ?? "")
        XCTAssertEqual(model.closedLid.state.phase, .restored)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(model.closedLid.isOn)
        await lab.stop()
    }
}
actor LidReplyGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var replyWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        if !released { await withCheckedContinuation { replyWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func release() {
        released = true
        replyWaiters.forEach { $0.resume() }; replyWaiters = []
    }
}

/// Hold a real controller's positive response across owner cancellation. The
/// channel can still disconnect independently while that response is in flight.
actor HeldLidReplyFixture: ClosedLidClientTransport {
    let client: ClosedLidMemoryClient
    let holdHeartbeat: Bool
    let gate: LidReplyGate
    init(client: ClosedLidMemoryClient, holdHeartbeat: Bool, gate: LidReplyGate) {
        self.client = client; self.holdHeartbeat = holdHeartbeat; self.gate = gate
    }
    func openSession() async throws -> ClosedLidReply { try await client.openSession() }
    func submit(_ command: ClosedLidCommand) async throws -> ClosedLidReply {
        let reply = try await client.submit(command)
        switch command {
        case .start where !holdHeartbeat, .heartbeat where holdHeartbeat:
            await gate.enterAndWait()
        default: break
        }
        return reply
    }
    func invalidate() async { await client.invalidate() }
}

actor LostLidReplyFixture: ClosedLidClientTransport {
    private var state = ClosedLidState()
    let genericRefusal: Bool
    init(genericRefusal: Bool = false) { self.genericRefusal = genericRefusal }
    func openSession() -> ClosedLidReply {
        if state.recoveryRequired {
            return genericRefusal ? .init(failure: .unavailable) : .init(state: state, failure: .recoveryRequired)
        }
        return .init(accepted: true, sessionToken: UUID(), generation: 1, state: state)
    }
    func submit(_ command: ClosedLidCommand) throws -> ClosedLidReply {
        if case .start = command {
            state.phase = .commandAccepted; state.applicationAccepted = true
            state.recoveryRequired = true; state.sessionID = UUID()
            throw ClosedLidFailure.timeout
        }
        return .init(state: state, failure: .wrongSession)
    }
    func invalidate() {
        state.phase = .restoreAcceptedAwaitingWitness; state.restoreCommandAccepted = true
    }
}

/// Injected model fixture: only temporary fixture journals and memory control ports.
@MainActor private final class ClosedLidModelFixture {
    let model: TilveroModel
    private let suite = "ClosedLidModelFixture-" + UUID().uuidString
    private let preferences: UserDefaults
    init(service: ClosedLidService? = nil) {
        preferences = UserDefaults(suiteName: suite)!
        model = TilveroModel(isDemo: true, preferences: preferences,
            keepAwakeService: KeepAwakeService(driver: AwakeFixture()),
            closedLidService: service ?? ClosedLidService(mode: .fixtureMemory),
            sideEffects: .init(loginStatus: { "Fixture disabled" }, toggleLogin: {},
                openBatterySettings: {}, rawCatalog: { [] }))
    }
    func stop() async { _ = await model.closedLid.prepareForTermination(); cleanup() }
    func cleanup() { model.stop(); preferences.removePersistentDomain(forName: suite) }
}
