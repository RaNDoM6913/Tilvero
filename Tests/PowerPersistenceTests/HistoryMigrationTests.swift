// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import CoreData
@testable import PowerCore
@testable import PowerPersistence

/// Schema 2 → 3: in-place migration, then a batched, resumable backfill of the scalar columns from payloads.
@MainActor final class HistoryMigrationTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryMigration-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    /// Realistic snapshots: charging and adapter changes, a long offline gap, a battery change, missing values.
    private func snapshots(start: Date) -> [BatterySnapshot] {
        (0..<240).map { index in
            let at = start.addingTimeInterval(Double(index) * 60 + (index >= 150 ? 1800 : 0))
            let charging = (index / 40) % 2 == 0, external = (index / 60) % 2 == 0
            let charge: Double? = index % 37 == 5 ? nil : 50 + Double(index % 30)
            let fields = [
                CatalogReading(definition: BatteryCatalog.definition("011"), value: charge.map(CatalogValue.decimal), source: "fixture", collectedAt: at, freshness: .fresh),
                CatalogReading(definition: BatteryCatalog.definition("038"), value: .decimal(charging ? 12 : -7), source: "fixture", collectedAt: at, provenance: .measured, freshness: .fresh),
                CatalogReading(definition: BatteryCatalog.definition("039"), value: .decimal(30 + Double(index % 5)), source: "fixture", collectedAt: at, provenance: .measured, freshness: .fresh),
                CatalogReading(definition: BatteryCatalog.definition("026"), value: .decimal(95), source: "fixture", collectedAt: at, provenance: .estimated, freshness: .fresh)]
            return BatterySnapshot(chargePercent: .init(value: charge.map { Int($0) }, source: "fixture", collectedAt: at),
                isCharging: .init(value: charging, source: "fixture", collectedAt: at), isExternalPower: .init(value: external, source: "fixture", collectedAt: at),
                cycleCount: .init(value: 100 + index / 100, source: "fixture", collectedAt: at),
                collectedAt: at, catalog: fields, monotonicTime: Double(index) * 60 + (index >= 150 ? 1800 : 0) + 1000,
                batteryIdentityToken: index < 200 ? "battery-a" : "battery-b")
        }
    }

    /// Records the snapshots in a fresh store and returns its payload-level rows in v2 order plus the reference summary.
    private func versionTwoRows(start: Date) async throws -> (rows: [VersionTwoFixture.Row], summary: HistorySummary, samples: [HistorySample]) {
        let reference = try BatteryHistoryStore(url: nil)
        for snapshot in snapshots(start: start) { try await reference.record(snapshot) }
        let summary = try await reference.summary()
        let samples = try await reference.samples(limit: 100000)
        try await reference.close()
        var rows: [(Date, Int, VersionTwoFixture.Row)] = []
        for sample in samples {
            rows.append((sample.collectedAt, 1, .init(kind: "sample", at: sample.collectedAt, payload: try VersionTwoFixture.compressed(sample),
                                                     identity: sample.collectedAt < start.addingTimeInterval(200 * 60 + 1800) ? "battery-a" : "battery-b")))
        }
        for gap in summary.gaps { rows.append((gap.end, 0, .init(kind: "gap", at: gap.end, payload: try VersionTwoFixture.compressed(gap)))) }
        return (rows.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2), summary, samples)
    }

    func testVersionTwoStoreMigratesInPlaceBackfillsResumablyAndMatchesTheRecordedSummary() async throws {
        let url = folder.appendingPathComponent("History.sqlite")
        let start = Date().addingTimeInterval(-6 * 3600)
        let (rows, expected, samples) = try await versionTwoRows(start: start)
        XCTAssertGreaterThan(expected.gaps.count, 1, "Fixture covers offline and battery-change boundaries.")
        XCTAssertGreaterThan(expected.sessions.count, 3)
        try VersionTwoFixture.write(rows, to: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let store = try BatteryHistoryStore(url: url)
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        XCTAssertTrue((metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []).contains("TilveroHistory-v3"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode, "Migrated in place, not copied.")
        let pending = try await store.summaryIfReady()
        XCTAssertNil(pending, "No partial or zero summary while columns are still empty.")
        // Before the backfill the rows are still readable (from their payloads).
        let beforeBackfill = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertEqual(beforeBackfill.map(\.id), samples.map(\.id))
        XCTAssertEqual(beforeBackfill.map(\.chargePercent), samples.map(\.chargePercent))

        // One batch, then the app quits: the next launch resumes where it stopped.
        let finished = try await store.backfillOnce(limit: 100)
        XCTAssertFalse(finished)
        try await store.close()
        let reopened = try BatteryHistoryStore(url: url)
        var diagnostics = await reopened.diagnostics()
        XCTAssertFalse(diagnostics.backfillComplete)
        try await reopened.completeBackfill(batchSize: 64)
        diagnostics = await reopened.diagnostics()
        XCTAssertTrue(diagnostics.backfillComplete)
        XCTAssertEqual(diagnostics.corruptRows, 0)
        XCTAssertEqual(diagnostics.summaryRebuilds, 1, "Exactly one rebuild, after the backfill.")
        let migrated = try await reopened.summary()
        XCTAssertEqual(migrated, expected)
        // Scalars now come from columns and equal what the payloads say.
        let fromColumns = try await reopened.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertEqual(fromColumns, beforeBackfill)
        let again = try await reopened.backfillOnce(limit: 10)
        XCTAssertTrue(again, "A finished backfill is a no-op.")
        try await reopened.close()

        // An ordinary launch reads the persisted summary instead of rescanning.
        let launched = try await BatteryHistoryStore.open(url: url)
        let launchSummary = try await launched.summaryIfReady()
        XCTAssertEqual(launchSummary, expected)
        diagnostics = await launched.diagnostics()
        XCTAssertEqual(diagnostics.summaryRebuilds, 0)
        XCTAssertEqual(diagnostics.mainThreadOperations, 0)
        try await launched.close()
    }

    func testCorruptVersionTwoRowsStayFlaggedPreservedAndNeverBecomeAnEmptySummary() async throws {
        let url = folder.appendingPathComponent("History.sqlite")
        let start = Date().addingTimeInterval(-6 * 3600)
        var (rows, _, samples) = try await versionTwoRows(start: start)
        let corruptAt = samples[120].collectedAt.addingTimeInterval(1)
        let corrupt = try VersionTwoFixture.corruptPayload()
        rows.insert(.init(kind: "sample", at: corruptAt, payload: corrupt, identity: "battery-a"), at: rows.firstIndex { $0.at > corruptAt }!)
        rows.insert(.init(kind: "gap", at: corruptAt, payload: corrupt), at: rows.firstIndex { $0.at > corruptAt }!)
        try VersionTwoFixture.write(rows, to: url)

        let store = try BatteryHistoryStore(url: url)
        try await store.completeBackfill(batchSize: 50)
        let diagnostics = await store.diagnostics()
        XCTAssertTrue(diagnostics.backfillComplete)
        XCTAssertEqual(diagnostics.corruptRows, 2)
        await assertCorrupt { _ = try await store.summary() }
        await assertCorrupt { _ = try await store.summaryIfReady() }
        await assertCorrupt { _ = try await store.samples() }
        let afterCorruption = try await store.samples(since: corruptAt.addingTimeInterval(1))
        XCTAssertEqual(afterCorruption.count, samples.filter { $0.collectedAt > corruptAt }.count, "Rows outside the damaged one still read.")
        // Ordinary maintenance neither repairs nor drops a damaged row.
        try await store.maintain()
        try await store.close()
        for kind in ["sample", "gap"] {
            let flagged = try VersionTwoFixture.rawRows(at: url, kind: kind).filter { $0.columnsVersion == -1 }
            XCTAssertEqual(flagged.count, 1, kind)
            XCTAssertEqual(flagged.first?.payload, corrupt, "\(kind) payload preserved byte for byte")
        }

        // Erase is the user's explicit way out: everything goes, and the store is consistent and empty afterwards.
        let reopened = try BatteryHistoryStore(url: url)
        try await reopened.erase()
        let empty = try await reopened.summary()
        XCTAssertEqual(empty.sampleCount, 0)
        XCTAssertTrue(empty.gaps.isEmpty)
        XCTAssertNil(empty.estimatedChargedWh)
        let none = try await reopened.samples()
        XCTAssertTrue(none.isEmpty)
        let erased = await reopened.diagnostics()
        XCTAssertEqual(erased.corruptRows, 0)
        try await reopened.record(snapshots(start: Date())[0])
        let after = try await reopened.summary()
        XCTAssertEqual(after.sampleCount, 1)
        try await reopened.close()
    }

    func testNewerSchemaIsRefusedWithoutTouchingTheFile() throws {
        let url = folder.appendingPathComponent("History.sqlite")
        let model = BatteryHistoryStore.model(version: BatteryHistoryStore.currentSchemaVersion).copy() as! NSManagedObjectModel
        model.versionIdentifiers = ["TilveroHistory-v\(BatteryHistoryStore.currentSchemaVersion + 1)"]
        let attribute = NSAttributeDescription(); attribute.name = "future"; attribute.attributeType = .stringAttributeType; attribute.isOptional = true
        model.entities.first!.properties.append(attribute)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.remove(try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url))
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try BatteryHistoryStore(url: url)) { XCTAssertEqual($0 as? HistoryStoreError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    private func assertCorrupt(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("A flagged row must surface as an error.", file: file, line: line) }
        catch { XCTAssertEqual(error as? HistoryStoreError, .corruptRecord, file: file, line: line) }
    }
}
