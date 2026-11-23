// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import PowerPersistence
@testable import TilveroApp

/// The model never waits for the history store: refreshes, power changes and the menu bar go on while the store is busy.
@MainActor final class HistoryModelTests: XCTestCase {
    private func reading(_ percent: Int, external: Bool, at date: Date = Date()) -> BatterySnapshot {
        BatterySnapshot(chargePercent: .init(value: percent, source: "fixture", collectedAt: date, freshness: .fresh),
                        isExternalPower: .init(value: external, source: "fixture", collectedAt: date), collectedAt: date,
                        batteryIdentityToken: "history-model-fixture")
    }

    private func fixture() throws -> (model: TilveroModel, box: SnapshotBox, store: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryModel-\(UUID())")
        let suite = TestDefaults.name("HistoryModel"), defaults = TestDefaults.defaults(suite)
        let url = root.appendingPathComponent("History.sqlite")
        let box = SnapshotBox(reading(73, external: false))
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { box.value })
        return (model, box, url, { model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) })
    }

    /// Releases a held queue after `seconds` if the test itself never gets there (a regression would otherwise hang).
    private func watchdog(_ release: @escaping @MainActor () -> Void, seconds: Double = 5) -> Task<Bool, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return false }
            release(); return true
        }
    }

    func testRefreshAndPowerChangesDoNotWaitForABusyStore() async throws {
        let f = try fixture(); defer { f.cleanup() }
        await f.model.waitForHistoryWork()
        let release = f.model.holdHistoryWorkForTesting()
        let guardTask = watchdog(release)
        await f.model.refresh()
        XCTAssertEqual(f.model.snapshot.chargePercent.value, 73, "The reading is shown while the store is busy.")
        XCTAssertTrue(f.model.history.isEmpty)
        f.box.value = reading(74, external: true)
        await f.model.refresh()
        XCTAssertEqual(f.model.snapshot.chargePercent.value, 74, "A power-change refresh is not dropped.")
        guardTask.cancel()
        let fired = await guardTask.value
        XCTAssertFalse(fired, "Refresh waited for the held history queue.")
        release()
        await f.model.waitForHistoryWork()
        XCTAssertEqual(f.model.history.map(\.chargePercent), [73, 74], "Both readings are recorded once the store is free.")
    }

    func testAnEraseWinsOverARecordQueuedBeforeIt() async throws {
        let f = try fixture(); defer { f.cleanup() }
        await f.model.waitForHistoryWork()
        let release = f.model.holdHistoryWorkForTesting()
        let guardTask = watchdog(release)
        await f.model.refresh()          // queues a record behind the held store
        f.model.eraseHistory()
        release(); guardTask.cancel()
        await f.model.waitForHistoryWork()
        XCTAssertTrue(f.model.history.isEmpty, "A reading taken before the erase is not written after it.")
        XCTAssertNil(f.model.weeklyCapacity)
        let store = try BatteryHistoryStore(url: f.store)
        let stored = try await store.samples().count
        XCTAssertEqual(stored, 0)
        try await store.close()
    }

    func testASleepBoundaryKeepsTheTimeItHappenedNotWhenTheQueueGotToIt() async throws {
        let f = try fixture(); defer { f.cleanup() }
        await f.model.refresh()
        await f.model.waitForHistoryWork()
        let release = f.model.holdHistoryWorkForTesting()
        let guardTask = watchdog(release)
        let before = Date()
        f.model.setSleeping(true)
        let after = Date()
        try await Task.sleep(for: .milliseconds(400))
        release(); guardTask.cancel()
        f.box.value = reading(72, external: true)
        f.model.setSleeping(false)
        let deadline = Date().addingTimeInterval(5)
        while f.model.history.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            await f.model.waitForHistoryWork()
        }
        let summary = try XCTUnwrap(f.model.historySummary)
        let sleep = try XCTUnwrap(summary.gaps.last { $0.reason == .sleep })
        XCTAssertGreaterThanOrEqual(sleep.start, before)
        XCTAssertLessThanOrEqual(sleep.start, after, "The boundary starts when the Mac went to sleep, not 400 ms later.")
    }

    func testStopWritesQueuedSleepReportsBeforeClosing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        await f.model.refresh()
        await f.model.waitForHistoryWork()
        let release = f.model.holdHistoryWorkForTesting()
        f.model.setSleeping(true)        // a sleep report waits behind the held queue
        f.model.stop()                   // termination: it must still reach the disk
        release()
        let store = try BatteryHistoryStore(url: f.store)
        let reports = try await store.sleepSessions()
        XCTAssertFalse(reports.isEmpty, "The queued report was written by the termination close.")
        XCTAssertTrue(reports.allSatisfy { !$0.isPending }, "Stopping closes the pending observation.")
        try await store.close()
    }
}
