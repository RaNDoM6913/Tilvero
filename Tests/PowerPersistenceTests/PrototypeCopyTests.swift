import XCTest
import Foundation
import CoreData
import PowerCore
@testable import PowerPersistence

@MainActor final class PrototypeCopyTests: XCTestCase {
    func testLegacySchemaIsUpgradedOnlyInCopyBeforeIdentifierIsJournaled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroCopyTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("legacy.sqlite")
        let copyURL = folder.appendingPathComponent("production/History.sqlite")
        let source = try BatteryHistoryStore(url: nil)
        try source.record(BatterySnapshot(chargePercent: .init(value: 77, source: "isolated fixture")))
        let payload = try JSONEncoder().encode(try XCTUnwrap(source.samples().first))
        try source.close()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 1))
        let legacy = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: sourceURL, options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let row = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
        row.setValue(UUID(), forKey: "id"); row.setValue(Date(), forKey: "atDate")
        row.setValue("sample", forKey: "kind"); row.setValue(Int64(1), forKey: "sequence")
        row.setValue(try (payload as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
        try context.save(); context.reset(); try coordinator.remove(legacy)
        let original = try Data(contentsOf: sourceURL)
        try BatteryHistoryStore.copyForPrototypeMigration(from: sourceURL, to: copyURL)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: copyURL)
        XCTAssertTrue(BatteryHistoryStore.model(version: 2).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
        let identifier = try BatteryHistoryStore.persistentStoreIdentifier(at: copyURL)
        let reopened = try BatteryHistoryStore(url: copyURL)
        XCTAssertEqual(try reopened.samples().first?.chargePercent, 77)
        try reopened.close()
        XCTAssertEqual(try BatteryHistoryStore.persistentStoreIdentifier(at: copyURL), identifier)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path + "-wal") && ((try? Data(contentsOf: URL(fileURLWithPath: copyURL.path + "-wal")).count) ?? 0) > 0)
    }

    func testCopyCannotOverwriteAnyExistingDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroCopyTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.sqlite"), second = folder.appendingPathComponent("second.sqlite")
        let source = try BatteryHistoryStore(url: first); try source.close()
        let destination = try BatteryHistoryStore(url: second); try destination.close()
        let original = try Data(contentsOf: second)
        XCTAssertThrowsError(try BatteryHistoryStore.copyForPrototypeMigration(from: first, to: second))
        XCTAssertEqual(try Data(contentsOf: second), original)
    }
}
