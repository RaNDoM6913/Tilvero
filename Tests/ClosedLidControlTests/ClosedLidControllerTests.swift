import XCTest
import Foundation
import Darwin
@testable import ClosedLidControl

final class LidTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 100
    func now() -> Double { lock.withLock { value } }
    func advance(_ amount: Double) { lock.withLock { value += amount } }
}
actor LidTestBackend: ClamshellBackend {
    var observation: ClamshellObservation
    var calls: [Bool] = []
    var failures = 0
    var sleepCalls = 0
    var sleepFails = false
    var beforeSleep: (@Sendable () throws -> Void)?
    var observationAfterClear: ClamshellObservation?
    var beforeCall: (@Sendable (Bool) throws -> Void)?
    var afterCall: (@Sendable (Bool) throws -> Void)?
    var delayObservation: CheckedContinuation<Void, Never>?
    var holdObservation = false
    var holdApply = false
    var applyContinuation: CheckedContinuation<Void, Never>?
    let clock: @Sendable () -> Double
    let observerID: UUID
    init(context: UUID = UUID(), clock: @escaping @Sendable () -> Double = { 100 }, observerID: UUID = UUID()) {
        self.clock = clock; self.observerID = observerID
        observation = .init(bootID: "boot-a", sampledAt: 100, contextID: context, activeUserID: 501,
            lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: true,
            witness: .init(bootID: "boot-a", receivedAt: 100, sequence: 1, contextID: context,
                           notificationBits: 2, sleepAllowed: true, observerID: observerID))
    }
    func observe() async throws -> ClamshellObservation {
        if holdObservation { holdObservation = false; await withCheckedContinuation { delayObservation = $0 } }
        var result = observation; result.sampledAt = clock(); return result
    }
    func setLidSleepDisabled(_ disabled: Bool) async throws -> ClamshellCommandReceipt {
        if disabled && holdApply { holdApply = false; await withCheckedContinuation { applyContinuation = $0 } }
        try beforeCall?(disabled); calls.append(disabled)
        if failures > 0 { failures -= 1; throw ClosedLidFailure.commandRejected }
        try afterCall?(disabled)
        if !disabled, let observationAfterClear { observation = observationAfterClear }
        return .init(disabled: disabled, acceptedAt: clock())
    }
    func requestNormalSleep() async throws -> Bool {
        sleepCalls += 1; try beforeSleep?()
        if sleepFails { throw ClosedLidFailure.unavailable }
        return true
    }
    func changeObservationAfterClear(_ value: ClamshellObservation) { observationAfterClear = value }
    func failSleep() { sleepFails = true }
    func interceptSleep(_ body: @escaping @Sendable () throws -> Void) { beforeSleep = body }
    func pauseNextApply() { holdApply = true }
    func applyIsPaused() -> Bool { applyContinuation != nil }
    func resumeApply() { applyContinuation?.resume(); applyContinuation = nil }
    func update(_ value: ClamshellObservation) { observation = value }
    func fail(_ count: Int) { failures = count }
    func interceptAfter(_ body: @escaping @Sendable (Bool) throws -> Void) { afterCall = body }
    func intercept(_ body: @escaping @Sendable (Bool) throws -> Void) { beforeCall = body }
    func pauseNextObservation() { holdObservation = true }
    func observationIsPaused() -> Bool { delayObservation != nil }
    func resumeObservation() { delayObservation?.resume(); delayObservation = nil }
}
func assertCalls(_ backend: LidTestBackend, _ expected: [Bool], file: StaticString = #filePath, line: UInt = #line) async {
    let actual = await backend.calls; XCTAssertEqual(actual, expected, file: file, line: line)
}
struct LidFixture: Sendable {
    let directory: URL
    let journal: ClosedLidJournal
    let clock = LidTestClock()
    let backend: LidTestBackend
    let peer = ClosedLidPeer(userID: 501, auditSessionID: 42, connectionID: UUID())
    let controller: ClosedLidController
    let guardian: ClosedLidGuardian
    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory().replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)).appendingPathComponent("tilvero-lid-\(UUID())")
        journal = try ClosedLidJournal(directory: directory)
        let capturedClock = clock
        backend = LidTestBackend(clock: { capturedClock.now() })
        controller = ClosedLidController(backend: backend, journal: journal, clock: { capturedClock.now() }, bootID: { "boot-a" })
        guardian = ClosedLidGuardian(backend: backend, journal: journal, clock: { capturedClock.now() }, bootID: { "boot-a" })
    }
    func open() async throws -> ClosedLidReply { try await controller.openSession(peer: peer, activeUserID: 501) }
    func send(_ command: ClosedLidCommand, using reply: ClosedLidReply, id: UUID = UUID()) async throws -> ClosedLidReply {
        try await controller.perform(.init(requestID: id, sessionToken: reply.sessionToken!, generation: reply.generation + 1, command: command), peer: peer, activeUserID: 501)
    }
    func start() async throws -> ClosedLidReply {
        _ = try await guardian.tick(); let opened = try await open(); return try await send(.start(seconds: 60), using: opened)
    }
}

