import XCTest
import CoreData
import SQLite3
import PowerCore
@testable import PowerPersistence

@MainActor final class SleepPersistenceTests: XCTestCase {
    private func record(at date: Date = Date(), id: UUID = UUID()) -> SleepSessionRecord {
        let stamp = SleepObservationStamp(wallDate: date, continuousSeconds: 100, runID: UUID())
        let endpoint = SleepBatteryEndpoint(snapshot: BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: date),
            collectedAt: date, batteryIdentityToken: "private-salted-identity"), stamp: stamp)
        return .init(id: id, sleepBoundary: stamp, before: endpoint, phase: .awaitingWake)
    }
    func testUpsertReopenPrototypeCopyAndEraseKeepStableRecordAndBatteryHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroSleep-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite"), copyURL = folder.appendingPathComponent("copy.sqlite")
        let first = record()
        let finished = first.interrupted(reason: .applicationStopped, at: .init(wallDate: Date(), continuousSeconds: 110, runID: first.sleepBoundary!.runID))
        let store = try BatteryHistoryStore(url: url)
        try store.record(BatterySnapshot(chargePercent: .init(value: 80, source: "fixture")))
        try store.upsertSleepSession(first)
        try store.upsertSleepSession(finished)
        XCTAssertEqual(try store.sleepSessions(), [finished])
        XCTAssertEqual(try store.samples().count, 1)
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains(first.id.uuidString))
        XCTAssertFalse(String(decoding: try store.exportJSON(), as: UTF8.self).contains("private-salted-identity"))
        try store.close()
        try BatteryHistoryStore.copyForPrototypeMigration(from: url, to: copyURL)
        let reopened = try BatteryHistoryStore(url: copyURL)
        XCTAssertEqual(try reopened.sleepSessions(), [finished])
        XCTAssertEqual(try reopened.sleepSessions().first?.before?.batteryIdentityToken, "private-salted-identity")
        XCTAssertEqual(try reopened.samples().count, 1)
        try reopened.erase()
        XCTAssertTrue(try reopened.sleepSessions().isEmpty)
        XCTAssertTrue(try reopened.samples().isEmpty)
        try reopened.close()
        let original = try BatteryHistoryStore(url: url)
        XCTAssertEqual(try original.sleepSessions(), [finished])
        try original.close()
    }
    func testSleepRetentionUsesDetailedPeriodWithoutDeletingAnnualSamples() throws {
        let store = try BatteryHistoryStore(url: nil, configuration: .init(retentionDays: 365, detailedDays: 30))
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
        try store.record(BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: tenDaysAgo), collectedAt: tenDaysAgo))
        try store.upsertSleepSession(record(at: tenDaysAgo))
        XCTAssertEqual(try store.sleepSessions().count, 1)
        try store.configureRetention(7)
        XCTAssertTrue(try store.sleepSessions().isEmpty)
        XCTAssertEqual(try store.samples().count, 1)
        XCTAssertEqual(store.retentionDays, 365)
        try store.configureRetention(30)
        try store.upsertSleepSession(record(at: tenDaysAgo))
        XCTAssertEqual(try store.sleepSessions().count, 1)
    }
    func testSeparateCapKeepsLatestTwoThousandRowsWithoutDuplicatingUpserts() throws {
        let store = try BatteryHistoryStore(url: nil)
        let now = Date()
        for index in 0..<2002 { try store.upsertSleepSession(record(at: now.addingTimeInterval(Double(index) / 10))) }
        let records = try store.sleepSessions(limit: 100000)
        XCTAssertEqual(records.count, 2000)
        XCTAssertEqual(records.first?.observedAt, now.addingTimeInterval(0.2))
        XCTAssertEqual(try store.sleepSessions(limit: 5).count, 5)
        XCTAssertTrue(try store.sleepSessions(limit: 0).isEmpty)
    }
    func testUnknownVersionAndCorruptSleepRowsArePreservedAndBatteryHistoryStillReads() throws {
        for payload in [Data("{\"version\":99,\"record\":{}}".utf8), Data("NOT_JSON".utf8), Data(repeating: 0, count: 140_000)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroSleepCorrupt-\(UUID())")
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("history.sqlite")
            let first = try BatteryHistoryStore(url: url)
            try first.record(BatterySnapshot(chargePercent: .init(value: 71, source: "fixture")))
            try first.close()
            try inject(payload, at: url)
            let reopened = try BatteryHistoryStore(url: url)
            XCTAssertThrowsError(try reopened.sleepSessions())
            XCTAssertThrowsError(try reopened.upsertSleepSession(record()))
            XCTAssertEqual(try reopened.samples().first?.chargePercent, 71)
            try reopened.close()
            XCTAssertEqual(try rawSleepPayload(at: url), payload)
        }
    }
    func testInvalidDomainPayloadCannotReplaceExistingRow() throws {
        let store = try BatteryHistoryStore(url: nil)
        let valid = record()
        try store.upsertSleepSession(valid)
        let invalid = SleepSessionRecord(id: valid.id, sleepBoundary: nil, phase: .closed)
        XCTAssertThrowsError(try store.upsertSleepSession(invalid))
        XCTAssertEqual(try store.sleepSessions(), [valid])
        try store.close()
        XCTAssertThrowsError(try store.upsertSleepSession(valid))
    }
    func testFailedSQLiteSaveRollsBackSleepInsertAndStoreCanRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroSleepRollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let store = try BatteryHistoryStore(url: url)
        try store.record(BatterySnapshot(chargePercent: .init(value: 72, source: "fixture")))
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        // A runtime SQLite error avoids Core Data's constraint/optimistic-lock retry loop.
        let reject = "CREATE TRIGGER reject_sleep_fixture BEFORE INSERT ON ZHISTORYRECORD WHEN NEW.ZKIND = 'sleep' BEGIN SELECT abs(-9223372036854775808); END;"
        XCTAssertEqual(sqlite3_exec(connection, reject, nil, nil, nil), SQLITE_OK)
        let pending = record()
        XCTAssertThrowsError(try store.upsertSleepSession(pending))
        XCTAssertTrue(try store.sleepSessions().isEmpty)
        XCTAssertEqual(try store.samples().first?.chargePercent, 72)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER reject_sleep_fixture", nil, nil, nil), SQLITE_OK)
        try store.upsertSleepSession(pending)
        XCTAssertEqual(try store.sleepSessions(), [pending])
        try store.close()
    }
    private func inject(_ payload: Data, at url: URL) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let row = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
        row.setValue(UUID(), forKey: "id"); row.setValue(Date(), forKey: "atDate")
        row.setValue("sleep", forKey: "kind"); row.setValue(Int64(2), forKey: "sequence")
        row.setValue(try (payload as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
        try context.save(); context.reset(); try coordinator.remove(store)
    }
    private func rawSleepPayload(at url: URL) throws -> Data {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryRecord")
        request.predicate = NSPredicate(format: "kind == %@", "sleep")
        let row = try XCTUnwrap(context.fetch(request).first)
        let data = try XCTUnwrap(row.value(forKey: "payload") as? Data)
        let uncompressed = try (data as NSData).decompressed(using: .lzfse) as Data
        context.reset(); try coordinator.remove(store)
        return uncompressed
    }
}
