import XCTest
import Foundation
import Darwin
import PowerCore
@testable import PowerPrivileged

private actor FixtureHardware: PrivilegedHardware {
    var settings: [OwnedResource: HardwareSetting] = [.charging: .nativeCharge(featureState: nil, limit: nil)]
    var writes: [HardwareSetting] = []
    var failWrites = false
    var failReadback = false
    let journal: SecureJournal
    init(journal: SecureJournal) { self.journal = journal }
    func capabilities() -> [ControlCapability] { [] }
    func qualify(_ resource: OwnedResource) {}
    func chargeObservation() -> ChargeObservation { .init(percent: 70, externalPower: true) }
    func read(_ resource: OwnedResource) throws -> HardwareSetting {
        guard let setting = settings[resource] else { throw PolicyError.unavailable }; return setting
    }
    func write(_ setting: HardwareSetting, resource: OwnedResource) throws {
        // A first write must see the root journal prepared; acquiring another lock must fail.
        do { _ = try journal.acquireLock(); throw PolicyError.invalidContract } catch PrivilegeError.locked {} catch { throw error }
        writes.append(setting)
        if failWrites { throw PolicyError.readbackMismatch }
        if !failReadback { settings[resource] = setting }
    }
    func setFailure(writes: Bool = false, readback: Bool = false) { failWrites = writes; failReadback = readback }
    func externallySet(_ setting: HardwareSetting) { settings[.charging] = setting }
    func recordedWrites() -> [HardwareSetting] { writes }
}

