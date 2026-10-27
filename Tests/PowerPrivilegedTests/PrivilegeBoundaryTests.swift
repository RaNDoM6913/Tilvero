import XCTest
import Foundation
import Darwin
import PowerCore
@testable import PowerPrivileged

final class PrivilegeBoundaryTests: XCTestCase {
    func testProtocolRejectsOversizeWrongVersionStaleGenerationWrongSessionAndBadTargets() throws {
        let token = UUID(), peer = PeerSession(userID: 501, auditSessionID: 12, connectionID: UUID())
        var validator = RequestValidator(sessionToken: token, peer: peer)
        let valid = HelperEnvelope(sessionToken: token, generation: 1, command: .applyCharge(target: 80))
        try validator.validate(try JSONEncoder().encode(valid), peer: peer, activeUserID: 501)
        XCTAssertThrowsError(try validator.validate(try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 0, command: .applyCharge(target: 80))), peer: peer, activeUserID: 501))
        XCTAssertThrowsError(try validator.validate(try JSONEncoder().encode(HelperEnvelope(version: HelperEnvelope.protocolVersion + 1, sessionToken: token, generation: 2, command: .readState)), peer: peer, activeUserID: 501))
        XCTAssertThrowsError(try validator.validate(try JSONEncoder().encode(HelperEnvelope(sessionToken: UUID(), generation: 2, command: .applyCharge(target: 80))), peer: peer, activeUserID: 501))
        XCTAssertThrowsError(try validator.validate(try JSONEncoder().encode(HelperEnvelope(sessionToken: token, generation: 2, command: .applyCharge(target: 40))), peer: peer, activeUserID: 501))
        XCTAssertThrowsError(try validator.validate(Data(repeating: 0, count: 40_000), peer: peer, activeUserID: 501))
        XCTAssertThrowsError(try validator.validate(try JSONEncoder().encode(valid), peer: peer, activeUserID: 502))
    }

    func testSecureJournalPreservesAbsentSettingsAndRejectsSymlinkAndUnsecureMode() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
        let lease = try journal.acquireLock()
        var record = OwnershipJournal(bootID: "test-boot", generation: 1, ownerToken: UUID(), ownerUserID: getuid(), heartbeat: 10, leaseDeadline: 20)
        record.entries[.charging] = JournalEntry(original: .nativeCharge(featureState: nil, limit: nil), intended: .nativeCharge(featureState: 1, limit: 80))
        try journal.write(record, lock: lease)
        XCTAssertEqual(try journal.read(lock: lease)?.entries[.charging]?.original, .nativeCharge(featureState: nil, limit: nil))
        let file = directory.appendingPathComponent("ownership.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try journal.read(lock: lease))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try journal.read(lock: lease))
    }

    func testLockExcludesAnotherControllerAndCorruptionIsNotAnEmptyJournal() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
        let lock = try journal.acquireLock()
        XCTAssertThrowsError(try journal.acquireLock())
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("ownership.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("ownership.json").path)
        XCTAssertThrowsError(try journal.read(lock: lock))
    }

    func testDurableAuthorityEpochIsBoundedAndRejectsUnsafeOrCorruptStorage() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("tilvero-authority-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SecureJournal(directory: directory, expectedOwner: getuid())
        let lock = try journal.acquireLock()
        let firstEpoch = try journal.authorityEpoch(lock: lock)
        let revokedEpoch = try journal.revokeAuthority(lock: lock)
        XCTAssertNotEqual(firstEpoch, revokedEpoch)
        let empty = OwnershipJournal(bootID: "fixture", generation: 1, ownerToken: UUID(), ownerUserID: getuid(), heartbeat: 10, leaseDeadline: 25)
        try journal.write(empty, lock: lock); try journal.removeVerifiedEmpty(lock: lock)
        let reopened = try SecureJournal(directory: directory, expectedOwner: getuid())
        XCTAssertEqual(try reopened.authorityEpoch(lock: lock), revokedEpoch)
        let file = directory.appendingPathComponent("authority.json")
        XCTAssertLessThan(try Data(contentsOf: file).count, 256)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try reopened.authorityEpoch(lock: lock))
        XCTAssertThrowsError(try reopened.revokeAuthority(lock: lock))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try reopened.authorityEpoch(lock: lock))
        XCTAssertThrowsError(try reopened.revokeAuthority(lock: lock))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try reopened.authorityEpoch(lock: lock))
        XCTAssertThrowsError(try reopened.revokeAuthority(lock: lock))
    }

    func testTrustConfigurationRejectsMissingBroadAndInjectedIdentity() throws {
        XCTAssertThrowsError(try HelperTrustConfiguration(teamID: "", appIdentifier: "local.tilvero", helperIdentifier: "local.tilvero.helper"))
        XCTAssertThrowsError(try HelperTrustConfiguration(teamID: "AAAAAAAAAA", appIdentifier: "x\" or true", helperIdentifier: "helper"))
        let trust = try HelperTrustConfiguration(teamID: "ABCDEFGHIJ", appIdentifier: "com.example.Tilvero", helperIdentifier: "com.example.Tilvero.Helper")
        XCTAssertTrue(trust.appRequirement.contains("anchor apple generic"))
        XCTAssertTrue(trust.appRequirement.contains("certificate leaf[subject.OU] = \"ABCDEFGHIJ\""))
        XCTAssertNotEqual(trust.appRequirement, trust.helperRequirement)
    }
}
