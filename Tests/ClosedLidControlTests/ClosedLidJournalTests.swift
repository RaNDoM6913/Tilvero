// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import Darwin
@testable import ClosedLidControl

final class ClosedLidJournalTests: XCTestCase {
    func testSymlinkHardlinkModeAndOversizeAreRejected() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory().replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored)).appendingPathComponent("tilvero-lid-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ClosedLidJournal(directory: directory)
        let recordPath = directory.appendingPathComponent("ownership.json")
        let target = directory.appendingPathComponent("other")
        try Data("{}".utf8).write(to: target); chmod(target.path, 0o600)
        XCTAssertEqual(symlink(target.path, recordPath.path), 0)
        XCTAssertThrowsError(try journal.load()); unlink(recordPath.path)
        XCTAssertEqual(link(target.path, recordPath.path), 0)
        XCTAssertThrowsError(try journal.load()); unlink(recordPath.path)
        try Data("{}".utf8).write(to: recordPath); chmod(recordPath.path, 0o644)
        XCTAssertThrowsError(try journal.load()); chmod(recordPath.path, 0o600)
        try Data(repeating: 65, count: 100_000).write(to: recordPath)
        XCTAssertThrowsError(try journal.load())
    }
    func testCorruptionCannotResetAuthorityAndOperationLockExcludesAnotherWriter() throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let lock = try f.journal.acquireOperation()
        XCTAssertThrowsError(try f.journal.acquireOperation())
        withExtendedLifetime(lock) {}
        let path = f.directory.appendingPathComponent("authority.json")
        try Data("invalid".utf8).write(to: path); chmod(path.path, 0o600)
        XCTAssertThrowsError(try f.journal.transaction { _, _ in () })
    }
    func testPostApplyJournalFailureRetainsPreparedRecordForGuardianRecovery() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let path = f.directory.appendingPathComponent("ownership.json")
        await f.backend.interceptAfter { disabled in if disabled { chmod(path.path, 0o644) } }
        do { _ = try await f.start(); XCTFail("Post-call journal failure must remain visible") } catch {}
        await assertCalls(f.backend, [true]); chmod(path.path, 0o600)
        XCTAssertEqual(try f.journal.load()?.state.phase, .prepared)
        let recovered = try await f.guardian.tick(startup: true)
        XCTAssertEqual(recovered.phase, .restoreAcceptedAwaitingWitness); await assertCalls(f.backend, [true, false])
    }
    func testPostClearJournalFailureNeverReissuesAcceptedClear() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        let path = f.directory.appendingPathComponent("ownership.json")
        await f.backend.interceptAfter { disabled in if !disabled { chmod(path.path, 0o644) } }
        f.clock.advance(16)
        do { _ = try await f.guardian.tick(); XCTFail("Post-clear journal failure must remain visible") } catch {}
        await assertCalls(f.backend, [true, false]); chmod(path.path, 0o600)
        let intent = try f.journal.load()
        XCTAssertEqual(intent?.state.phase, .restoreAcceptedAwaitingWitness)
        XCTAssertFalse(intent!.state.restoreCommandAccepted)
        for _ in 0..<3 { _ = try await f.guardian.tick(startup: true) }
        await assertCalls(f.backend, [true, false])
    }
    func testMissingAuthorityAndMechanismMismatchDoNotResetExistingOwnership() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.start()
        let authority = f.directory.appendingPathComponent("authority.json")
        let data = try Data(contentsOf: authority); try FileManager.default.removeItem(at: authority)
        XCTAssertThrowsError(try f.journal.load())
        try data.write(to: authority); chmod(authority.path, 0o600)
        XCTAssertThrowsError(try f.journal.transaction { record, _ in record!.mechanism = "global-sleep-disabled" })
        await assertCalls(f.backend, [true])
    }
    func testJournalFailureBeforePreparationCannotWriteKernel() async throws {
        let f = try LidFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.guardian.tick(); let opened = try await f.open()
        let ownership = f.directory.appendingPathComponent("ownership.json")
        chmod(ownership.path, 0o644)
        do { _ = try await f.send(.start(seconds: 60), using: opened) } catch {}
        let calls = await f.backend.calls
        XCTAssertEqual(calls, [])
    }
}
