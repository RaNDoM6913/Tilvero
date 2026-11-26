// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp
import ChargeBackends
import PowerCore

/// The one write path against an isolated fixture transport (never PowerUI): every case asserts the writes.
@MainActor final class NativeChargeServiceTests: XCTestCase {
    func testAnApplyWritesOnceReadsBackAndLeavesNothingBehind() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.admitted, "the live interface grants the limit")
        try await f.service.apply(90)
        XCTAssertEqual(f.service.observed?.configuration.target, 90)
        XCTAssertFalse(f.journalExists, "a confirmed limit is the user's own macOS setting")
        XCTAssertFalse(f.service.hasUnresolvedSession)
        try await f.service.apply(100)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: false, target: 100, optimizedCharging: true), "100 is the limit off")
        try await f.service.apply(85)   // re-enabled through the limit write itself
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        try await f.service.apply(85)   // already active: nothing to write
        let writes = await f.client.writes; XCTAssertEqual(writes, [90, 100, 85])
    }

    func testAnExternalChangeIsObservedAndNeverOverwritten() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90)
        await f.client.external(target: 95)
        await f.service.refresh()
        XCTAssertEqual(f.service.reportedLimit, 95)
        XCTAssertFalse(f.journalExists)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    /// An unresolved journal is never re-applied at launch: it only waits for a settled clear read.
    func testRestartReadsButNeverReappliesJournaledIntent() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh(); await f.client.ignoreNextSet()
        do { try await f.service.apply(90); XCTFail("the readback does not confirm") } catch {}
        XCTAssertTrue(f.journalExists)
        let reopened = f.reopen()
        XCTAssertTrue(reopened.hasUnresolvedSession)
        await reopened.refresh()
        XCTAssertTrue(f.journalExists, "a young session waits")
        XCTAssertTrue(reopened.canApplyTarget(90), "it never blocks the slider")
        try f.settle()
        await reopened.refresh()
        XCTAssertFalse(f.journalExists, "the first settled clear read closes it, without a write")
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testMonitoringAndUnreadRoutesNeverWrite() async throws {
        let monitor = Fixture(monitoring: true); defer { monitor.cleanup() }
        await monitor.service.refresh()
        XCTAssertFalse(monitor.service.admitted)
        do { try await monitor.service.apply(90); XCTFail("monitoring never writes") } catch {}
        let unread = Fixture(); defer { unread.cleanup() }
        do { try await unread.service.apply(90); XCTFail("nothing was read: nothing is granted") }
        catch NativeChargeServiceError.unavailable {} catch { XCTFail("Wrong error: \(error)") }
        let monitorWrites = await monitor.client.writes, unreadWrites = await unread.client.writes
        XCTAssertEqual(monitorWrites + unreadWrites, [])
    }

    func testTargetsOutsideThePersistentLevelsNeverWrite() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        for target in [79, 83, 99] {
            do { try await f.service.apply(target); XCTFail("Must reject \(target)") } catch {}
        }
        XCTAssertFalse(f.journalExists)
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }

    /// Write-ahead: the journal is saved before the dispatch; a save failure writes nothing and leaves nothing behind.
    func testJournalFailurePreventsTheFirstMutation() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.url.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: f.url.deletingLastPathComponent())
        await f.service.refresh()
        do { try await f.service.apply(90); XCTFail("Write-ahead journal is mandatory") } catch {}
        XCTAssertFalse(f.service.hasUnresolvedSession)
        XCTAssertNotEqual(f.service.presentation().attention, .journalIntegrity, "nothing was dispatched, nothing to review")
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }

    /// A write whose readback never confirms is an unknown outcome: an indeterminate journal (status line only) with its
    /// expected value, no follow-up write, and the slider stays usable.
    func testAnUnconfirmedWriteLeavesAnIndeterminateSessionAndNoFollowUpWrite() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh(); await f.client.ignoreNextSet()
        do { try await f.service.apply(90); XCTFail("Must detect the missing readback") }
        catch NativeChargeServiceError.readbackMismatch {} catch { XCTFail("Wrong error: \(error)") }
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
        XCTAssertEqual(saved.phase, .indeterminate)
        XCTAssertEqual(saved.expectedMutation?.target, 90)
        XCTAssertTrue(saved.hasWritten)
        XCTAssertEqual(f.service.presentation().attention, .mutationUnresolved)
        XCTAssertFalse(f.service.presentation().requiresGlobalAttention, "a status line, not a banner")
        await f.service.refresh()
        XCTAssertTrue(f.service.canApplyTarget(95))
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    /// A change made in System Settings between the read and the write is the user's: nothing is written.
    func testAnExternalEditBetweenTheReadsIsKeptAndNothingIsWritten() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh(); await f.client.changeAfterNextRead(to: 95)
        do { try await f.service.apply(90); XCTFail("Must preserve the external edit") }
        catch NativeChargeServiceError.changedElsewhere {} catch { XCTFail("Wrong error: \(error)") }
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(f.service.observed?.configuration.target, 95)
    }

    func testAStalePreWriteReadNeverDispatches() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        await f.client.forceInvalidRead(target: 85, stale: true)
        do { try await f.service.apply(90); XCTFail("A stale read must block the write") } catch {}
        XCTAssertFalse(f.journalExists)
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }

    /// Only a settled, clear read closes a session: a stale read or a missing registry readback on AC never does.
    func testRefreshNeverClosesASessionFromAnInvalidRead() async throws {
        for stale in [true, false] {
            let f = Fixture(); defer { f.cleanup() }
            await f.service.refresh(); await f.client.ignoreNextSet()
            do { try await f.service.apply(90); XCTFail("unconfirmed") } catch {}
            try f.settle()
            let before = try Data(contentsOf: f.url)
            await f.client.forceInvalidRead(target: 85, stale: stale)
            await f.service.refresh()
            XCTAssertNil(f.service.observed)
            XCTAssertEqual(try Data(contentsOf: f.url), before, "stale \(stale)")
            await f.client.clearInvalidRead()
            await f.service.refresh()
            XCTAssertFalse(f.journalExists, "stale \(stale): a clear read closes it")
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        }
    }

    /// On AC with no registry readback the stored setting is still what macOS stores: shown, writable, and the readback
    /// decides (here it cannot confirm, so the session stays unresolved).
    func testAMissingRegistryReadbackStillShowsTheSettingAndTheReadbackDecides() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.client.forceInvalidRead(target: 80, stale: false)
        await f.service.refresh()
        XCTAssertTrue(f.service.interfaceWasDiscovered, "A valid native setting must not fall back to a helper requirement")
        XCTAssertEqual(f.service.acceptedTargets, [80, 85, 90, 95, 100])
        XCTAssertEqual(f.service.nativeSetting?.configuration.target, 80)
        XCTAssertNil(f.service.observed, "Independent registration is still required for a confirmed policy")
        XCTAssertNil(f.service.presentation().activePolicy)
        XCTAssertTrue(f.service.canApply)
        do { try await f.service.apply(90); XCTFail("not confirmed without the registry") } catch {}
        XCTAssertEqual(f.service.presentation().attention, .mutationUnresolved)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testMonitoringPreviewPreservesAForeignJournalAndNeverWrites() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        await f.client.ignoreNextSet()
        do { try await f.service.apply(90); XCTFail("unconfirmed") } catch {}
        let before = try Data(contentsOf: f.url)
        try f.settle()
        let preview = NativeChargeService(client: f.client, journalURL: f.url, monitoringOnly: true)
        await preview.refresh()
        XCTAssertFalse(preview.hasUnresolvedSession, "a monitoring preview never loads the session")
        XCTAssertFalse(preview.admitted)
        do { try await preview.apply(85); XCTFail("monitoring never writes") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.url), before)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    @MainActor private struct Fixture {
        let client = NativeChargeFixtureClient()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroNative-\(UUID().uuidString)/session.json")
        let service: NativeChargeService
        init(monitoring: Bool = false) {
            service = NativeChargeService(client: client, journalURL: url, monitoringOnly: monitoring, verificationAttempts: 2)
        }
        func reopen() -> NativeChargeService { NativeChargeService(client: client, journalURL: url, verificationAttempts: 2) }
        var journalExists: Bool { FileManager.default.fileExists(atPath: url.path) }
        func settle() throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: url.path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// The macOS shape of the limit: an enabled target, or 100 stored as "limit off" (disabled, no registered row).
actor NativeChargeFixtureClient: NativeChargeTransport {
    var writes: [Int] = []
    private var target = 85
    private var ignoreSet = false
    private var afterReadTarget: Int?
    private var staleReads = false
    private var unavailablePolicy = false
    func read() async throws -> NativeChargeSnapshot {
        let enabled = target != 100
        let value = NativeChargeSnapshot(configuration: .init(enabled: enabled, target: target, optimizedCharging: true),
              supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: enabled ? target : nil,
              policyReadbackAvailable: !unavailablePolicy, collectedAt: staleReads ? Date().addingTimeInterval(-120) : Date())
        if let afterReadTarget { target = afterReadTarget; self.afterReadTarget = nil }
        return value
    }
    func setLimit(_ target: Int) async throws { writes.append(target); if ignoreSet { ignoreSet = false; return }; self.target = target }
    func setEnabled(_ enabled: Bool) async throws { XCTFail("The native path writes only the limit") }
    func forceInvalidRead(target: Int, stale: Bool) { self.target = target; staleReads = stale; unavailablePolicy = !stale }
    func clearInvalidRead() { staleReads = false; unavailablePolicy = false }
    func ignoreNextSet() { ignoreSet = true }
    func changeAfterNextRead(to target: Int) { afterReadTarget = target }
    func external(target: Int) { self.target = target }
}
