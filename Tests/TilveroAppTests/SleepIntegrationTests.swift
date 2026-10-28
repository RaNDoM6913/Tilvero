import XCTest
import Foundation
@testable import TilveroApp
import PowerCore
@testable import PowerPersistence
import CoreData

@MainActor final class SleepIntegrationTests: XCTestCase {
    func testPreWakeAsyncReadCannotBecomePostWakeEvidenceAndWakeReadIsQueued() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = SleepSnapshotQueue(values: [80, 70], blockFirst: true)
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url,
                                 snapshotProvider: { await queue.read() })
        defer { model.stop() }
        let oldRead = Task { await model.refresh() }
        for _ in 0..<200 { if await queue.readCount > 0 { break }; await Task.yield() }
        model.setSleeping(true)
        model.setSleeping(false)
        await queue.releaseFirst()
        await oldRead.value
        for _ in 0..<500 {
            if model.sleepSessions.contains(where: { $0.after?.chargePercent == 70 }) { break }
            await Task.yield()
        }
        XCTAssertEqual(model.snapshot.chargePercent.value, 70)
        XCTAssertEqual(model.sleepSessions.first?.after?.chargePercent, 70)
        XCTAssertFalse(model.sleepSessions.contains { $0.after?.chargePercent == 80 })
        let reads = await queue.readCount
        XCTAssertEqual(reads, 2)
    }

    func testRetainedDisplayChargeCannotFillMissingPostWakeReading() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = SleepSnapshotQueue(values: [80, nil])
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url,
                                 snapshotProvider: { await queue.read() })
        defer { model.stop() }
        await model.refresh()
        model.setSleeping(true); model.setSleeping(false)
        for _ in 0..<300 { if await queue.readCount >= 2 { break }; await Task.yield() }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.snapshot.chargePercent.value, 80, "A retained display reading is permitted.")
        XCTAssertNil(model.sleepSessions.first?.after, "Retained UI values are not fresh endpoint evidence.")
        XCTAssertNil(model.sleepSessions.first?.chargeChangePercentagePoints)
    }

    func testHistoryToggleClosesPendingAndDoesNotCollectWhileDisabled() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url,
                                 snapshotProvider: { SleepSnapshotQueue.sample(80) })
        defer { model.stop() }
        await model.refresh(); model.setSleeping(true)
        XCTAssertEqual(model.sleepSessions.count, 1)
        model.historyEnabled = false
        XCTAssertEqual(model.sleepSessions.first?.phase, .incomplete)
        XCTAssertTrue(model.sleepSessions.first?.issues.contains(.historyDisabled) == true)
        let count = model.sleepSessions.count
        model.setSleeping(false); await model.refresh()
        XCTAssertEqual(model.sleepSessions.count, count)
        XCTAssertNil(model.sleepSessions.first?.after)
    }

    func testPendingDiskObservationBecomesIncompleteOnRelaunchAndEraseUsesSameStore() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try BatteryHistoryStore(url: fixture.url)
        let stamp = SleepObservationStamp(wallDate: Date(), continuousSeconds: 100, runID: UUID())
        try store.upsertSleepSession(.init(sleepBoundary: stamp, phase: .awaitingWake))
        try store.close()
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url)
        defer { model.stop() }
        XCTAssertEqual(model.sleepSessions.first?.phase, .incomplete)
        XCTAssertTrue(model.sleepSessions.first?.issues.contains(.applicationRestarted) == true)
        model.eraseHistory()
        XCTAssertTrue(model.sleepSessions.isEmpty)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testSimulationCannotCollectOrPersistSleepReports() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let model = TilveroModel(isDemo: true, preferences: fixture.preferences, historyURL: fixture.url)
        defer { model.stop() }
        await model.refresh(); model.setSleeping(true); model.setSleeping(false)
        await model.refreshSleepActivity()
        XCTAssertTrue(model.sleepSessions.isEmpty)
        XCTAssertNil(model.sleepActivity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testDisabledHistoryRelaunchRemainsIncompleteAfterRetentionReload() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.preferences.set(false, forKey: "historyEnabled")
        let store = try BatteryHistoryStore(url: fixture.url)
        let stamp = SleepObservationStamp(wallDate: Date(), continuousSeconds: 100, runID: UUID())
        try store.upsertSleepSession(.init(sleepBoundary: stamp, phase: .awaitingWake)); try store.close()
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url)
        defer { model.stop() }
        XCTAssertEqual(model.sleepSessions.first?.phase, .incomplete)
        model.retentionDays = 7
        XCTAssertEqual(model.sleepSessions.first?.phase, .incomplete)
        XCTAssertTrue(model.sleepSessions.first?.issues.contains(.applicationRestarted) == true)
    }

    func testCorruptSleepPayloadDoesNotHideBatteryHistoryOrBecomeEmptySuccess() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try BatteryHistoryStore(url: fixture.url)
        try store.record(SleepSnapshotQueue.sample(80)); try store.close()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
        let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: fixture.url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let row = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
        row.setValue(UUID(), forKey: "id")
        // An unknown/corrupt payload must not be silently discarded by the
        // ordinary battery-history retention pass before sleep validation.
        row.setValue(Date().addingTimeInterval(-400 * 86400), forKey: "atDate")
        row.setValue("sleep", forKey: "kind"); row.setValue(Int64(999), forKey: "sequence")
        row.setValue(try (Data("not-json".utf8) as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
        try context.save(); context.reset(); try coordinator.remove(disk)
        let model = TilveroModel(isDemo: false, preferences: fixture.preferences, historyURL: fixture.url,
                                 snapshotProvider: { SleepSnapshotQueue.sample(79) })
        defer { model.stop() }
        XCTAssertEqual(model.history.last?.chargePercent, 80)
        XCTAssertNotNil(model.sleepReportError)
        await model.refresh()
        XCTAssertNotNil(model.sleepReportError, "A successful battery refresh cannot erase the independent sleep-store error.")
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let suite: String
        let preferences: UserDefaults
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroSleepIntegration-\(UUID())")
            url = directory.appendingPathComponent("History.sqlite")
            suite = "TilveroSleepIntegration.\(UUID())"
            preferences = UserDefaults(suiteName: suite)!
        }
        func cleanup() { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }
}

private actor SleepSnapshotQueue {
    private var values: [Int?]
    private let blockFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    init(values: [Int?], blockFirst: Bool = false) { self.values = values; self.blockFirst = blockFirst }
    func read() async -> BatterySnapshot {
        readCount += 1
        let index = readCount - 1
        if index == 0 && blockFirst { await withCheckedContinuation { continuation = $0 } }
        let value = values[min(index, values.count - 1)]
        return Self.sample(value)
    }
    func releaseFirst() { continuation?.resume(); continuation = nil }
    nonisolated static func sample(_ percent: Int?) -> BatterySnapshot {
        let now = Date()
        return BatterySnapshot(chargePercent: .init(value: percent, source: "fixture", collectedAt: now),
            isCharging: .init(value: false, source: "fixture", collectedAt: now),
            isExternalPower: .init(value: false, source: "fixture", collectedAt: now),
            collectedAt: now, batteryIdentityToken: "fixture-battery")
    }
}
