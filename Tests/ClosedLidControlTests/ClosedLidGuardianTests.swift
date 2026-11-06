// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import Darwin
@testable import ClosedLidControl

final class ClosedLidGuardianTests: XCTestCase {
    func testLeaseExpiryClearsOnceAndWaitsForNewWitness() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start(); f.clock.advance(16)
        let restored = try await f.guardian.tick()
        XCTAssertEqual(restored.phase, .restoreAcceptedAwaitingWitness)
        XCTAssertTrue(restored.restoreCommandAccepted); XCTAssertFalse(restored.configurationVerified)
        _ = try await f.guardian.tick(); let once = await f.backend.calls
        XCTAssertEqual(once, [true, false])
        var observation = await f.backend.observation
        f.clock.advance(1); observation.sampledAt = 117
        let old = observation.witness!
        observation.witness = .init(bootID: "boot-a", receivedAt: 117, sequence: old.sequence + 1,
            contextID: old.contextID, notificationBits: 2, sleepAllowed: true)
        await f.backend.update(observation)
        let confirmed = try await f.guardian.tick()
        XCTAssertEqual(confirmed.phase, .restored); XCTAssertFalse(confirmed.recoveryRequired)
        XCTAssertFalse(confirmed.configurationVerified)
    }
    func testControllerStartupRecoversWithoutPublishingGuardianReadiness() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let pulse = f.directory.appendingPathComponent("guardian.json")
        _ = try await f.start(); let before = try Data(contentsOf: pulse)
        let restarted = ClosedLidController(backend: f.backend, journal: f.journal, clock: { f.clock.now() }, bootID: { "boot-a" })
        let state = try await restarted.recoverAtStartup(activeUserID: 501)
        XCTAssertEqual(state.phase, .restoreAcceptedAwaitingWitness)
        XCTAssertEqual(try Data(contentsOf: pulse), before)
        await assertCalls(f.backend, [true, false])
    }
    func testNewBootRetiresWithoutAnyKernelWrite() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        let newBoot = ClosedLidGuardian(backend: f.backend, journal: f.journal, clock: { f.clock.now() }, bootID: { "boot-b" })
        let state = try await newBoot.tick(startup: true)
        XCTAssertEqual(state.phase, .retiredAfterBoot)
        let calls = await f.backend.calls; XCTAssertEqual(calls, [true])
    }
    func testHelperRestartAndDisconnectRestoreButContextConflictRevokesWithoutClear() async throws {
        for conflict in [false, true] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await f.start()
            if conflict {
                var observation = await f.backend.observation; observation.contextID = UUID()
                await f.backend.update(observation)
            }
            let state = try await f.guardian.tick(startup: true)
            XCTAssertEqual(state.phase, conflict ? .conflict : .restoreAcceptedAwaitingWitness)
            let calls = await f.backend.calls; XCTAssertEqual(calls, conflict ? [true] : [true, false])
            let opened = try await f.controller.openSession(peer: f.peer, activeUserID: 501)
            XCTAssertFalse(opened.accepted)
        }
    }
    func testRejectedRestoreRetriesThreeTimesButAcceptedNeverRepeats() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start(); await f.backend.fail(10); f.clock.advance(16)
        for _ in 0..<8 { _ = try await f.guardian.tick() }
        let calls = await f.backend.calls; XCTAssertEqual(calls, [true, false, false, false])
        let state = try await f.controller.currentState()
        XCTAssertTrue(state.recoveryRequired); XCTAssertEqual(state.phase, .restorationRequired)
    }
    func testRestartFromEveryPreRestoreDurablePhaseClearsOnlyOnce() async throws {
        for phase in [ClosedLidPhase.prepared, .commandAccepted, .restorationRequired] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await f.start()
            try f.journal.transaction { record, _ in record!.state.phase = phase }
            let recovered = try await f.guardian.tick(startup: true)
            XCTAssertEqual(recovered.phase, .restoreAcceptedAwaitingWitness)
            _ = try await f.guardian.tick(startup: true); await assertCalls(f.backend, [true, false])
        }
    }
    func testOtherUserOrExternalDisplayRevokesWithoutClearingForeignContext() async throws {
        for uidConflict in [false, true] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await f.start(); var observation = await f.backend.observation
            if uidConflict { observation.activeUserID = 502 } else { observation.externalDisplayPresent = true }
            await f.backend.update(observation)
            let state = try await f.guardian.tick()
            XCTAssertEqual(state.phase, .conflict); XCTAssertTrue(state.recoveryRequired)
            await assertCalls(f.backend, [true])
        }
    }
    func testDeadControllerProcessTriggersRecoveryBeforeLeaseDeadline() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        try f.journal.transaction { record, _ in record!.controllerPID = Int32.max }
        let state = try await f.guardian.tick()
        XCTAssertEqual(state.phase, .restoreAcceptedAwaitingWitness)
        await assertCalls(f.backend, [true, false])
    }
    func testIndependentGuardianObserverCanConfirmAfterControllerSequence100() async throws {
        for (contextConflict, controllerDies) in [(false, false), (false, true), (true, false), (true, true)] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            var original = await f.backend.observation
            let observerA = original.witness!.observerID
            original.witness = .init(bootID: "boot-a", receivedAt: 100, sequence: 100, contextID: original.contextID,
                notificationBits: 2, sleepAllowed: true, observerID: observerA)
            await f.backend.update(original)
            let observerB = UUID()
            let backendB = LidTestBackend(context: contextConflict ? UUID() : original.contextID,
                clock: { f.clock.now() }, observerID: observerB)
            var observationB = await backendB.observation; observationB.witness = nil
            await backendB.update(observationB)
            let guardianB = ClosedLidGuardian(backend: backendB, journal: f.journal,
                clock: { f.clock.now() }, bootID: { "boot-a" })
            _ = try await guardianB.tick()
            let opened = try await f.open(); let started = try await f.send(.start(seconds: 60), using: opened)
            XCTAssertTrue(started.accepted)
            if controllerDies {
                try f.journal.transaction { record, _ in record!.controllerPID = Int32.max }
            } else { f.clock.advance(16) }
            let cleared = try await guardianB.tick()
            XCTAssertEqual(cleared.phase, contextConflict ? .conflict : .restoreAcceptedAwaitingWitness)
            await assertCalls(f.backend, [true]); await assertCalls(backendB, contextConflict ? [] : [false])
            guard !contextConflict else { continue }
            // A's sequence100 is meaningless in the independently started observerB.
            f.clock.advance(1)
            observationB.witness = .init(bootID: "boot-a", receivedAt: f.clock.now(), sequence: 1, contextID: original.contextID,
                notificationBits: 2, sleepAllowed: true, observerID: observerB)
            await backendB.update(observationB)
            let restored = try await guardianB.tick()
            XCTAssertEqual(restored.phase, .restored); XCTAssertFalse(restored.recoveryRequired)
            await assertCalls(backendB, [false])
        }
    }
    func testSameObserverRequiresNewSequenceAndCrossObserverStillRequiresPostClearTime() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = await f.backend.observation
        let observerB = UUID(); let backendB = LidTestBackend(context: original.contextID,
            clock: { f.clock.now() }, observerID: observerB)
        var observationB = await backendB.observation
        observationB.witness = .init(bootID: "boot-a", receivedAt: 100, sequence: 5, contextID: original.contextID,
            notificationBits: 2, sleepAllowed: true, observerID: observerB)
        await backendB.update(observationB)
        let guardianB = ClosedLidGuardian(backend: backendB, journal: f.journal,
            clock: { f.clock.now() }, bootID: { "boot-a" })
        _ = try await guardianB.tick(); let opened = try await f.open()
        _ = try await f.send(.start(seconds: 60), using: opened)
        await backendB.interceptAfter { disabled in if !disabled { f.clock.advance(1) } }
        f.clock.advance(16); _ = try await guardianB.tick(); f.clock.advance(1)
        // Relabeling the old sequence with a later timestamp is insufficient in the same observer.
        observationB.witness = .init(bootID: "boot-a", receivedAt: 118, sequence: 5, contextID: original.contextID,
            notificationBits: 2, sleepAllowed: true, observerID: observerB)
        await backendB.update(observationB)
        let repeated = try await guardianB.tick(); XCTAssertEqual(repeated.phase, .restoreAcceptedAwaitingWitness)
        // A restarted/different observer cannot reuse a witness received before the clear.
        observationB.witness = .init(bootID: "boot-a", receivedAt: 115, sequence: 1, contextID: original.contextID,
            notificationBits: 2, sleepAllowed: true, observerID: UUID())
        await backendB.update(observationB)
        let stale = try await guardianB.tick(); XCTAssertEqual(stale.phase, .restoreAcceptedAwaitingWitness)
        // Even a new observer cannot confirm from an event between issue and accepted return.
        observationB.witness = .init(bootID: "boot-a", receivedAt: 116.5, sequence: 1, contextID: original.contextID,
            notificationBits: 2, sleepAllowed: true, observerID: UUID())
        await backendB.update(observationB)
        let preReceipt = try await guardianB.tick(); XCTAssertEqual(preReceipt.phase, .restoreAcceptedAwaitingWitness)
        observationB.witness = .init(bootID: "boot-a", receivedAt: 118, sequence: 6, contextID: original.contextID,
            notificationBits: 2, sleepAllowed: true, observerID: observerB)
        await backendB.update(observationB)
        let restored = try await guardianB.tick(); XCTAssertEqual(restored.phase, .restored)
        await assertCalls(f.backend, [true]); await assertCalls(backendB, [false])
    }
    func testClosedLidAcceptedClearRequestsNormalSleepExactlyOnceWithDurableIntent() async throws {
        for trigger in 0..<3 {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let started = try await f.start()
            var observation = await f.backend.observation; observation.lidClosed = true; observation.witness = nil
            await f.backend.update(observation)
            await f.backend.interceptSleep {
                let record = try f.journal.load()!
                XCTAssertTrue(record.state.restoreCommandAccepted)
                XCTAssertEqual(record.state.normalSleepRequestAttempted, true)
                XCTAssertNil(record.state.normalSleepRequestAccepted)
            }
            let stopped: ClosedLidState
            if trigger == 0 { stopped = try await f.send(.stop(sessionID: started.state.sessionID!), using: started).state }
            else {
                if trigger == 1 { f.clock.advance(16) }
                else { try f.journal.transaction { record, _ in record!.controllerPID = Int32.max } }
                stopped = try await f.guardian.tick()
            }
            XCTAssertEqual(stopped.normalSleepRequestAttempted, true)
            XCTAssertEqual(stopped.normalSleepRequestAccepted, true)
            XCTAssertFalse(stopped.behaviorObserved); XCTAssertFalse(stopped.configurationVerified)
            for _ in 0..<3 { _ = try await f.guardian.tick(startup: true) }
            let sleepCalls = await f.backend.sleepCalls; XCTAssertEqual(sleepCalls, 1)
            await assertCalls(f.backend, [true, false])
        }
    }
    func testNormalSleepAcceptedThenJournalFailureLeavesIntentAndNeverRepeats() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let started = try await f.start(); var observation = await f.backend.observation
        observation.lidClosed = true; observation.witness = nil; await f.backend.update(observation)
        let path = f.directory.appendingPathComponent("ownership.json")
        await f.backend.interceptSleep { chmod(path.path, 0o644) }
        do { _ = try await f.send(.stop(sessionID: started.state.sessionID!), using: started); XCTFail("Post-Sleep journal failure must stay visible") }
        catch {}
        chmod(path.path, 0o600)
        let pending = try f.journal.load()!
        XCTAssertEqual(pending.state.normalSleepRequestAttempted, true); XCTAssertNil(pending.state.normalSleepRequestAccepted)
        for _ in 0..<3 { _ = try await f.guardian.tick(startup: true) }
        let calls = await f.backend.sleepCalls; XCTAssertEqual(calls, 1)
        await assertCalls(f.backend, [true, false])
    }
    func testNormalSleepIsNeverRequestedForOpenUnknownExternalConflictOrRejectedClear() async throws {
        for variant in 0..<6 {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let started = try await f.start(); var observation = await f.backend.observation
            observation.witness = nil; observation.lidClosed = variant == 0 ? false : (variant == 1 ? nil : true)
            if variant == 2 { observation.externalDisplayPresent = true }
            if variant == 3 { observation.contextID = UUID() }
            await f.backend.update(observation)
            if variant == 4 { await f.backend.fail(3) }
            if variant == 5 {
                try f.journal.transaction { record, epoch in
                    record!.state.phase = .restoreAcceptedAwaitingWitness
                    record!.state.restoreCommandAccepted = false; record!.restoreIssuedAt = 100
                    record!.revoked = true; epoch = UUID()
                }
                _ = try await f.guardian.tick(startup: true)
            } else { _ = try await f.send(.stop(sessionID: started.state.sessionID!), using: started) }
            let sleepCalls = await f.backend.sleepCalls; XCTAssertEqual(sleepCalls, 0)
        }
    }
    func testNormalSleepUsesFreshPostClearObservationInsteadOfPreClearClosedLid() async throws {
        for variant in 0..<5 {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let started = try await f.start(); var before = await f.backend.observation
            before.lidClosed = true; before.witness = nil; await f.backend.update(before)
            var after = before
            if variant == 0 { after.lidClosed = false }
            if variant == 1 { after.lidClosed = nil }
            if variant == 2 { after.contextID = UUID() }
            if variant == 3 { after.externalDisplayPresent = true }
            if variant == 4 { after.activeUserID = 502 }
            await f.backend.changeObservationAfterClear(after)
            let stopped = try await f.send(.stop(sessionID: started.state.sessionID!), using: started)
            XCTAssertTrue(stopped.state.restoreCommandAccepted)
            XCTAssertEqual(stopped.state.normalSleepRequestAttempted, false)
            let calls = await f.backend.sleepCalls; XCTAssertEqual(calls, 0)
            await assertCalls(f.backend, [true, false])
        }
    }
    func testNormalSleepIntentAfterCrashAndAmbiguousErrorIsNeverRetried() async throws {
        for seededIntent in [false, true] {
            let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let started = try await f.start(); var observation = await f.backend.observation
            observation.lidClosed = true; observation.witness = nil; await f.backend.update(observation)
            if seededIntent {
                try f.journal.transaction { record, epoch in
                    record!.state.phase = .restoreAcceptedAwaitingWitness; record!.state.restoreCommandAccepted = true
                    record!.restoreReceipt = .init(disabled: false, acceptedAt: 100); record!.restoreIssuedAt = 100
                    record!.state.normalSleepRequestAttempted = true; record!.state.normalSleepRequestAccepted = nil
                    record!.revoked = true; epoch = UUID()
                }
            } else {
                await f.backend.failSleep()
                _ = try await f.send(.stop(sessionID: started.state.sessionID!), using: started)
            }
            for _ in 0..<3 { _ = try await f.guardian.tick(startup: true) }
            let calls = await f.backend.sleepCalls; XCTAssertEqual(calls, seededIntent ? 0 : 1)
            let state = try await f.controller.currentState()
            XCTAssertEqual(state.normalSleepRequestAttempted, true); XCTAssertNil(state.normalSleepRequestAccepted)
        }
    }
    func testCrashDuringRestoreIntentDoesNotBlindlyRepeat() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        try f.journal.transaction { record, epoch in
            record!.state.phase = .restoreAcceptedAwaitingWitness
            record!.restoreBoundarySequence = 1
            record!.restoreIssuedAt = 100
            record!.state.restoreCommandAccepted = false
            epoch = UUID(); record!.revoked = true
        }
        _ = try await f.guardian.tick(startup: true)
        let calls = await f.backend.calls; XCTAssertEqual(calls, [true])
        let state = try await f.controller.currentState(); XCTAssertTrue(state.recoveryRequired)
    }
}
