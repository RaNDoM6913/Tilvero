import XCTest
@testable import TilveroApp
import ChargeBackends

@MainActor final class NativeChargeServiceTests: XCTestCase {
    func testApplyAndRestorePreserveOriginalUserLimitAndOBC() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        XCTAssertEqual(f.service.observed?.configuration.target, 90)
        XCTAssertTrue(f.service.hasOwnedSettings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url.path))
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        let writes = await f.client.writes
        XCTAssertEqual(writes, [90, 85])
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url.path))
        XCTAssertEqual(f.service.observed?.configuration.optimizedCharging, true)
    }
    func testLowerTargetWaitsAndNeverWritesFromStaleData() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(80, batteryPercent: 85, batteryFresh: true)
        XCTAssertEqual(f.service.pendingTarget, 80)
        var writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        await f.service.observeBattery(percent: 78, fresh: false)
        writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        await f.service.observeBattery(percent: 78, fresh: true)
        writes = await f.client.writes; XCTAssertEqual(writes, [80])
    }
    func testRestoreBelowCurrentChargeRemainsPendingAndJournaled() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(95, batteryPercent: 60, batteryFresh: true)
        let restored = try await f.service.restore(batteryPercent: 90, batteryFresh: true)
        XCTAssertFalse(restored)
        XCTAssertTrue(f.service.restorationPending)
        let writes = await f.client.writes; XCTAssertEqual(writes, [95])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url.path))
    }
    func testExternalChangeRelinquishesWithoutOverwritingUser() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        await f.client.external(target: 95)
        await f.service.refresh()
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertNil(f.service.pendingTarget)
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        XCTAssertEqual(f.service.observed?.configuration.target, 95)
    }
    func testRestartReadsButNeverReappliesJournaledIntent() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        let reopened = NativeChargeService(client: f.client, journalURL: f.url, admitted: true, verificationAttempts: 2)
        await reopened.refresh()
        XCTAssertTrue(reopened.recoveryRequired)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        let restored = try await reopened.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
    }
    func testMonitoringAndUnadmittedRoutesNeverWrite() async throws {
        for (admitted, monitoring) in [(false, false), (true, true)] {
            let f = Fixture(admitted: admitted, monitoring: monitoring); defer { f.cleanup() }
            await f.service.refresh()
            do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Must remain gated") } catch {}
            let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func testInvalidOrMissingBatteryNeverWrites() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        for (target, percent, fresh) in [(79, Optional(60), true), (83, Optional(60), true), (90, nil, true), (90, Optional(60), false)] {
            do { try await f.service.apply(target, batteryPercent: percent, batteryFresh: fresh); XCTFail("Must reject") } catch {}
        }
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }

    func testJournalFailurePreventsTheFirstMutation() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try Data("occupied".utf8).write(to: f.url.deletingLastPathComponent())
        await f.service.refresh()
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Write-ahead journal is mandatory") } catch {}
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
    }
    func testUnconfirmedOperationCannotClearJournalJustBecauseOldPolicyIsVisible() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh(); await f.client.ignoreNextSet()
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Must detect missing readback") } catch {}
        XCTAssertTrue(f.service.recoveryRequired)
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertFalse(restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url.path))
    }
    func testEnablePartialFailureRemainsRecoverable() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.client.disableAndFailAfterEnable()
        await f.service.refresh()
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Must report failed enable") } catch {}
        XCTAssertTrue(f.service.recoveryRequired)
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        XCTAssertEqual(f.service.observed?.configuration.enabled, false)
        XCTAssertEqual(f.service.observed?.configuration.target, 85)
    }
    func testExternalEditBetweenStagesIsPreserved() async throws {
        let f = Fixture(); defer { f.cleanup() }
        await f.service.refresh(); await f.client.changeAfterNextRead(to: 95)
        do { try await f.service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Must preserve external edit") } catch {}
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertEqual(f.service.observed?.configuration.target, 95)
    }

    func testCancelCannotEraseAnIndeterminatePendingMutation() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        try await f.service.apply(80, batteryPercent: 85, batteryFresh: true)
        await f.client.ignoreNextSet()
        await f.service.observeBattery(percent: 78, fresh: true)
        XCTAssertTrue(f.service.recoveryRequired)
        XCTAssertThrowsError(try f.service.cancelPending())
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertFalse(restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.url.path))
    }
    func testUnavailableOrStalePreMutationReadPreservesOwnedJournal() async throws {
        for stale in [true, false] {
            let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
            try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
            await f.client.failReadsAfterNext(stale: stale)
            do { try await f.service.apply(95, batteryPercent: 60, batteryFresh: true); XCTFail("Incomplete read must block the next write") } catch {}
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.url.path))
            XCTAssertTrue(f.service.hasOwnedSettings)
        }
    }
    func testExternalEditDuringRestoreDoesNotLeaveFalseRecovery() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        await f.client.changeAfterNextRead(to: 95)
        do { _ = try await f.service.restore(batteryPercent: 60, batteryFresh: true); XCTFail("The external edit must be reported") } catch {}
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertFalse(f.service.recoveryRequired)
        let restored = try await f.service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }
    func testGeneralAdmissionDoesNotEnableUnqualifiedFullOnce() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        do { try await f.service.chargeToFullOnce(batteryPercent: 60, batteryFresh: true); XCTFail("Separate full-once evidence is required") } catch {}
        let writes = await f.client.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(f.service.canChargeToFullOnce)
    }

    func testMonitoringPreviewPreservesForeignNativeJournalAndCanQuit() async throws {
        let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
        try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
        let before = try Data(contentsOf: f.url)
        let preview = NativeChargeService(client: f.client, journalURL: f.url, admitted: true, monitoringOnly: true)
        await preview.refresh()
        XCTAssertFalse(preview.hasOwnedSettings)
        XCTAssertFalse(preview.recoveryRequired)
        XCTAssertFalse(preview.admitted)
        let restored = try await preview.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        XCTAssertEqual(try Data(contentsOf: f.url), before)
        let writes = await f.client.writes; XCTAssertEqual(writes, [90])
    }

    func testRefreshCannotRelinquishOwnedStateFromInvalidExternalReadback() async throws {
        for stale in [true, false] {
            let f = Fixture(); defer { f.cleanup() }; await f.service.refresh()
            try await f.service.apply(90, batteryPercent: 60, batteryFresh: true)
            let before = try Data(contentsOf: f.url)
            await f.client.forceInvalidRead(target: 85, stale: stale)
            await f.service.refresh()
            XCTAssertTrue(f.service.hasOwnedSettings)
            XCTAssertNil(f.service.observed)
            XCTAssertFalse(f.service.isAvailable)
            XCTAssertEqual(try Data(contentsOf: f.url), before)
            let writes = await f.client.writes; XCTAssertEqual(writes, [90])
        }
    }

    @MainActor private struct Fixture {
        let client = NativeChargeFixtureClient()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroNative-\(UUID().uuidString)/session.json")
        let service: NativeChargeService
        init(admitted: Bool = true, monitoring: Bool = false) {
            service = NativeChargeService(client: client, journalURL: url, admitted: admitted, monitoringOnly: monitoring, verificationAttempts: 2)
        }
        func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

actor NativeChargeFixtureClient: NativeChargeTransport {
    var writes: [Int] = []
    private var target = 85
    private var enabled = true
    private var ignoreSet = false
    private var failEnable = false
    private var afterReadTarget: Int?
    private var failAfterRead: Bool?
    private var staleReads = false
    private var unavailablePolicy = false
    func read() async throws -> NativeChargeSnapshot {
        let value = NativeChargeSnapshot(configuration: .init(enabled: enabled, target: target, optimizedCharging: true),
              supportedTargets: [80,85,90,95,100], registeredManualLimit: enabled ? target : nil,
              policyReadbackAvailable: !unavailablePolicy, collectedAt: staleReads ? Date().addingTimeInterval(-120) : Date())
        if let afterReadTarget { target = afterReadTarget; self.afterReadTarget = nil }
        if let failAfterRead { staleReads = failAfterRead; unavailablePolicy = !failAfterRead; self.failAfterRead = nil }
        return value
    }
    func setLimit(_ target: Int) async throws { writes.append(target); if ignoreSet { ignoreSet = false; return }; self.target = target; enabled = true }
    func setEnabled(_ enabled: Bool) async throws {
        self.enabled = enabled
        if enabled && failEnable { failEnable = false; throw NativeChargeServiceError.readbackMismatch }
    }
    func forceInvalidRead(target: Int, stale: Bool) { self.target = target; staleReads = stale; unavailablePolicy = !stale }
    func failReadsAfterNext(stale: Bool) { failAfterRead = stale }
    func ignoreNextSet() { ignoreSet = true }
    func disableAndFailAfterEnable() { enabled = false; failEnable = true }
    func changeAfterNextRead(to target: Int) { afterReadTarget = target }
    func external(target: Int) { self.target = target }
}
