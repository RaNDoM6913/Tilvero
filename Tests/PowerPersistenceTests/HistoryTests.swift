import XCTest
import Foundation
import CoreData
@testable import PowerCore
@testable import PowerPersistence

@MainActor final class HistoryTests: XCTestCase {
    func testSimulationNeverEntersHistory() throws {
        let store = try BatteryHistoryStore(url: nil)
        XCTAssertThrowsError(try store.record(.demo()))
        XCTAssertEqual(try store.samples().count, 0)
    }
    func testRealDiskReopenPreservesReadingsAndMarksRelaunchBoundary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let date = Date()
        do { let store = try BatteryHistoryStore(url: url); try store.record(sample(at: date, uptime: 100, identity: "a", charge: 80)); try store.close() }
        let reopened = try BatteryHistoryStore(url: url)
        XCTAssertEqual(try reopened.samples().first?.chargePercent, 80)
        try reopened.record(sample(at: date.addingTimeInterval(10), uptime: 110, identity: "a", charge: 81))
        XCTAssertEqual(try reopened.summary().gaps.last?.reason, .launch)
        XCTAssertNotEqual(try reopened.samples().first?.segmentID, try reopened.samples().last?.segmentID)
    }
    func testGapsAndBatteryReplacementPreventPowerIntegration() throws {
        let store = try BatteryHistoryStore(url: nil, configuration: .init(maximumGapSeconds: 30))
        let date = Date()
        try store.record(sample(at: date, uptime: 100, identity: "a", charge: 80, power: 10))
        try store.record(sample(at: date.addingTimeInterval(10), uptime: 110, identity: "a", charge: 81, power: 10))
        try store.record(sample(at: date.addingTimeInterval(1000), uptime: 1100, identity: "a", charge: 82, power: 10))
        try store.record(sample(at: date.addingTimeInterval(1010), uptime: 1110, identity: "b", charge: 50, power: 10))
        let summary = try store.summary()
        XCTAssertEqual(try XCTUnwrap(summary.estimatedChargedWh), 10 * 10 / 3600, accuracy: 0.00001)
        XCTAssertEqual(summary.gaps.map(\.reason), [.offline, .batteryReplacement])
        XCTAssertEqual(summary.coveredSeconds, 10, accuracy: 0.001)
    }
    func testClockChangeAndExplicitSleepAreChartBoundaries() throws {
        let store = try BatteryHistoryStore(url: nil)
        let date = Date()
        try store.record(sample(at: date, uptime: 100, identity: "a", charge: 80))
        try store.record(sample(at: date.addingTimeInterval(-3600), uptime: 110, identity: "a", charge: 80))
        try store.markGap(reason: .sleep, at: date)
        try store.record(sample(at: date.addingTimeInterval(100), uptime: 120, identity: "a", charge: 81))
        XCTAssertTrue(try store.summary().gaps.contains { $0.reason == .clockChange })
        XCTAssertTrue(try store.summary().gaps.contains { $0.reason == .sleep })
    }
    func testDefaultExportsExcludeSensitiveAndPreserveUnitsAndGaps() throws {
        let store = try BatteryHistoryStore(url: nil)
        let date = Date()
        var fixture = sample(at: date, uptime: 1, identity: "secret-token", charge: 80)
        fixture = BatterySnapshot(chargePercent: fixture.chargePercent, collectedAt: date, catalog: fixture.catalog + [
            CatalogReading(definition: BatteryCatalog.definition("059"), value: .text("SECRET_SERIAL"), source: "fixture")],
            monotonicTime: 1, batteryIdentityToken: "secret-token")
        try store.record(fixture)
        let json = String(decoding: try store.exportJSON(), as: UTF8.self)
        let csv = String(decoding: try store.exportCSV(), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET_SERIAL")); XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(csv.contains("SECRET_SERIAL")); XCTAssertFalse(csv.contains("secret-token"))
        XCTAssertTrue(json.contains("availability")); XCTAssertTrue(csv.contains("unit")); XCTAssertTrue(csv.contains("segment"))
    }
    func testRetentionAndAggregationPreserveMissingValues() throws {
        let store = try BatteryHistoryStore(url: nil, configuration: .init(retentionDays: 5, maximumSamples: 5, detailedDays: 0, aggregateIntervalSeconds: 300))
        let date = Date()
        for i in 0..<10 { try store.record(sample(at: date.addingTimeInterval(Double(i) * 10), uptime: Double(i) * 10, identity: "a", charge: Double(80 + i))) }
        let samples = try store.samples()
        XCTAssertLessThanOrEqual(samples.count, 5)
        XCTAssertTrue(samples.contains { $0.isAggregate })
        XCTAssertTrue(samples.allSatisfy { $0.temperatureCelsius == nil })
        try store.erase(); XCTAssertEqual(try store.samples().count, 0)
    }
    func testUnavailableDatabaseDoesNotExposePersonalPath() throws {
        let badURL = URL(fileURLWithPath: "/dev/null/private-account/history.sqlite")
        do { _ = try BatteryHistoryStore(url: badURL); XCTFail("Opening a directory below a file must fail.") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private-account")) }
    }
    func testVersionOneSQLiteMigratesWithoutLosingSamples() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("v1.sqlite")
        let source = try BatteryHistoryStore(url: nil)
        try source.record(sample(at: Date(), uptime: 1, identity: "a", charge: 87))
        var legacyPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(source.samples().first))) as! [String: Any]
        legacyPayload.removeValue(forKey: "energyEvidenceVersion"); legacyPayload["chargedWh"] = 0.0; legacyPayload["dischargedWh"] = 0.0
        let payload = try JSONSerialization.data(withJSONObject: legacyPayload)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 1))
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let object = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
            object.setValue(UUID(), forKey: "id"); object.setValue(Date(), forKey: "atDate")
            object.setValue("sample", forKey: "kind"); object.setValue(Int64(1), forKey: "sequence")
            object.setValue(try (payload as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
            try context.save(); context.reset(); try coordinator.remove(store)
        }
        let migrated = try BatteryHistoryStore(url: url)
        XCTAssertEqual(try migrated.samples().first?.chargePercent, 87)
        XCTAssertNil(try migrated.samples().first?.chargedWh)
        try migrated.close()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        XCTAssertTrue((metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []).contains("TilveroHistory-v2"))
    }
    func testUnknownEnergyIsNotExportedAsMeasuredZero() throws {
        let store = try BatteryHistoryStore(url: nil)
        let date = Date()
        try store.record(sample(at: date, uptime: 100, identity: "a", charge: 80))
        try store.record(sample(at: date.addingTimeInterval(60), uptime: 160, identity: "a", charge: 80))
        XCTAssertNil(try store.summary().estimatedChargedWh)
        XCTAssertNil(try store.catalogReadings().first { $0.id == "085" }?.value)
        try store.record(sample(at: date.addingTimeInterval(120), uptime: 220, identity: "a", charge: 80, power: 0))
        try store.record(sample(at: date.addingTimeInterval(180), uptime: 280, identity: "a", charge: 80, power: 0))
        XCTAssertEqual(try store.summary().estimatedChargedWh, 0)
        XCTAssertNotNil(try store.catalogReadings().first { $0.id == "085" }?.value)
    }
    private func sample(at date: Date, uptime: TimeInterval, identity: String, charge: Double, power: Double? = nil) -> BatterySnapshot {
        let fields = [CatalogReading(definition: BatteryCatalog.definition("011"), value: .decimal(charge), source: "fixture", collectedAt: date, freshness: .fresh),
            CatalogReading(definition: BatteryCatalog.definition("038"), value: power.map(CatalogValue.decimal), source: "fixture", collectedAt: date, provenance: .measured, freshness: .fresh)]
        return BatterySnapshot(chargePercent: .init(value: Int(charge), source: "fixture", collectedAt: date),
            isCharging: .init(value: true, source: "fixture", collectedAt: date), isExternalPower: .init(value: true, source: "fixture", collectedAt: date),
            collectedAt: date, catalog: fields, monotonicTime: uptime, batteryIdentityToken: identity)
    }
}
