import XCTest
import Foundation
import Darwin
import PowerCore
@testable import PowerPrivileged

private actor FanHardwareFixture: PrivilegedHardware {
    private var targets = ["0": 0, "1": 0]
    private var automatic = ["0": true, "1": true]
    private var clock: Double = 10
    private var sensorFresh = true
    private var missingRPM = false
    private var actualOverride: Int?
    private var failFanOneManual = false
    private var failFanOneTarget = false
    private var restorationBlocked = false
    private var writes: [(FanRegister, FanRegisterValue)] = []
    private let journal: SecureJournal
    init(journal: SecureJournal, partialFailure: Bool = false) { self.journal = journal; failFanOneManual = partialFailure }
    func capabilities() -> [ControlCapability] { [.init(backend: "fixture-fan", readiness: .available, reason: "Explicit in-memory fixture")] }
    func qualify(_ resource: OwnedResource) {}
    func chargeObservation() throws -> ChargeObservation { throw PolicyError.unavailable }
    func fanObservation() async throws -> FanObservation {
        var actual = targets.mapValues { $0 == 0 ? 1500 : $0 }
        if missingRPM { actual.removeValue(forKey: "1") }
        if let actualOverride { actual["0"] = actualOverride }
        return FanObservation(descriptors: ["0", "1"].map { .init(id: $0, minimumRPM: 1200, maximumRPM: 6000) }, actualRPM: actual,
            targetRPM: targets, autoMode: automatic, sensorTemperature: sensorFresh ? 50 : nil, sensorFresh: sensorFresh,
            sampledContinuousSeconds: clock)
    }
    func read(_ resource: OwnedResource) throws -> HardwareSetting {
        guard resource == .fans else { throw PolicyError.unavailable }
        if automatic.values.allSatisfy({ $0 }) { return .fanAuto }
        guard automatic.values.allSatisfy({ !$0 }) else { throw PolicyError.readbackMismatch }
        return .fanRPM(targets)
    }
    func write(_ setting: HardwareSetting, resource: OwnedResource) throws { throw PolicyError.invalidPolicy }
    func writeFanRegister(_ register: FanRegister, value: FanRegisterValue) throws {
        let file = journal.directory.appendingPathComponent("ownership.json")
        let saved = try JSONDecoder().decode(OwnershipJournal.self, from: Data(contentsOf: file))
        guard saved.entries[.fans]?.fanSteps.contains(where: { $0.register == register && ($0.intended == value || $0.original == value) && ($0.phase == .prepared || $0.phase == .recovering) }) == true else { throw PolicyError.invalidContract }
        writes.append((register, value))
        if failFanOneManual, register == .automatic(fanID: "1"), value == .automatic(false) {
            failFanOneManual = false; restorationBlocked = true; throw PolicyError.readbackMismatch
        }
        if failFanOneTarget, register == .target(fanID: "1") {
            failFanOneTarget = false; restorationBlocked = true; throw PolicyError.readbackMismatch
        }
        if restorationBlocked { throw PolicyError.readbackMismatch }
        switch (register, value) {
        case let (.target(id), .rpm(rpm)): targets[id] = rpm
        case let (.automatic(id), .automatic(auto)): automatic[id] = auto
        default: throw PolicyError.invalidPolicy
        }
    }
    func setTime(_ time: Double, freshSensor: Bool = true, missingRPM: Bool = false, actualRPM: Int? = nil) {
        clock = time; sensorFresh = freshSensor; self.missingRPM = missingRPM; actualOverride = actualRPM
    }
    func allowRestoration() { restorationBlocked = false }
    func failNextTargetUpdate() { failFanOneTarget = true }
    func foreignChange(fan: String, rpm: Int) { targets[fan] = rpm; automatic[fan] = false }
    func recordedWriteCount() -> Int { writes.count }
}

