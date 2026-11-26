// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp
import ChargeBackends
import PowerCore

/// Every transport here is an isolated actor fixture; these tests never call PowerUI.
@MainActor final class NativeChargeForwardStateTests: XCTestCase {
    func testLeavingThePageDropsItsActionNotice() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        let suite = TestDefaults.name("NoticeDismiss"), preferences = TestDefaults.defaults(suite)
        preferences.set(false, forKey: "historyEnabled")
        defer { TestDefaults.remove(suite) }
        let model = TilveroModel(isDemo: false, preferences: preferences,
            historyURL: f.url.deletingLastPathComponent().appendingPathComponent("History.sqlite"),
            snapshotProvider: { BatterySnapshot(chargePercent: .init(value: 86, source: "fixture", freshness: .fresh),
                                                isExternalPower: .init(value: false, source: "fixture")) },
            nativeCharge: f.service)
        defer { model.stop() }
        await model.refreshNativeCharge()
        model.setDraft(90)
        await f.client.configure(read: .fail, after: 0)   // the apply's own read fails: a failure notice
        model.applyDraftTarget()
        for _ in 0..<200 where model.isApplying { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.notice)
        model.dismissActionNotice()
        XCTAssertNil(model.notice, "An action notice must not follow the user onto another tab")
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }

    func testStandaloneReadTimeoutDoesNotInventUnknownWrite() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90)
        await f.client.configure(read: .suspend, after: 0)
        await f.service.refresh()
        XCTAssertFalse(f.journalExists, "a read past its deadline records no write")
        XCTAssertNil(f.service.observed)
        XCTAssertFalse(f.service.canApply)
        do { try await f.service.apply(95); XCTFail("A pending read must block the next write") } catch {}
        await f.client.release()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(f.service.observed, "A late read cannot publish current policy")
        await f.service.refresh()
        XCTAssertTrue(f.service.canApply)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    /// A read failure before the dispatch (the apply's own read, or the re-read just before the write) writes nothing and
    /// leaves no journal behind: nothing to review.
    func testAPreDispatchReadFailureNeverWritesOrLeavesAJournal() async throws {
        for behavior in [ForwardClient.ReadBehavior.fail, .stale, .suspend] {
            for readsBefore in [0, 1] {
                let label = "\(behavior) after \(readsBefore)"
                let f = ForwardFixture(); defer { f.cleanup() }
                await f.service.refresh()
                try await f.service.apply(90)
                await f.client.configure(read: behavior, after: readsBefore)
                do { try await f.service.apply(95); XCTFail("\(label): the read must prevent the dispatch") } catch {}
                XCTAssertFalse(f.journalExists, label)
                XCTAssertFalse(f.service.hasUnresolvedSession, label)
                XCTAssertNotEqual(f.service.presentation().attention, .journalIntegrity, label)
                let writes = await f.client.writes; XCTAssertEqual(writes, [90], label)
                await f.client.release()
            }
        }
    }

    /// The first read after the setter fails (an error, a hung read, a stale read): the outcome is unknown and the journal
    /// keeps the expected value for the next launch; nothing is re-applied.
    func testFirstPostSetterReadFailureRetainsExpectedMutation() async throws {
        for behavior in [ForwardClient.ReadBehavior.fail, .suspend, .stale] {
            let f = ForwardFixture(); defer { f.cleanup() }
            await f.service.refresh()
            await f.client.configure(read: behavior, after: 2)
            do { try await f.service.apply(90); XCTFail("Configuration acknowledgement required") } catch {}
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.url))
            XCTAssertEqual(saved.phase, .indeterminate)
            XCTAssertEqual(saved.expectedMutation?.target, 90)
            XCTAssertEqual(f.service.presentation().attention, .mutationUnresolved)
            let reopened = f.reopen()
            XCTAssertTrue(reopened.presentation().hasRecordedMutation)
            XCTAssertEqual(reopened.presentation().attention, .mutationUnresolved)
            XCTAssertFalse(reopened.presentation().showsAttentionBanner, "a status line that closes itself, not a banner")
            await f.client.release()
            for _ in 0..<100 { await Task.yield() }
            await f.service.refresh()
            XCTAssertTrue(f.journalExists, "a young session waits for a settled read")
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        }
    }

    /// A write-ahead save failure dispatches nothing and leaves nothing to review; a journal that cannot be removed after a
    /// confirmed write is the one state Diagnostics flags, and it still blocks nothing.
    func testWriteAheadAndConfirmedJournalPersistenceFailuresNeverInventInFlightSetter() async throws {
        for readsBeforeBlock in [0, 2] {
            let f = ForwardFixture(); defer { f.cleanup() }
            try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
            await f.service.refresh()
            await f.client.lockFolder(f.folder, after: readsBeforeBlock)
            do { try await f.service.apply(90); XCTFail("Persistence must fail") } catch {}
            XCTAssertNil(f.service.presentation().pendingPurpose)
            let writes = await f.client.writes
            XCTAssertEqual(writes, readsBeforeBlock == 0 ? [] : [90])
            f.unlockFolder()
            if readsBeforeBlock == 0 {
                XCTAssertNotEqual(f.service.presentation().attention, .journalIntegrity)
                XCTAssertFalse(f.journalExists, "nothing is left on disk")
                await f.service.refresh()
                XCTAssertEqual(f.service.presentation().attention, .none)
                try await f.service.apply(90)
                let later = await f.client.writes
                XCTAssertEqual(later, [90], "a later apply works")
            } else {
                XCTAssertEqual(f.service.presentation().attention, .journalIntegrity)
                XCTAssertTrue(f.service.presentation().requiresGlobalAttention)
                XCTAssertTrue(f.service.canApplyTarget(95), "it blocks nothing")
                try await f.service.apply(95)   // supersedes the leftover without a write of its own
                XCTAssertEqual(f.service.presentation().attention, .none)
                XCTAssertFalse(f.journalExists)
                let later = await f.client.writes
                XCTAssertEqual(later, [90, 95])
            }
        }
    }

    func testPresentationFreshnessBoundaries() async throws {
        let f = ForwardFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90)
        let snapshot = try XCTUnwrap(f.service.nativeSetting)
        XCTAssertTrue(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(-5)))
        XCTAssertTrue(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(65)))
        XCTAssertFalse(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(-5.01)))
        XCTAssertFalse(snapshot.isFresh(at: snapshot.collectedAt.addingTimeInterval(65.01)))
        XCTAssertEqual(f.service.presentation(at: snapshot.collectedAt).attention, .none)
        XCTAssertFalse(f.service.presentation(at: snapshot.collectedAt).requiresGlobalAttention)
        XCTAssertNil(f.service.presentation(at: snapshot.collectedAt.addingTimeInterval(66)).activePolicy)
        XCTAssertNil(f.service.presentation(at: snapshot.collectedAt.addingTimeInterval(66)).currentPreference)
        XCTAssertEqual(f.service.presentation(at: snapshot.collectedAt.addingTimeInterval(66)).attention, .policyUnconfirmed)
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
}

