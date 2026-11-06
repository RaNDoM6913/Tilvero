// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import CoreFoundation
@testable import ClosedLidControl

final class ClamshellBackendTests: XCTestCase {
    func testFixedABIAndCloseOnBothAcceptedAndRejectedCalls() throws {
        let calls = Calls()
        let port = RootDomainClamshellPort(effectiveUID: { 0 }, open: { 41 }, call: { connection, selector, input in
            calls.append(connection, selector, input); return input == 1 ? 0 : -1
        }, close: { calls.close($0) })
        try port.setLidSleepDisabled(true)
        XCTAssertThrowsError(try port.setLidSleepDisabled(false))
        XCTAssertEqual(calls.inputs, [1, 0]); XCTAssertEqual(calls.selectors, [12, 12])
        XCTAssertEqual(calls.connections, [41, 41]); XCTAssertEqual(calls.closed, [41, 41])
    }
    func testNormalSleepIsSeparateFixedOperationWithAcceptanceAndClose() async throws {
        let calls = Calls()
        let port = RootDomainClamshellPort(effectiveUID: { 0 }, open: { 41 },
            call: { c,s,i in calls.append(c,s,i); return 0 }, close: { calls.close($0) },
            sleep: { connection in calls.sleep(connection); return 0 })
        let backend = ClamshellUserClientBackend(port: port, observer: makeTracker(), clock: { 100 })
        XCTAssertTrue(calls.sleepConnections.isEmpty)
        let accepted = try await backend.requestNormalSleep()
        XCTAssertTrue(accepted)
        XCTAssertEqual(calls.sleepConnections, [41]); XCTAssertEqual(calls.closed, [41])
        XCTAssertTrue(calls.inputs.isEmpty)
    }
    func testNormalSleepRejectsNonrootAndClosesAfterKernelRejection() async {
        let denied = Calls()
        let deniedPort = RootDomainClamshellPort(effectiveUID: { 501 }, open: { denied.close(999); return 41 },
            call: { _,_,_ in 0 }, close: { denied.close($0) }, sleep: { denied.sleep($0); return 0 })
        XCTAssertThrowsError(try deniedPort.requestNormalSleep())
        XCTAssertTrue(denied.closed.isEmpty); XCTAssertTrue(denied.sleepConnections.isEmpty)
        let rejected = Calls()
        let rejectedPort = RootDomainClamshellPort(effectiveUID: { 0 }, open: { 41 },
            call: { _,_,_ in 0 }, close: { rejected.close($0) }, sleep: { rejected.sleep($0); return -1 })
        let backend = ClamshellUserClientBackend(port: rejectedPort, observer: makeTracker(), clock: { 100 })
        do { _ = try await backend.requestNormalSleep(); XCTFail("Rejected normal Sleep claimed accepted") }
        catch { XCTAssertEqual(error as? ClosedLidFailure, .commandRejected) }
        XCTAssertEqual(rejected.sleepConnections, [41]); XCTAssertEqual(rejected.closed, [41])
    }
    func testNormalSleepDoesNotConvertFalseAcceptanceToTrue() async throws {
        let backend = ClamshellUserClientBackend(port: UnacceptedSleepPort(), observer: makeTracker(), clock: { 100 })
        let accepted = try await backend.requestNormalSleep()
        XCTAssertFalse(accepted)
    }
    func testUnprivilegedPortDoesNotOpenOrCall() {
        let calls = Calls()
        let port = RootDomainClamshellPort(effectiveUID: { 501 }, open: { calls.close(999); return 41 }, call: { c, s, i in calls.append(c,s,i); return 0 }, close: { calls.close($0) })
        XCTAssertThrowsError(try port.setLidSleepDisabled(true))
        XCTAssertTrue(calls.closed.isEmpty); XCTAssertTrue(calls.inputs.isEmpty)
    }
    func testNativeTrueNotificationWithUnknownPowerCannotWitnessBaseline() throws {
        let tracker = ClamshellObservationTracker(sample: { .init(activeUserID: 501, lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: true, powerSourceType: nil) }, clock: { 100 }, bootID: { "boot-a" })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let observed = try tracker.observation()
        XCTAssertEqual(observed.aggregateSleepAllowed, true)
        XCTAssertNil(observed.witness)
    }
    func testRealBackendCompositionDeniesUnknownPowerWithoutAnyPortWrite() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory().replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)).appendingPathComponent("tilvero-lid-platform-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ClosedLidJournal(directory: directory)
        let tracker = ClamshellObservationTracker(sample: { .init(activeUserID: 501, lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: true, powerSourceType: nil) }, clock: { 100 }, bootID: { "boot-a" })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let calls = Calls()
        let port = RootDomainClamshellPort(effectiveUID: { 0 }, open: { calls.close(999); return 41 }, call: { c,s,i in calls.append(c,s,i); return 0 }, close: { calls.close($0) })
        let backend = ClamshellUserClientBackend(port: port, observer: tracker, clock: { 100 })
        let guardian = ClosedLidGuardian(backend: backend, journal: journal, clock: { 100 }, bootID: { "boot-a" })
        let controller = ClosedLidController(backend: backend, journal: journal, clock: { 100 }, bootID: { "boot-a" })
        _ = try await guardian.tick()
        let peer = ClosedLidPeer(userID: 501, auditSessionID: 77, connectionID: UUID())
        let opened = try await controller.openSession(peer: peer, activeUserID: 501)
        let token = try XCTUnwrap(opened.sessionToken)
        let started = try await controller.perform(.init(sessionToken: token, generation: opened.generation + 1, command: .start(seconds: 60)), peer: peer, activeUserID: 501)
        XCTAssertFalse(started.accepted)
        XCTAssertEqual(started.failure, .baselineWitnessRequired)
        XCTAssertTrue(calls.inputs.isEmpty); XCTAssertTrue(calls.closed.isEmpty)
    }
    func testRegistryTrueNeverMakesBaselineWitnessAndInvalidNativeBitsRevoke() throws {
        let tracker = makeTracker()
        XCTAssertEqual(try tracker.observation().aggregateSleepAllowed, true)
        XCTAssertNil(try tracker.observation().witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let observed = try tracker.observation()
        XCTAssertEqual(observed.witness?.notificationBits, 2)
        XCTAssertEqual(observed.witness?.receivedAt, 100)
        XCTAssertEqual(observed.witness?.contextID, observed.contextID)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 6)
        XCTAssertNil(try tracker.observation().witness)
    }
    func testOnlyExpectedNotificationCreatesWitnessAndFalseRevokesIt() throws {
        let tracker = makeTracker()
        tracker.receiveNativeNotification(message: 123, bits: 2)
        XCTAssertNil(try tracker.observation().witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        XCTAssertNotNil(try tracker.observation().witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 0)
        XCTAssertNil(try tracker.observation().witness)
    }
    func testContextChangesRevokeWitnessAndUnknownDisplayStaysUnknown() throws {
        let sample = Sample()
        let tracker = ClamshellObservationTracker(sample: { sample.value }, clock: { 100 }, bootID: { "boot-a" })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let original = try tracker.observation()
        XCTAssertNil(original.externalDisplayPresent)
        sample.value.powerSourceType = "Battery Power"
        tracker.contextChanged()
        let changed = try tracker.observation()
        XCTAssertNotEqual(original.contextID, changed.contextID); XCTAssertNil(changed.witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        sample.value = .init(activeUserID: 502, lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: true)
        XCTAssertNil(try tracker.observation().witness)
    }
    func testIndependentObserversShareSemanticContextWithoutSharingWitnessIdentity() throws {
        let sample = Sample()
        let first = ClamshellObservationTracker(sample: { sample.value }, clock: { 100 }, bootID: { "boot-a" })
        let second = ClamshellObservationTracker(sample: { sample.value }, clock: { 100 }, bootID: { "boot-a" })
        first.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        second.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let a = try first.observation(), b = try second.observation()
        XCTAssertEqual(a.contextID, b.contextID)
        XCTAssertNotEqual(a.witness?.observerID, b.witness?.observerID)
        first.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        XCTAssertEqual(a.witness?.observerID, try first.observation().witness?.observerID)
        sample.value.powerSourceType = "Battery Power"
        let changedA = try first.observation(), changedB = try second.observation()
        XCTAssertEqual(changedA.contextID, changedB.contextID)
        XCTAssertNotEqual(a.contextID, changedA.contextID)
        XCTAssertNil(changedA.witness); XCTAssertNil(changedB.witness)
    }
    func testSemanticContextIncludesPowerUnknownConsoleAndExternalIdentity() throws {
        let sample = Sample()
        sample.value.externalDisplayPresent = true
        sample.value.externalDisplayIDs = [8,4]
        let tracker = ClamshellObservationTracker(sample: { sample.value }, clock: { 100 }, bootID: { "boot-a" })
        let initial = try tracker.observation().contextID
        sample.value.externalDisplayIDs = [4,8]
        XCTAssertEqual(initial, try tracker.observation().contextID)
        sample.value.externalDisplayIDs = [4,9]
        XCTAssertNotEqual(initial, try tracker.observation().contextID)
        sample.value.externalDisplayIDs = [8,4]
        sample.value.powerSourceType = nil
        XCTAssertNotEqual(initial, try tracker.observation().contextID)
        sample.value.powerSourceType = "AC Power"
        sample.value.activeUserID = nil
        XCTAssertNotEqual(initial, try tracker.observation().contextID)
    }
    func testBenignContextNotificationAndBuiltinDisplayChangesPreserveWitness() throws {
        let sample = Sample()
        let tracker = ClamshellObservationTracker(sample: { sample.value }, clock: { 100 }, bootID: { "boot-a" })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let before = try tracker.observation()
        tracker.contextChanged()
        sample.value.lidClosed = true
        sample.value.aggregateSleepAllowed = false
        let after = try tracker.observation()
        XCTAssertEqual(before.contextID, after.contextID)
        XCTAssertEqual(before.witness, after.witness)
    }
    func testOnlineEmptyListIsMeasuredAbsentOnlyWithSuccessfulQueryAndKnownConsole() {
        XCTAssertEqual(ClamshellOnlineDisplays.externalIDs(querySucceeded: true, onlineIDs: [], truncated: false, activeUserID: 501, isBuiltIn: { _ in false }), [])
        XCTAssertNil(ClamshellOnlineDisplays.externalIDs(querySucceeded: false, onlineIDs: [], truncated: false, activeUserID: 501, isBuiltIn: { _ in false }))
        XCTAssertNil(ClamshellOnlineDisplays.externalIDs(querySucceeded: true, onlineIDs: [], truncated: false, activeUserID: nil, isBuiltIn: { _ in false }))
        XCTAssertNil(ClamshellOnlineDisplays.externalIDs(querySucceeded: true, onlineIDs: [4], truncated: true, activeUserID: 501, isBuiltIn: { _ in false }))
        XCTAssertEqual(ClamshellOnlineDisplays.externalIDs(querySucceeded: true, onlineIDs: [1,4,3], truncated: false, activeUserID: 501, isBuiltIn: { $0 == 1 }), [3,4])
    }
    func testStaleBackwardAndNewBootNotificationsCannotRemainWitnesses() throws {
        let time = ObservationTime()
        let tracker = ClamshellObservationTracker(sample: { .init(activeUserID: 501, lidClosed: false, externalDisplayPresent: false, powerSourceType: "AC Power") }, clock: { time.now }, bootID: { time.boot })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        time.now = 106
        XCTAssertNil(try tracker.observation().witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        time.now = 105
        XCTAssertNil(try tracker.observation().witness)
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        let context = try tracker.observation().contextID
        time.boot = "boot-b"
        let newBoot = try tracker.observation()
        XCTAssertNil(newBoot.witness); XCTAssertNotEqual(context, newBoot.contextID)
    }
    func testMalformedClockBootAndNonBooleanRegistryAreUnavailable() throws {
        XCTAssertNil(ClamshellRegistryBoolean.decode(NSNumber(value: 1)))
        XCTAssertNil(ClamshellRegistryBoolean.decode("true" as CFString))
        XCTAssertEqual(ClamshellRegistryBoolean.decode(kCFBooleanTrue), true)
        XCTAssertEqual(ClamshellRegistryBoolean.decode(kCFBooleanFalse), false)
        let tracker = ClamshellObservationTracker(sample: { .init(activeUserID: 501) }, clock: { .nan }, bootID: { "unavailable" })
        tracker.receiveNativeNotification(message: ClamshellNativeABI.stateMessage, bits: 2)
        XCTAssertThrowsError(try tracker.observation())
    }
    private func makeTracker() -> ClamshellObservationTracker {
        ClamshellObservationTracker(sample: { .init(activeUserID: 501, lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: true, powerSourceType: "AC Power") }, clock: { 100 }, bootID: { "boot-a" })
    }
}
private final class Calls: @unchecked Sendable {
    var inputs: [UInt64] = []; var selectors: [UInt32] = []; var connections: [UInt32] = []; var closed: [UInt32] = []; var sleepConnections: [UInt32] = []
    func append(_ c: UInt32, _ s: UInt32, _ i: UInt64) { connections.append(c); selectors.append(s); inputs.append(i) }
    func close(_ c: UInt32) { closed.append(c) }
    func sleep(_ c: UInt32) { sleepConnections.append(c) }
}
private final class Sample: @unchecked Sendable {
    var value = ClamshellContextSample(activeUserID: 501, lidClosed: false, externalDisplayPresent: nil, aggregateSleepAllowed: true, powerSourceType: "AC Power")
}

private final class ObservationTime: @unchecked Sendable { var now: Double = 100; var boot = "boot-a" }

private struct UnacceptedSleepPort: ClamshellUserClientPort {
    func setLidSleepDisabled(_ disabled: Bool) throws { throw ClosedLidFailure.unsupported }
    func requestNormalSleep() throws -> Bool { false }
}
