// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import CoreData
@testable import PowerCore
@testable import PowerPersistence

/// Before a schema upgrade the old store is copied next to it, so a rollback to the previous app can restore it.
@MainActor final class HistoryBackupTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("History.sqlite") }
    private var backup: URL { folder.appendingPathComponent("History.pre-v\(BatteryHistoryStore.currentSchemaVersion).sqlite") }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryBackup-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private func versionTwoStore(rows: Int, journal: String = "WAL") throws {
        let all = try SyntheticHistory.versionTwoRows(now: Date(), detailed: rows, spacing: 60, aggregates: 0)
        try VersionTwoFixture.write(all, to: url)
        if journal != "WAL" {
            // Rewrite as a rollback-journal file (no -wal/-shm needed to read it in a read-only folder).
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
            try coordinator.remove(try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                                       options: [NSSQLitePragmasOption: ["journal_mode": journal]]))
        }
    }

    private func version(of file: URL) throws -> [String] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: file,
                                                                                   options: [NSReadOnlyPersistentStoreOption: true])
        return metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []
    }

    private func sampleCount(inVersionTwo file: URL) throws -> Int {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: file,
                                                       options: [NSReadOnlyPersistentStoreOption: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let count = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryRecord")
            request.predicate = NSPredicate(format: "kind == %@", "sample")
            return try context.count(for: request)
        }
        try coordinator.remove(store)
        return count
    }

    func testMigrationFirstWritesAPrivateSingleFileBackupOfTheOldSchema() async throws {
        try versionTwoStore(rows: 300)
        let store = try BatteryHistoryStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"), "One consistent file, no separate log.")
        XCTAssertTrue(try version(of: backup).contains("TilveroHistory-v2"), "The backup keeps the old schema.")
        XCTAssertTrue(try version(of: url).contains("TilveroHistory-v3"))
        XCTAssertEqual(try sampleCount(inVersionTwo: backup), 300)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try await store.close()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAnExistingBackupIsNeverOverwritten() async throws {
        try versionTwoStore(rows: 20)
        try FileManager.default.copyItem(at: url, to: backup)   // an earlier, smaller old-schema copy
        let original = try Data(contentsOf: backup)
        try FileManager.default.removeItem(at: url)
        try versionTwoStore(rows: 50)
        let store = try BatteryHistoryStore(url: url)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let count = try await store.samples(limit: 1000).count
        XCTAssertEqual(count, 50, "The store itself migrated.")
        try await store.close()
    }

    func testAnUnreadableExistingBackupStopsTheMigrationWithoutTouchingAnything() throws {
        try versionTwoStore(rows: 20)
        try Data("not a database".utf8).write(to: backup)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try BatteryHistoryStore(url: url)) { XCTAssertEqual($0 as? HistoryStoreError, .migrationBackupFailed) }
        XCTAssertEqual(try Data(contentsOf: backup), Data("not a database".utf8))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try version(of: url).contains("TilveroHistory-v2"))
    }

    func testAFailedBackupLeavesTheStoreUnmigratedAndTheNextLaunchRetries() async throws {
        try versionTwoStore(rows: 40, journal: "DELETE")
        let before = try Data(contentsOf: url)
        // A folder that cannot take a new file stands in for a full disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try BatteryHistoryStore(url: url)) { XCTAssertEqual($0 as? HistoryStoreError, .migrationBackupFailed) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertEqual(try Data(contentsOf: url), before, "Nothing was migrated or rewritten.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let retried = try BatteryHistoryStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let count = try await retried.samples(limit: 1000).count
        XCTAssertEqual(count, 40)
        try await retried.close()
    }

    func testBackupsExpireAfterThirtyDaysOrAtTheNextSchemaChange() async throws {
        try versionTwoStore(rows: 10)
        let store = try BatteryHistoryStore(url: url)
        try await store.close()
        let older = folder.appendingPathComponent("History.pre-v2.sqlite")
        try Data("older step".utf8).write(to: older)
        // A current backup younger than 30 days stays.
        _ = try BatteryHistoryStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path), "A backup of an older step goes at the next schema change.")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-31 * 86400)], ofItemAtPath: backup.path)
        _ = try BatteryHistoryStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "Removed after 30 days.")
    }

    func testCurrentStoresAndEphemeralStoresWriteNoBackup() async throws {
        let store = try BatteryHistoryStore(url: url)
        try await store.record(BatterySnapshot(chargePercent: .init(value: 70, source: "fixture")))
        try await store.close()
        _ = try BatteryHistoryStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