@MainActor final class FanRuntimeTests: XCTestCase {
    private func setup(partialFailure: Bool = false) async throws -> (URL, SecureJournal, FanHardwareFixture, PrivilegedController, PeerSession, UUID) {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-fan-runtime-\(UUID())")
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
        let hardware = FanHardwareFixture(journal: journal, partialFailure: partialFailure)
        let controller = PrivilegedController(hardware: hardware, journal: journal, bootID: "boot")
        let peer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
        let session = try await controller.openSession(peer: peer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
        return (directory, journal, hardware, controller, peer, try XCTUnwrap(session.sessionToken))
    }
    private func payload(_ command: HelperCommand, token: UUID, generation: UInt64 = 1) throws -> Data {
        try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: generation, command: command))
    }

    func testPartialMultiFanWriteHasPerRegisterRecoveryAndActualReadState() async throws {
        let (directory, journal, hardware, controller, peer, token) = try await setup(partialFailure: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token), peer: peer, activeUserID: 501, now: 10); XCTFail("Injected second-fan failure must fail") } catch {}
        let state = try await controller.readState(now: 10)
        XCTAssertEqual(state.ownedResources, [.fans]); XCTAssertTrue(state.recoveryRequired)
        XCTAssertEqual(state.fanObservation?.autoMode, ["0": false, "1": true])
        XCTAssertNil(state.observedSettings[.fans], "A mixed hardware mode must not become fabricated aggregate success")
        await hardware.allowRestoration()
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        let restored = try await guardian.recover(now: 26, activeUserID: 501); XCTAssertTrue(restored)
        let observed = try await hardware.fanObservation()
        XCTAssertEqual(observed.autoMode, ["0": true, "1": true]); XCTAssertEqual(observed.targetRPM, ["0": 0, "1": 0])
        let lock = try journal.acquireLock(); XCTAssertTrue(try XCTUnwrap(journal.read(lock: lock)).entries.isEmpty)
    }

    func testForeignFanTargetIsPreservedWhileOtherPartiallyOwnedFanRestores() async throws {
        let (directory, journal, hardware, controller, peer, token) = try await setup(partialFailure: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await controller.perform(payload(.setFanRPM(["0": 3000, "1": 3000]), token: token), peer: peer, activeUserID: 501, now: 10); XCTFail("Injected failure") } catch {}
        await hardware.allowRestoration(); await hardware.foreignChange(fan: "0", rpm: 4500)
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        do { _ = try await guardian.recover(now: 26, activeUserID: 501); XCTFail("Foreign fan remains unresolved") } catch PrivilegeError.recoveryRequired {}
        let observed = try await hardware.fanObservation()
        XCTAssertEqual(observed.targetRPM["0"], 4500); XCTAssertEqual(observed.autoMode["0"], false)
        XCTAssertEqual(observed.targetRPM["1"], 0); XCTAssertEqual(observed.autoMode["1"], true)
        let lock = try journal.acquireLock(), retained = try XCTUnwrap(journal.read(lock: lock))
        XCTAssertEqual(retained.entries[.fans]?.phase, .unresolved)
        XCTAssertTrue(retained.entries[.fans]?.fanSteps.filter { $0.register.fanID == "1" }.allSatisfy { $0.phase == .restored } == true)
    }

    func testHelperOwnedBoostExpiresDespiteHeartbeatAndReadStateReportsActualEvidence() async throws {
        let (directory, _, hardware, controller, peer, token) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applied = try await controller.perform(payload(.setFanPolicy(.boost(rpm: 3000, seconds: 4)), token: token), peer: peer, activeUserID: 501, now: 10)
        XCTAssertTrue(applied.configurationVerified); XCTAssertFalse(applied.behaviorObserved)
        XCTAssertEqual(applied.fanPolicyState?.phase, .managed)
        await hardware.setTime(12)
        let heartbeat = try await controller.perform(payload(.heartbeat, token: token), peer: peer, activeUserID: 501, now: 12)
        XCTAssertEqual(heartbeat.ownedResources, [.fans]); XCTAssertTrue(heartbeat.capabilities.isEmpty)
        await hardware.setTime(14); await controller.tickFanPolicy(now: 14, activeUserID: 501)
        let released = try await controller.readState(now: 14)
        XCTAssertTrue(released.ownedResources.isEmpty); XCTAssertFalse(released.recoveryRequired)
        XCTAssertEqual(released.fanPolicyState?.phase, .systemAuto)
        XCTAssertEqual(released.fanObservation?.autoMode, ["0": true, "1": true])
    }

    func testHelperCurveStaleSensorAndManualLostLeaseReleaseWithoutGUI() async throws {
        let (directory, _, hardware, controller, peer, token) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let curve = try FanCurve(points: [.init(celsius: 40, rpm: 1800), .init(celsius: 80, rpm: 5000)])
        _ = try await controller.perform(payload(.setFanPolicy(.curve(curve)), token: token), peer: peer, activeUserID: 501, now: 10)
        await hardware.setTime(11); await controller.tickFanPolicy(now: 11, activeUserID: 501)
        let managed = try await controller.readState(now: 11); XCTAssertEqual(managed.fanPolicyState?.phase, .managed)
        await hardware.setTime(12, freshSensor: false); await controller.tickFanPolicy(now: 12, activeUserID: 501)
        let staleReleased = try await controller.readState(now: 12); XCTAssertEqual(staleReleased.fanPolicyState?.phase, .systemAuto)
        await hardware.setTime(13)
        _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token, generation: 2), peer: peer, activeUserID: 501, now: 13)
        await hardware.setTime(29); await controller.tickFanPolicy(now: 29, activeUserID: 501)
        let expired = try await controller.readState(now: 29); XCTAssertEqual(expired.fanPolicyState?.phase, .systemAuto)
    }

    func testMissingRPMAndSleepCauseHelperAutoRecovery() async throws {
        let (directory, _, hardware, controller, peer, token) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token), peer: peer, activeUserID: 501, now: 10)
        await hardware.setTime(11, missingRPM: true); await controller.tickFanPolicy(now: 11, activeUserID: 501)
        let incomplete = try await controller.readState(now: 11)
        XCTAssertEqual(incomplete.fanObservation?.autoMode, ["0": true, "1": true])
        await hardware.setTime(12)
        _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token, generation: 2), peer: peer, activeUserID: 501, now: 12)
        await hardware.setTime(13); await controller.tickFanPolicy(now: 13, activeUserID: 501, sleeping: true)
        let slept = try await controller.readState(now: 13); XCTAssertTrue(slept.ownedResources.isEmpty)
    }

    func testInterruptedSecondTargetTransitionRestoresPriorOwnedIntermediateValue() async throws {
        let (directory, journal, hardware, controller, peer, token) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token), peer: peer, activeUserID: 501, now: 10)
        await hardware.setTime(11); await hardware.failNextTargetUpdate()
        do { _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 4000, "1": 4000])), token: token, generation: 2), peer: peer, activeUserID: 501, now: 11); XCTFail("Interrupted second target update") } catch {}
        let partial = try await controller.readState(now: 11)
        XCTAssertEqual(partial.fanObservation?.targetRPM, ["0": 4000, "1": 3000])
        await hardware.allowRestoration()
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        let recovered = try await guardian.recover(now: 27, activeUserID: 501); XCTAssertTrue(recovered)
        let observed = try await hardware.fanObservation()
        XCTAssertEqual(observed.autoMode, ["0": true, "1": true]); XCTAssertEqual(observed.targetRPM, ["0": 0, "1": 0])
    }

    func testRevokedFanLoopCannotReacquireAfterNextOwnerReleases() async throws {
        for recreateController in [false, true] {
            let (directory, journal, hardware, oldController, oldPeer, oldToken) = try await setup()
            defer { try? FileManager.default.removeItem(at: directory) }
            let curve = try FanCurve(points: [.init(celsius: 40, rpm: 1800), .init(celsius: 80, rpm: 5000)])
            _ = try await oldController.perform(payload(.setFanPolicy(.curve(curve)), token: oldToken), peer: oldPeer, activeUserID: 501, now: 10)
            await hardware.setTime(11); await oldController.tickFanPolicy(now: 11, activeUserID: 501)
            let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
            _ = try await guardian.recover(now: 26, activeUserID: 501)
            let freshJournal = try SecureJournal(directory: directory, expectedOwner: getuid())
            let newController = recreateController ? PrivilegedController(hardware: hardware, journal: freshJournal, bootID: "boot") : oldController
            let newPeer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
            let session = try await newController.openSession(peer: newPeer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
            let newToken = try XCTUnwrap(session.sessionToken)
            await hardware.setTime(27)
            _ = try await newController.perform(payload(.setFanRPM(["0": 3000, "1": 3000]), token: newToken), peer: newPeer, activeUserID: 501, now: 27)
            await hardware.setTime(28)
            _ = try await newController.perform(payload(.restoreAll, token: newToken, generation: 2), peer: newPeer, activeUserID: 501, now: 28)
            let writesBeforeTick = await hardware.recordedWriteCount()
            await hardware.setTime(29); await oldController.tickFanPolicy(now: 29, activeUserID: 501)
            let writesAfterTick = await hardware.recordedWriteCount()
            XCTAssertEqual(writesBeforeTick, writesAfterTick)
            let state = try await oldController.readState(now: 29)
            XCTAssertTrue(state.ownedResources.isEmpty)
            XCTAssertEqual(state.fanObservation?.autoMode, ["0": true, "1": true])
        }
    }

    func testActualRPMDivergenceReleasesOwnedTargetsInsteadOfClaimingManaged() async throws {
        let (directory, _, hardware, controller, peer, token) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await controller.perform(payload(.setFanPolicy(.manual(["0": 3000, "1": 3000])), token: token), peer: peer, activeUserID: 501, now: 10)
        await hardware.setTime(11, actualRPM: 1500); await controller.tickFanPolicy(now: 11, activeUserID: 501)
        let released = try await controller.readState(now: 11)
        XCTAssertEqual(released.fanPolicyState?.phase, .systemAuto)
        XCTAssertTrue(released.ownedResources.isEmpty); XCTAssertFalse(released.behaviorObserved)
    }
}
