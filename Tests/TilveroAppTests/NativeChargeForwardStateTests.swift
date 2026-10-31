import XCTest
@testable import TilveroApp
import ChargeBackends

/// Every transport here is an isolated actor fixture; these tests never call PowerUI.
@MainActor final class NativeChargeForwardStateTests: XCTestCase {
    func testConfirmedReplacementCannotResumeSupersededPendingTarget() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(80, batteryPercent: 85, batteryFresh: true)
        XCTAssertEqual(f.service.pendingTarget, 80)
        await f.client.dropRegistrationAfterSet()
        do { try await f.service.apply(95, batteryPercent: 85, batteryFresh: true); XCTFail("Policy is not confirmed") } catch {}
        XCTAssertFalse(f.service.recoveryRequired)
        XCTAssertNil(f.service.pendingTarget, "The confirmed replacement supersedes the old pending request")
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
        XCTAssertNil(saved.plannedTarget)
        await f.client.restoreRegistration()
        await f.service.refresh()
        await f.service.observeBattery(percent: 79, fresh: true)
        let writes = await f.client.writes
        XCTAssertEqual(writes, [95], "A subsequent observation must not resurrect the old 80% request")
    }

    func testStandaloneReadTimeoutDoesNotInventUnknownWrite() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        let before = try Data(contentsOf: f.url)
        await f.client.configure(read: .suspend, after: 0)
        await f.service.refresh()
        XCTAssertFalse(f.service.recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: f.url), before)
        XCTAssertNil(f.service.observed)
        XCTAssertFalse(f.service.canApply)
        do { _ = try await f.service.restore(batteryPercent: 60, batteryFresh: true); XCTFail("Pending read must block restoration") } catch {}
        await f.client.release()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(f.service.observed, "A late read cannot publish current policy")
        XCTAssertFalse(f.service.recoveryRequired)
        await f.service.refresh()
        XCTAssertTrue(f.service.canApply)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testPendingIntentAttentionSurvivesTimedOutRefresh() async throws {
        for restoring in [false, true] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            if restoring {
                try await f.service.apply(95, batteryPercent: 60, batteryFresh: true)
                let restored = try await f.service.restore(batteryPercent: 90, batteryFresh: true)
                XCTAssertFalse(restored)
            } else {
                try await f.service.apply(80, batteryPercent: 85, batteryFresh: true)
            }
            await f.client.configure(read: .suspend, after: 0)
            await f.service.refresh()
            let presentation = f.service.presentation()
            XCTAssertEqual(presentation.attention, .operationPending)
            XCTAssertTrue(presentation.requiresGlobalAttention, "A pending read cannot hide retained charging intent")
            XCTAssertEqual(presentation.pendingTarget, restoring ? nil : 80)
            XCTAssertEqual(presentation.restorationTarget, restoring ? 85 : nil)
            await f.client.release()
        }
    }

    func testConfirmedSetterWithMissingRegistrationKeepsOwnershipWithoutMutationRecovery() async throws {
        for conflict in [false, true] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            await f.client.dropRegistrationAfterSet(conflict: conflict)
            do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Policy is not confirmed") } catch {}
            XCTAssertFalse(f.service.recoveryRequired)
            XCTAssertTrue(f.service.hasOwnedSettings)
            XCTAssertFalse(f.service.canApply)
            XCTAssertNil(f.service.observed)
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
            XCTAssertEqual(saved.phase, .owned)
            XCTAssertEqual(saved.baseline.target, 85)
            XCTAssertEqual(saved.lastVerified.target, 90)
            XCTAssertNil(saved.expectedMutation)
            await f.client.restoreRegistration()
            await f.service.refresh()
            XCTAssertTrue(f.service.canApply)
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        }
    }

    func testSecondApplyPreDispatchReadFailurePreservesOwnedJournalExactly() async throws {
        for behavior in [ForwardClient.ReadBehavior.fail, .stale, .missingPolicy, .suspend] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
            let before = try Data(contentsOf: f.url)
            await f.client.configure(read: behavior, after: 1)
            do { try await f.service.apply(95, batteryPercent: 60, batteryFresh: true); XCTFail("Read must prevent dispatch") } catch {}
            XCTAssertFalse(f.service.recoveryRequired)
            XCTAssertEqual(try Data(contentsOf: f.url), before)
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
            await f.client.release()
        }
    }

    func testFirstPostSetterReadFailureRetainsExpectedMutation() async throws {
        for behavior in [ForwardClient.ReadBehavior.fail, .suspend, .stale] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            await f.client.configure(read: behavior, after: 2)
            do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Configuration acknowledgement required") } catch {}
            XCTAssertTrue(f.service.recoveryRequired)
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
            XCTAssertEqual(saved.phase, .indeterminate)
            XCTAssertEqual(saved.expectedMutation?.target, 90)
            await f.client.release()
            for _ in 0..<100 { await Task.yield() }
            await f.service.refresh()
            XCTAssertTrue(f.service.recoveryRequired)
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        }
    }

    func testRestorePreDispatchFailuresPreserveEntryRecoveryAndBytes() async throws {
        for reopening in [false, true] {
            for behavior in [ForwardClient.ReadBehavior.fail, .stale, .missingPolicy, .suspend] {
                let f = ForwardFixture(); defer { f.cleanup() }
                await f.service.refresh()
                try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
                let service = reopening ? NativeChargeService(client: f.client, journalURL: f.url, admitted: true,
                    verificationAttempts: 1, environment: "fixture", operationTimeout: .milliseconds(30)) : f.service
                let before = try Data(contentsOf: f.url)
                await f.client.configure(read: behavior, after: 1)
                do { _ = try await service.restore(batteryPercent: 60, batteryFresh: true); XCTFail("No setter without valid read") } catch {}
                XCTAssertEqual(service.recoveryRequired, reopening)
                XCTAssertEqual(try Data(contentsOf: f.url), before)
                let writes = await f.client.writes; XCTAssertEqual(writes, [90])
                await f.client.release()
            }
        }
    }

    func testLaterVerificationReadFailureIsPolicyUncertaintyAfterConfirmedConfiguration() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        await f.client.configure(read: .fail, after: 3)
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Final policy read fails") } catch {}
        XCTAssertFalse(f.service.recoveryRequired)
        XCTAssertEqual(f.service.presentation().attention, .policyUnconfirmed)
        XCTAssertNil(f.service.presentation().activePolicy)
        await f.service.refresh()
        XCTAssertEqual(f.service.presentation().activePolicy?.target, 90)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testPartialEnableConfirmationDoesNotClaimFinalRequestedTarget() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.client.startDisabled()
        await f.service.refresh()
        await f.client.configure(read: .missingPolicy, after: 3)
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Second setter admission read fails") } catch {}
        XCTAssertFalse(f.service.recoveryRequired)
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
        XCTAssertTrue(saved.lastVerified.enabled)
        XCTAssertEqual(saved.lastVerified.target, 85)
        XCTAssertNil(saved.expectedMutation)
        XCTAssertEqual(saved.phase, .owned)
        XCTAssertNil(f.service.presentation().activePolicy)
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        let toggles = await f.client.enabledWrites; XCTAssertEqual(toggles, [true])
    }

    func testSecondSetterTimeoutDoesNotReuseEarlierEnableConfirmation() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.client.startDisabled()
        await f.service.refresh()
        await f.client.suspendLimit()
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Second setter must timeout") } catch {}
        XCTAssertTrue(f.service.recoveryRequired)
        XCTAssertEqual(f.service.presentation().pendingPurpose, .setLimit(target: 90))
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
        XCTAssertEqual(saved.lastVerified.target, 85)
        XCTAssertEqual(saved.expectedMutation?.target, 90)
        await f.client.release()
        for _ in 0..<100 { await Task.yield() }
        await f.service.refresh()
        XCTAssertTrue(f.service.recoveryRequired)
        XCTAssertEqual(f.service.presentation().attention, .mutationUnresolved)
        XCTAssertNil(f.service.presentation().activePolicy)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testWriteAheadAndConfirmedJournalPersistenceFailuresNeverInventInFlightSetter() async throws {
        for readsBeforeBlock in [1, 2] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            await f.client.blockJournal(f.url, after: readsBeforeBlock)
            do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Persistence must fail") } catch {}
            XCTAssertTrue(f.service.recoveryRequired)
            XCTAssertEqual(f.service.presentation().attention, .journalIntegrity)
            XCTAssertNil(f.service.presentation().pendingPurpose)
            let writes = await f.client.writes
            XCTAssertEqual(writes, readsBeforeBlock == 1 ? [] : [90])
        }
    }

    func testPresentationFreshnessPendingAndLegacyReviewPrecedence() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        let snapshot = try XCTUnwrap(f.service.nativeSetting)
        XCTAssertTrue(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(-5)))
        XCTAssertTrue(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(65)))
        XCTAssertFalse(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(-5.01)))
        XCTAssertFalse(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(65.01)))
        XCTAssertEqual(f.service.presentation(at: snapshot.collectedAt).attention, .none)
        XCTAssertFalse(f.service.presentation(at: snapshot.collectedAt).requiresGlobalAttention)
        XCTAssertNil(f.service.presentation(at: snapshot.collectedAt.addingTimeInterval(66)).activePolicy)
        XCTAssertEqual(f.service.presentation(at: snapshot.collectedAt.addingTimeInterval(66)).attention, .policyUnconfirmed)
        try await f.service.apply(80, batteryPercent: 85, batteryFresh: true)
        XCTAssertEqual(f.service.presentation().attention, .lowerTargetPending)
        XCTAssertTrue(f.service.presentation().requiresGlobalAttention)
        try f.service.cancelPending()
        let restored = try await f.service.restore(batteryPercent: 90, batteryFresh: true)
        XCTAssertFalse(restored)
        XCTAssertEqual(f.service.presentation().attention, .restorationPending)
    }

    func testBusyGateRejectsMutationBeforeDispatchCallback() async throws {
        let gate = NativeChargeOperationGate(timeout: .seconds(5))
        let client = ForwardClient()
        await client.configure(read: .suspend, after: 0)
        let pending = Task { try await gate.call(purpose: .read) { try await client.read() } }
        while gate.pendingPurpose == nil { await Task.yield() }
        var dispatched = false
        do {
            try await gate.call(purpose: .setLimit(target: 90), onDispatch: { dispatched = true }) {
                try await client.setLimit(90)
            }
            XCTFail("Busy gate must reject")
        } catch {}
        XCTAssertFalse(dispatched)
        // Admission can precede the fixture entering read; wait for the transport
        // to reach its suspension rather than assuming task scheduling order.
        while !(await client.isSuspended) { await Task.yield() }
        await client.release()
        _ = try await pending.value
        let writes = await client.writes; XCTAssertTrue(writes.isEmpty)
    }

    func testLegacyIndeterminateWithoutExpectedMutationNeverBecomesHealthy() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        let baseline = NativeChargeConfiguration(enabled: true, target: 80, optimizedCharging: true)
        let saved = NativeChargeJournal(sessionID: UUID(), environment: "fixture", baseline: baseline,
            lastVerified: .init(enabled: true, target: 85, optimizedCharging: true), plannedTarget: 85,
            phase: .indeterminate, hasWritten: true)
        try FileManager.default.createDirectory(at: f.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: f.url)
        let before = try Data(contentsOf: f.url)
        for registration in [false, true] {
            if registration { await f.client.restoreRegistration() } else { await f.client.removeRegistration() }
            let reopened = NativeChargeService(client: f.client, journalURL: f.url, admitted: true, verificationAttempts: 1, environment: "fixture", operationTimeout: .milliseconds(30))
            await reopened.refresh()
            XCTAssertEqual(reopened.presentation().attention, .sessionReview)
            XCTAssertNil(reopened.presentation().activePolicy)
            await f.client.configure(read: .suspend, after: 0)
            await reopened.refresh()
            XCTAssertEqual(reopened.presentation().attention, .sessionReview)
            await f.client.release()
            for _ in 0..<100 { await Task.yield() }
            await reopened.refresh()
            XCTAssertTrue(reopened.recoveryRequired)
            XCTAssertFalse(reopened.canApply)
            XCTAssertEqual(try Data(contentsOf: f.url), before)
        }
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }
}

