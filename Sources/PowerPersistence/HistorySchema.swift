// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreData

/// Versioned Core Data models of History.sqlite. Version 3 adds the scalar columns charts, summaries and the weekly
/// capacity read instead of decoding payloads; the payload stays the source of the full catalog readings.
enum HistorySchema {
    static let currentVersion = 3
    static let entityName = "HistoryRecord"

    /// Columns written for every sample row (version 3). Optional values stay optional: missing is never zero.
    nonisolated(unsafe) static let scalarAttributes: [(name: String, type: NSAttributeType, optional: Bool, defaultValue: Any?)] = [
        ("columnsVersion", .integer16AttributeType, false, 0),
        ("chargePercent", .doubleAttributeType, true, nil),
        ("temperature", .doubleAttributeType, true, nil),
        ("batteryPower", .doubleAttributeType, true, nil),
        ("capacityRetention", .doubleAttributeType, true, nil),
        ("capacityEstimate", .doubleAttributeType, true, nil),
        ("cycleCount", .integer64AttributeType, true, nil),
        ("isCharging", .booleanAttributeType, true, nil),
        ("isExternalPower", .booleanAttributeType, true, nil),
        ("isAggregate", .booleanAttributeType, false, false),
        ("aggregateCount", .integer64AttributeType, false, 0),
        ("segmentID", .UUIDAttributeType, true, nil),
        ("coveredSeconds", .doubleAttributeType, false, 0.0),
        ("chargedWh", .doubleAttributeType, true, nil),
        ("dischargedWh", .doubleAttributeType, true, nil),
        ("externalPowerSeconds", .doubleAttributeType, false, 0.0),
        ("observedFrom", .dateAttributeType, true, nil),
        ("monotonicTime", .doubleAttributeType, true, nil),
        ("timeZoneOffset", .integer32AttributeType, false, 0),
        ("energyEvidenceVersion", .integer16AttributeType, true, nil),
        // Gap and session rows: end of the interval, gap reason / session kind, whether a session start was observed.
        ("endDate", .dateAttributeType, true, nil),
        ("label", .stringAttributeType, true, nil),
        ("startKnown", .booleanAttributeType, false, false)
    ]

    /// `columnsVersion` of a row: 0 = written by version 2 and not yet backfilled, 1 = columns valid,
    /// -1 = the payload could not be decoded. Flagged rows stay on disk untouched and are reported, never read as empty.
    enum Columns {
        static let pending: Int16 = 0
        static let valid: Int16 = 1
        static let corrupt: Int16 = -1
    }

    nonisolated(unsafe) private static let models: [Int: NSManagedObjectModel] = {
        var result: [Int: NSManagedObjectModel] = [:]
        for version in 1...currentVersion {
            let model = build(version: version)
            // A coordinator freezes the model: its version checksum is stable only afterwards.
            _ = NSPersistentStoreCoordinator(managedObjectModel: model)
            result[version] = model
        }
        return result
    }()

    /// Versions 1 and 2 are kept for real migration fixtures and the staged migration, never for a new store.
    static func model(version: Int) -> NSManagedObjectModel { models[version]! }

    private static func build(version: Int) -> NSManagedObjectModel {
        let model = NSManagedObjectModel(); model.versionIdentifiers = ["TilveroHistory-v\(version)"]
        let entity = NSEntityDescription(); entity.name = entityName; entity.managedObjectClassName = "NSManagedObject"
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional
            a.defaultValue = defaultValue
            return a
        }
        var properties: [NSPropertyDescription] = [attribute("id", .UUIDAttributeType), attribute("atDate", .dateAttributeType),
            attribute("kind", .stringAttributeType), attribute("payload", .binaryDataAttributeType), attribute("sequence", .integer64AttributeType)]
        if version >= 2 { properties.append(attribute("identityToken", .stringAttributeType, optional: true)) }
        if version >= 3 {
            properties += scalarAttributes.map { attribute($0.name, $0.type, optional: $0.optional, defaultValue: $0.defaultValue) }
        }
        entity.properties = properties
        func index(_ name: String, _ names: [String]) -> NSFetchIndexDescription {
            NSFetchIndexDescription(name: name, elements: names.map { property in
                NSFetchIndexElementDescription(property: properties.first { $0.name == property }!, collationType: .binary)
            })
        }
        var indexes = [index("bySequence", ["sequence"])]
        if version >= 3 {
            indexes += [index("byKindSequence", ["kind", "sequence"]), index("byKindDate", ["kind", "atDate"]),
                        index("byColumns", ["columnsVersion"]), index("bySegment", ["segmentID"])]
        }
        entity.indexes = indexes
        model.entities = [entity]
        return model
    }

    /// The version of an existing store, or nil when no known model matches (a newer app wrote it, or it is not ours).
    static func compatibleVersion(_ metadata: [String: Any]) -> Int? {
        (1...currentVersion).reversed().first { model(version: $0).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) }
    }

    static func declaresNewerVersion(_ metadata: [String: Any]) -> Bool {
        let versions = metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []
        return versions.contains { version in
            guard version.hasPrefix("TilveroHistory-v"), let n = Int(version.dropFirst("TilveroHistory-v".count)) else { return false }
            return n > currentVersion
        }
    }

    /// In-place lightweight stages (SQLite ALTER TABLE), so a large store is not copied. The new columns start at their
    /// defaults with `columnsVersion` 0; the store backfills them from payloads afterwards, in batches and off the main thread.
    static func stagedMigrationManager() -> NSStagedMigrationManager {
        let references = (1...currentVersion).map { version -> NSManagedObjectModelReference in
            let model = model(version: version)
            return NSManagedObjectModelReference(model: model, versionChecksum: model.versionChecksum)
        }
        let stages = zip(references, references.dropFirst()).map { NSCustomMigrationStage(migratingFrom: $0, to: $1) }
        return NSStagedMigrationManager(stages)
    }
}
