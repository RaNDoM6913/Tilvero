// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreData
@testable import PowerCore
@testable import PowerPersistence

/// Builds stores exactly as schema version 2 wrote them (the recorded v2 model, LZFSE-compressed JSON payloads, random
/// record ids, no scalar columns), so migration and backfill are tested against the real on-disk shape.
enum VersionTwoFixture {
    struct Row {
        let kind: String
        let at: Date
        let payload: Data
        var identity: String? = nil
    }

    static func write(_ rows: [Row], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: 2))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                                       options: [NSSQLitePragmasOption: ["journal_mode": "WAL"]])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            for (index, row) in rows.enumerated() {
                let object = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
                object.setValue(UUID(), forKey: "id"); object.setValue(row.at, forKey: "atDate"); object.setValue(row.kind, forKey: "kind")
                object.setValue(row.payload, forKey: "payload"); object.setValue(Int64(index + 1), forKey: "sequence")
                object.setValue(row.identity, forKey: "identityToken")
                if index % 5000 == 4999 { try context.save(); context.reset() }
            }
            try context.save(); context.reset()
        }
        try coordinator.remove(store)
    }

    static func compressed<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try (encoder.encode(value) as NSData).compressed(using: .lzfse) as Data
    }

    static func corruptPayload() throws -> Data { try (Data("NOT_JSON".utf8) as NSData).compressed(using: .lzfse) as Data }

    /// Raw rows as a v3 coordinator sees them, for checks that must bypass the store (payload bytes, flags).
    static func rawRows(at url: URL, kind: String) throws -> [(payload: Data, columnsVersion: Int16, atDate: Date)] {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: BatteryHistoryStore.currentSchemaVersion))
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let rows = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryRecord")
            request.predicate = NSPredicate(format: "kind == %@", kind)
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
            return try context.fetch(request).map { ($0.value(forKey: "payload") as! Data, ($0.value(forKey: "columnsVersion") as! NSNumber).int16Value,
                                                     $0.value(forKey: "atDate") as! Date) }
        }
        try coordinator.remove(store)
        return rows
    }
}

/// Synthetic samples without going through `record` (60,000 records would take minutes).
enum SyntheticHistory {
    static func reading(_ id: String, _ value: Double?, at date: Date, provenance: TelemetryProvenance = .measured, reason: String? = nil) -> CatalogReading {
        CatalogReading(definition: BatteryCatalog.definition(id), value: value.map(CatalogValue.decimal), source: "fixture",
                       keyPath: "observed-v2/Voltage", collectedAt: date, provenance: provenance, freshness: .fresh, reason: reason)
    }

    static func sample(at date: Date, segment: UUID, charge: Double?, power: Double?, temperature: Double? = 31,
                       charging: Bool? = false, external: Bool? = false, aggregate: Bool = false, count: Int = 1,
                       covered: Double = 50, noise: String? = nil) -> HistorySample {
        var readings = [reading("011", charge, at: date), reading("038", power, at: date), reading("039", temperature, at: date),
                        reading("026", 96, at: date, provenance: .estimated), reading("043", 9.5, at: date), reading("054", external == true ? 30 : nil, at: date)]
        if let noise { readings.append(reading("113", 1, at: date, reason: noise)) }
        let energy = power.map { $0 * covered / 3600 }
        return HistorySample(id: UUID(), collectedAt: date, monotonicTime: date.timeIntervalSince1970, timeZoneOffsetSeconds: 0,
                             segmentID: segment, chargePercent: charge, temperatureCelsius: temperature, batteryPowerWatts: power,
                             capacityRetentionPercent: 96, cycleCount: 120, isCharging: charging, isExternalPower: external,
                             isAggregate: aggregate, aggregateCount: count, readings: readings, observedFrom: date.addingTimeInterval(aggregate ? -3540 : 0),
                             coveredSeconds: covered, energyEvidenceVersion: 1, chargedWh: energy.map { max(0, $0) },
                             dischargedWh: energy.map { max(0, -$0) }, externalPowerSeconds: external == true ? covered : 0)
    }

    /// `detailed` rows every `spacing` seconds ending at `now`, preceded by hourly aggregates; segments change daily.
    static func versionTwoRows(now: Date, detailed: Int, spacing: TimeInterval, aggregates: Int, noise: Bool = false) throws -> [VersionTwoFixture.Row] {
        let encoder = JSONEncoder()
        var rows: [VersionTwoFixture.Row] = []
        rows.reserveCapacity(detailed + aggregates)
        let detailStart = now.addingTimeInterval(-Double(detailed - 1) * spacing)
        var segment = UUID()
        for index in 0..<aggregates {
            let at = detailStart.addingTimeInterval(-Double(aggregates - index) * 3600)
            if index % 24 == 0 { segment = UUID() }
            let value = sample(at: at, segment: segment, charge: 40 + Double(index % 50), power: -8, charging: false, external: index % 48 < 24,
                               aggregate: true, count: 60, covered: 3000, noise: noise ? randomText() : nil)
            rows.append(.init(kind: "sample", at: at, payload: try VersionTwoFixture.compressed(value, encoder: encoder), identity: "fixture-battery"))
        }
        for index in 0..<detailed {
            let at = detailStart.addingTimeInterval(Double(index) * spacing)
            if index % 1728 == 0 { segment = UUID() }
            let phase = (index / 90) % 4
            let value = sample(at: at, segment: segment, charge: 20 + Double(index % 80), power: phase < 2 ? 15 : -9,
                               charging: phase < 2, external: phase < 3, covered: spacing, noise: noise ? randomText() : nil)
            rows.append(.init(kind: "sample", at: at, payload: try VersionTwoFixture.compressed(value, encoder: encoder), identity: "fixture-battery"))
        }
        return rows
    }

    /// Weakly compressible text: keeps fixture payloads close to real catalog sizes.
    static func randomText() -> String { (0..<6).map { _ in UUID().uuidString }.joined(separator: " ") }
}