final class ClosedLidControllerTests: XCTestCase {
    func testPreparedBeforeApplyAndAcceptedIsNotVerified() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.backend.intercept { disabled in
            if disabled { XCTAssertEqual(try f.journal.load()?.state.phase, .prepared) }
        }
        let started = try await f.start()
        XCTAssertTrue(started.accepted); XCTAssertEqual(started.state.phase, .commandAccepted)
        XCTAssertTrue(started.state.applicationAccepted); XCTAssertFalse(started.state.configurationVerified)
        XCTAssertFalse(started.state.behaviorObserved)
        await assertCalls(f.backend, [true])
    }
    func testRegistryTrueFalseOrStaleWitnessNeverAdmits() async throws {
        for variant in 0..<8 {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            var observation = await f.backend.observation
            if variant == 0 { observation.witness = nil }
            else {
                let old = observation.witness!
                observation.witness = .init(bootID: variant == 6 ? "other-boot" : old.bootID,
                    receivedAt: variant == 1 ? 90 : (variant == 7 ? 101 : 100), sequence: 1,
                    contextID: variant == 5 ? UUID() : old.contextID,
                    notificationBits: variant == 3 ? 0 : 2, sleepAllowed: variant != 2,
                    source: variant == 4 ? "registry aggregate property" : old.source)
            }
            await f.backend.update(observation)
            let reply = try await f.start()
            XCTAssertFalse(reply.accepted); XCTAssertEqual(reply.failure, .baselineWitnessRequired)
            await assertCalls(f.backend, [])
        }
    }
    func testGuardianReadinessAndActiveUserAreRequired() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let opened = try await f.open()
        let denied = try await f.send(.start(seconds: 60), using: opened)
        XCTAssertEqual(denied.failure, .guardianUnavailable)
        let wrong = try await f.controller.openSession(peer: f.peer, activeUserID: 502)
        XCTAssertEqual(wrong.failure, .wrongUser); await assertCalls(f.backend, [])
    }
    func testReplayStaleGenerationTokenAndUIDAreDenied() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open(); let request = UUID()
        let started = try await f.send(.start(seconds: 60), using: opened, id: request)
        let replay = try await f.send(.readState, using: started, id: request)
        XCTAssertEqual(replay.failure, .replay)
        let stale = try await f.send(.heartbeat(sessionID: started.state.sessionID!), using: opened)
        XCTAssertEqual(stale.failure, .staleGeneration)
        let badToken = try await f.controller.perform(.init(sessionToken: UUID(), generation: started.generation + 1, command: .readState), peer: f.peer, activeUserID: 501)
        XCTAssertEqual(badToken.failure, .wrongSession)
        let uid = try await f.controller.perform(.init(sessionToken: started.sessionToken!, generation: started.generation + 1, command: .readState), peer: f.peer, activeUserID: 502)
        XCTAssertEqual(uid.failure, .wrongUser); await assertCalls(f.backend, [true])
    }
    func testStopCannotBeUndoneByDelayedStartObservation() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open()
        await f.backend.pauseNextObservation()
        let task = Task { try await f.send(.start(seconds: 60), using: opened) }
        while !(await f.backend.observationIsPaused()) { await Task.yield() }
        await f.controller.disconnect(peer: f.peer)
        await f.backend.resumeObservation()
        let reply = try await task.value
        XCTAssertFalse(reply.accepted); await assertCalls(f.backend, [])
    }
    func testDisconnectDuringKernelCallRestoresLateApplyBeforeReleasingWriter() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open()
        await f.backend.pauseNextApply()
        let task = Task { try await f.send(.start(seconds: 60), using: opened) }
        while !(await f.backend.applyIsPaused()) { await Task.yield() }
        await f.controller.disconnect(peer: f.peer)
        let during = try await f.guardian.tick()
        XCTAssertTrue(during.recoveryRequired)
        await f.backend.resumeApply()
        let reply = try await task.value
        XCTAssertFalse(reply.accepted); await assertCalls(f.backend, [true, false])
        let state = try await f.controller.currentState()
        XCTAssertEqual(state.phase, .restoreAcceptedAwaitingWitness)
    }
    func testStopRetryAfterKnownRejectionIsAllowedButAcceptedClearIsNeverRepeated() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let started = try await f.start(); await f.backend.fail(1)
        let failed = try await f.send(.stop(sessionID: started.state.sessionID!), using: started)
        XCTAssertEqual(failed.failure, .commandRejected)
        let accepted = try await f.send(.recover(sessionID: started.state.sessionID!), using: failed)
        XCTAssertTrue(accepted.accepted); XCTAssertTrue(accepted.state.restoreCommandAccepted)
        _ = try await f.send(.recover(sessionID: started.state.sessionID!), using: accepted)
        await assertCalls(f.backend, [true, false, false])
    }
    func testRevokedSessionCanReadRestoreProgressButCannotStartOrRenew() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let started = try await f.start()
        let stopped = try await f.send(.stop(sessionID: started.state.sessionID!), using: started)
        let pending = try await f.send(.readState, using: stopped)
        XCTAssertTrue(pending.accepted); XCTAssertEqual(pending.state.phase, .restoreAcceptedAwaitingWitness)
        let renew = try await f.send(.heartbeat(sessionID: started.state.sessionID!), using: pending)
        XCTAssertEqual(renew.failure, .staleGeneration)
        let start = try await f.send(.start(seconds: 60), using: pending)
        XCTAssertEqual(start.failure, .staleGeneration)
        f.clock.advance(1); var observation = await f.backend.observation
        observation.witness = .init(bootID: "boot-a", receivedAt: 101, sequence: 2, contextID: observation.contextID,
                                    notificationBits: 2, sleepAllowed: true)
        await f.backend.update(observation); _ = try await f.guardian.tick()
        let finished = try await f.send(.readState, using: pending)
        XCTAssertTrue(finished.accepted); XCTAssertEqual(finished.state.phase, .restored)
        await assertCalls(f.backend, [true, false])
    }
    func testLongSessionDoesNotLoseStopAuthorityAfterManyStateRequests() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var latest = try await f.start()
        for _ in 0..<135 { latest = try await f.send(.readState, using: latest); XCTAssertTrue(latest.accepted) }
        let stopped = try await f.send(.stop(sessionID: latest.state.sessionID!), using: latest)
        XCTAssertTrue(stopped.accepted); await assertCalls(f.backend, [true, false])
    }
    func testExpiredHeartbeatCannotRenewAndGuardianNeverRenewsApplicationLease() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let started = try await f.start()
        f.clock.advance(10); _ = try await f.guardian.tick()
        let still = try await f.controller.currentState(); XCTAssertEqual(still.leaseDeadline, 115)
        f.clock.advance(6)
        let denied = try await f.send(.heartbeat(sessionID: started.state.sessionID!), using: started)
        XCTAssertFalse(denied.accepted); XCTAssertEqual(denied.failure, .expired)
        await assertCalls(f.backend, [true, false])
    }
    func testSessionDeadlineCannotBeExtendedByHeartbeats() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open()
        var latest = try await f.send(.start(seconds: 20), using: opened)
        for _ in 0..<3 {
            f.clock.advance(5)
            latest = try await f.send(.heartbeat(sessionID: latest.state.sessionID!), using: latest)
            XCTAssertTrue(latest.accepted)
        }
        XCTAssertEqual(latest.state.sessionDeadline, 120); XCTAssertEqual(latest.state.leaseDeadline, 120)
        f.clock.advance(6); _ = try await f.guardian.tick(); await assertCalls(f.backend, [true, false])
    }
    func testWrongAuditSessionConnectionAndRevokedEpochCannotMutate() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let started = try await f.start()
        for peer in [ClosedLidPeer(userID: 501, auditSessionID: 43, connectionID: f.peer.connectionID),
                     ClosedLidPeer(userID: 501, auditSessionID: 42, connectionID: UUID())] {
            let denied = try await f.controller.perform(.init(sessionToken: started.sessionToken!, generation: started.generation + 1,
                command: .stop(sessionID: started.state.sessionID!)), peer: peer, activeUserID: 501)
            XCTAssertEqual(denied.failure, .wrongSession); XCTAssertNil(denied.sessionToken)
        }
        try f.journal.transaction { _, epoch in epoch = UUID() }
        let denied = try await f.send(.heartbeat(sessionID: started.state.sessionID!), using: started)
        XCTAssertEqual(denied.failure, .staleGeneration); await assertCalls(f.backend, [true])
    }
    func testStaleGuardianAndSecondControllerCannotAcquire() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); f.clock.advance(7)
        var observation = await f.backend.observation
        observation.witness = .init(bootID: "boot-a", receivedAt: 107, sequence: 2, contextID: observation.contextID,
                                    notificationBits: 2, sleepAllowed: true)
        await f.backend.update(observation)
        let opened = try await f.open()
        let stale = try await f.send(.start(seconds: 60), using: opened)
        XCTAssertEqual(stale.failure, .guardianUnavailable); await assertCalls(f.backend, [])
        _ = try await f.guardian.tick()
        let started = try await f.send(.start(seconds: 60), using: opened); XCTAssertTrue(started.accepted)
        let other = ClosedLidController(backend: f.backend, journal: f.journal, clock: { f.clock.now() }, bootID: { "boot-a" })
        let denied = try await other.openSession(peer: f.peer, activeUserID: 501)
        XCTAssertEqual(denied.failure, .recoveryRequired); await assertCalls(f.backend, [true])
    }
    func testControllerStartupRevokesEvenAnIdlePreviousSession() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open()
        let restarted = ClosedLidController(backend: f.backend, journal: f.journal, clock: { f.clock.now() }, bootID: { "boot-a" })
        _ = try await restarted.recoverAtStartup(activeUserID: 501)
        let denied = try await f.send(.start(seconds: 60), using: opened)
        XCTAssertEqual(denied.failure, .staleGeneration); await assertCalls(f.backend, [])
    }
    func testRejectedOtherConnectionOpenNeverDisclosesExistingSessionToken() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        let other = ClosedLidPeer(userID: 501, auditSessionID: 42, connectionID: UUID())
        let denied = try await f.controller.openSession(peer: other, activeUserID: 501)
        XCTAssertFalse(denied.accepted); XCTAssertNil(denied.sessionToken)
    }
    func testKnownApplyFailureLeavesRecoverableRestoreReceipt() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        await f.backend.fail(1)
        let denied = try await f.start()
        XCTAssertEqual(denied.failure, .commandRejected)
        XCTAssertEqual(denied.state.phase, .restoreAcceptedAwaitingWitness)
        XCTAssertTrue(denied.state.restoreCommandAccepted); await assertCalls(f.backend, [true, false])
    }
    func testTrustedServerDurationCapRejects121AndInvalidCapButAllows120() async throws {
        for cap in [120, 0, -1, 86_401] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await f.guardian.tick()
            let controller = ClosedLidController(backend: f.backend, journal: f.journal,
                clock: { f.clock.now() }, bootID: { "boot-a" }, maximumSessionSeconds: cap)
            let opened = try await controller.openSession(peer: f.peer, activeUserID: 501)
            let denied = try await controller.perform(.init(sessionToken: opened.sessionToken!, generation: opened.generation + 1,
                command: .start(seconds: 121)), peer: f.peer, activeUserID: 501)
            XCTAssertFalse(denied.accepted); XCTAssertEqual(denied.failure, .malformed)
            await assertCalls(f.backend, [])
            let allowed = try await controller.perform(.init(sessionToken: opened.sessionToken!, generation: opened.generation + 1,
                command: .start(seconds: 120)), peer: f.peer, activeUserID: 501)
            if cap == 120 {
                XCTAssertTrue(allowed.accepted); XCTAssertEqual(allowed.state.sessionDeadline, 220)
                XCTAssertEqual(allowed.state.leaseDeadline, 115); await assertCalls(f.backend, [true])
            } else {
                XCTAssertFalse(allowed.accepted); XCTAssertEqual(allowed.failure, .malformed)
                await assertCalls(f.backend, [])
            }
        }
    }
    func testMalformedVersionAndBoundedDurationDenyWithoutWrite() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let opened = try await f.open()
        let wrong = try await f.controller.perform(.init(version: 99, sessionToken: opened.sessionToken!, generation: opened.generation + 1, command: .start(seconds: 60)), peer: f.peer, activeUserID: 501)
        XCTAssertEqual(wrong.failure, .malformed)
        for duration in [0, -1, 86_401] {
            let denied = try await f.send(.start(seconds: duration), using: opened)
            XCTAssertFalse(denied.accepted)
        }
        await assertCalls(f.backend, [])
    }
}