@MainActor final class RecoveryTests: XCTestCase {
    func testJournaledApplyAndExpiredGuardianRestoreBaselineBeforeDeletingJournal() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid()), hardware = FixtureHardware(journal: journal)
        let controller = PrivilegedController(hardware: hardware, journal: journal, bootID: "boot")
        let peer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
        let session = try await controller.openSession(peer: peer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
        let token = try XCTUnwrap(session.sessionToken)
        let payload = try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 1, command: .applyCharge(target: 80)))
        let result = try await controller.perform(payload, peer: peer, activeUserID: 501, now: 10)
        XCTAssertTrue(result.configurationVerified); XCTAssertFalse(result.behaviorObserved)
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        let notExpired = try await guardian.recover(now: 20, activeUserID: 501)
        XCTAssertFalse(notExpired)
        let restored = try await guardian.recover(now: 26, activeUserID: 501)
        XCTAssertTrue(restored)
        let writes = await hardware.recordedWrites()
        XCTAssertEqual(writes, [.nativeCharge(featureState: 1, limit: 80), .nativeCharge(featureState: nil, limit: nil)])
        do {
            let lock = try journal.acquireLock(), tombstone = try XCTUnwrap(journal.read(lock: lock))
            XCTAssertTrue(tombstone.entries.isEmpty); XCTAssertTrue(tombstone.ownerRevoked)
        }
        let staleOwner = try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 100, command: .applyCharge(target: 90)))
        do { _ = try await controller.perform(staleOwner, peer: peer, activeUserID: 501, now: 30); XCTFail("Guardian takeover must revoke even a higher old-owner generation") } catch PrivilegeError.recoveryRequired {}
    }

    func testGuardianRevocationSurvivesNewOwnerReleaseAndControllerRecreation() async throws {
        for recreateController in [false, true] {
            let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-authority-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
            let hardware = FixtureHardware(journal: journal)
            let oldController = PrivilegedController(hardware: hardware, journal: journal, bootID: "boot")
            let oldPeer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
            let oldSession = try await oldController.openSession(peer: oldPeer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
            let oldToken = try XCTUnwrap(oldSession.sessionToken)
            func payload(_ command: HelperCommand, token: UUID, generation: UInt64) throws -> Data {
                try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: generation, command: command))
            }
            _ = try await oldController.perform(payload(.applyCharge(target: 80), token: oldToken, generation: 1), peer: oldPeer, activeUserID: 501, now: 10)
            let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
            _ = try await guardian.recover(now: 26, activeUserID: 501)
            let freshJournal = try SecureJournal(directory: directory, expectedOwner: getuid())
            let newController = recreateController ? PrivilegedController(hardware: hardware, journal: freshJournal, bootID: "boot") : oldController
            let newPeer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
            let newSession = try await newController.openSession(peer: newPeer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
            let newToken = try XCTUnwrap(newSession.sessionToken)
            _ = try await newController.perform(payload(.applyCharge(target: 90), token: newToken, generation: 1), peer: newPeer, activeUserID: 501, now: 27)
            _ = try await newController.perform(payload(.restoreAll, token: newToken, generation: 2), peer: newPeer, activeUserID: 501, now: 28)
            let writesBeforeStale = await hardware.recordedWrites()
            do {
                _ = try await oldController.perform(payload(.applyCharge(target: 95), token: oldToken, generation: 100), peer: oldPeer, activeUserID: 501, now: 29)
                XCTFail("A revoked authenticated session must remain excluded after the next owner releases, including across controller recreation.")
            } catch PrivilegeError.recoveryRequired {}
            let writesAfterStale = await hardware.recordedWrites()
            XCTAssertEqual(writesAfterStale, writesBeforeStale)
            let observed = try await hardware.read(.charging)
            XCTAssertEqual(observed, .nativeCharge(featureState: nil, limit: nil))
        }
    }

    func testPartialReadbackRetainsOriginalAndGuardianBoundedRetriesNeverEraseFailure() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid()), hardware = FixtureHardware(journal: journal)
        let controller = PrivilegedController(hardware: hardware, journal: journal, bootID: "boot")
        let peer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
        let session = try await controller.openSession(peer: peer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
        let token = try XCTUnwrap(session.sessionToken)
        let payload = try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 1, command: .applyCharge(target: 80)))
        _ = try await controller.perform(payload, peer: peer, activeUserID: 501, now: 10)
        await hardware.setFailure(writes: true)
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        for _ in 0..<4 { do { _ = try await guardian.recover(now: 30, activeUserID: 501); XCTFail("Recovery must report failure") } catch PrivilegeError.recoveryRequired {} }
        let writes = await hardware.recordedWrites(); XCTAssertEqual(writes.count, 4)
        let lock = try journal.acquireLock(), retained = try XCTUnwrap(journal.read(lock: lock))
        XCTAssertEqual(retained.entries[.charging]?.original, .nativeCharge(featureState: nil, limit: nil))
        XCTAssertEqual(retained.entries[.charging]?.recoveryAttempts, 3)
        let heartbeat = try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 1, command: .heartbeat))
        do { _ = try await controller.perform(heartbeat, peer: peer, activeUserID: 501, now: 31); XCTFail("Stale owner must not regain authority") } catch {}
    }

    func testExternalChangeYieldsWithoutOverwritingForeignSetting() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-external-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid()), hardware = FixtureHardware(journal: journal)
        let controller = PrivilegedController(hardware: hardware, journal: journal, bootID: "boot")
        let peer = PeerSession(userID: 501, auditSessionID: 1, connectionID: UUID())
        let session = try await controller.openSession(peer: peer, version: HelperEnvelope.protocolVersion, activeUserID: 501)
        let token = try XCTUnwrap(session.sessionToken)
        _ = try await controller.perform(JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 1, command: .applyCharge(target: 80))), peer: peer, activeUserID: 501, now: 10)
        await hardware.externallySet(.nativeCharge(featureState: 1, limit: 90))
        let guardian = RecoveryGuardian(hardware: hardware, journal: journal, bootID: "boot")
        do { _ = try await guardian.recover(now: 26, activeUserID: 501); XCTFail("Foreign state must remain unresolved") } catch PrivilegeError.recoveryRequired {}
        let writes = await hardware.recordedWrites(); XCTAssertEqual(writes.count, 1)
    }
}