@MainActor private struct ForwardFixture {
    let client = ForwardClient()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeForward-\(UUID().uuidString)/session.json")
    let service: NativeChargeService
    init() {
        service = NativeChargeService(client: client, journalURL: url, admitted: true, verificationAttempts: 1,
                                      environment: "fixture", operationTimeout: .milliseconds(30))
    }
    func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private actor ForwardClient: NativeChargeTransport {
    enum ReadBehavior { case fail, stale, missingPolicy, suspend }
    var writes: [Int] = []
    var enabledWrites: [Bool] = []
    private var enabled = true
    private var suspendNextLimit = false
    private var block: (URL, Int)?
    var isSuspended: Bool { continuation != nil }
    private var target = 85
    private var registration = true
    private var dropOnSet = false
    private var conflictingRegistration = false
    private var forcedRegistration: Int?
    private var planned: (ReadBehavior, Int)?
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(read: ReadBehavior, after: Int) { planned = (read, after) }
    func read() async throws -> NativeChargeSnapshot {
        var stale = false
        var available = true
        if let (behavior, remaining) = planned {
            if remaining > 0 { planned = (behavior, remaining - 1) }
            else {
                planned = nil
                switch behavior {
                case .fail: throw NativeChargeServiceError.readbackMismatch
                case .stale: stale = true
                case .missingPolicy: available = false
                case .suspend: await withCheckedContinuation { continuation = $0 }
                }
            }
        }
        if let (url, remaining) = block {
            if remaining > 0 { block = (url, remaining - 1) }
            else {
                block = nil
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        return .init(configuration: .init(enabled: enabled, target: target, optimizedCharging: true),
            supportedTargets: [80,85,90,95,100], registeredManualLimit: registration && enabled ? (forcedRegistration ?? target) : nil,
            policyReadbackAvailable: available, collectedAt: stale ? Date().addingTimeInterval(-120) : Date())
    }
    func setLimit(_ target: Int) async throws {
        writes.append(target)
        if suspendNextLimit { suspendNextLimit = false; await withCheckedContinuation { continuation = $0 } }
        self.target = target
        if dropOnSet {
            registration = conflictingRegistration
            forcedRegistration = conflictingRegistration ? 80 : nil
        }
    }
    func setEnabled(_ enabled: Bool) async throws { enabledWrites.append(enabled); self.enabled = enabled }
    func startDisabled() { enabled = false }
    func suspendLimit() { suspendNextLimit = true }
    func blockJournal(_ url: URL, after reads: Int) { block = (url, reads) }
    func dropRegistrationAfterSet(conflict: Bool = false) { dropOnSet = true; conflictingRegistration = conflict }
    func restoreRegistration() { registration = true; forcedRegistration = nil }
    func removeRegistration() { registration = false }
    func release() { continuation?.resume(); continuation = nil }
}