@MainActor private struct ForwardFixture {
    let client = ForwardClient()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeForward-\(UUID().uuidString)/session.json")
    let service: NativeChargeService
    var folder: URL { url.deletingLastPathComponent() }
    init() {
        service = NativeChargeService(client: client, journalURL: url, verificationAttempts: 1,
                                      environment: "fixture", operationTimeout: .milliseconds(30))
    }
    func reopen() -> NativeChargeService {
        NativeChargeService(client: client, journalURL: url, verificationAttempts: 1, environment: "fixture", operationTimeout: .milliseconds(30))
    }
    var journalExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    func unlockFolder() { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    func cleanup() { unlockFolder(); try? FileManager.default.removeItem(at: folder) }
}

private actor ForwardClient: NativeChargeTransport {
    enum ReadBehavior { case fail, stale, suspend }
    var writes: [Int] = []
    private var lock: (URL, Int)?
    var isSuspended: Bool { continuation != nil }
    private var target = 85
    private var planned: (ReadBehavior, Int)?
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(read: ReadBehavior, after: Int) { planned = (read, after) }
    func read() async throws -> NativeChargeSnapshot {
        var stale = false
        if let (behavior, remaining) = planned {
            if remaining > 0 { planned = (behavior, remaining - 1) }
            else {
                planned = nil
                switch behavior {
                case .fail: throw NativeChargeServiceError.readbackMismatch
                case .stale: stale = true
                case .suspend: await withCheckedContinuation { continuation = $0 }
                }
            }
        }
        if let (folder, remaining) = lock {
            if remaining > 0 { lock = (folder, remaining - 1) }
            else {
                // The session folder becomes read-only: no journal can be saved or removed from now on.
                lock = nil
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            }
        }
        let enabled = target != 100
        return .init(configuration: .init(enabled: enabled, target: target, optimizedCharging: true),
            supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: enabled ? target : nil,
            collectedAt: stale ? Date().addingTimeInterval(-120) : Date())
    }
    func setLimit(_ target: Int) async throws { writes.append(target); self.target = target }
    func setEnabled(_ enabled: Bool) async throws { XCTFail("The native path writes only the limit") }
    func lockFolder(_ folder: URL, after reads: Int) { lock = (folder, reads) }
    func release() { continuation?.resume(); continuation = nil }
}
