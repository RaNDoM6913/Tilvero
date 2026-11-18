// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import CoreData
@testable import PowerCore
@testable import PowerPersistence

/// The running summary must say what a full rescan of the retained samples says, after records, aggregation and trims.
@MainActor final class HistorySummaryTests: XCTestCase {
    private func snapshot(_ index: Int, start: Date, identity: String = "battery") -> BatterySnapshot {
        let at = start.addingTimeInterval(Double(index) * 60)
        let charging = (index / 25) % 3 != 2, external = (index / 25) % 3 == 0 || (index / 25) % 3 == 1 && index % 2 == 0
        let fields = [
            CatalogReading(definition: BatteryCatalog.definition("011"), value: .decimal(40 + Double(index % 50)), source: "fixture", collectedAt: at, freshness: .fresh),
            CatalogReading(definition: BatteryCatalog.definition("038"), value: index % 11 == 3 ? nil : .decimal(charging ? 10 : -6), source: "fixture", collectedAt: at, provenance: .measured, freshness: .fresh),
            CatalogReading(definition: BatteryCatalog.definition("039"), value: .decimal(29 + Double(index % 4)), source: "fixture", collectedAt: at, provenance: .measured, freshness: .fresh)]
        return BatterySnapshot(chargePercent: .init(value: 40 + index % 50, source: "fixture", collectedAt: at),
            isCharging: .init(value: charging, source: "fixture", collectedAt: at), isExternalPower: .init(value: external, source: "fixture", collectedAt: at),
            collectedAt: at, catalog: fields, monotonicTime: Double(index) * 60 + 50, batteryIdentityToken: identity)
    }

    private func assertEquivalent(_ running: HistorySummary, _ rebuilt: HistorySummary, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(running.sampleCount, rebuilt.sampleCount, context, file: file, line: line)
        XCTAssertEqual(running.monitoringStart, rebuilt.monitoringStart, context, file: file, line: line)
        XCTAssertEqual(running.chargingSessionCount, rebuilt.chargingSessionCount, context, file: file, line: line)
        XCTAssertEqual(running.sessions, rebuilt.sessions, context, file: file, line: line)
        XCTAssertEqual(running.gaps, rebuilt.gaps, context, file: file, line: line)
        XCTAssertEqual(running.coveredSeconds, rebuilt.coveredSeconds, accuracy: 1e-6, context, file: file, line: line)
        XCTAssertEqual(running.observedExternalPowerSeconds, rebuilt.observedExternalPowerSeconds, accuracy: 1e-6, context, file: file, line: line)
        XCTAssertEqual(running.estimatedChargedWh == nil, rebuilt.estimatedChargedWh == nil, context, file: file, line: line)
        XCTAssertEqual(running.estimatedChargedWh ?? 0, rebuilt.estimatedChargedWh ?? 0, accuracy: 1e-9, context, file: file, line: line)
        XCTAssertEqual(running.estimatedDischargedWh ?? 0, rebuilt.estimatedDischargedWh ?? 0, accuracy: 1e-9, context, file: file, line: line)
    }

    func testRunningSummaryMatchesARescanAfterRecordsAndOldestFirstTrims() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySummary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        // A small sample cap trims the oldest rows (and the sessions that started in them) every few records.
        let configuration = HistoryConfiguration(maximumSamples: 40)
        let store = try BatteryHistoryStore(url: url, configuration: configuration)
        let start = Date().addingTimeInterval(-86400)
        for index in 0..<400 {
            if index == 170 { try await store.markGap(reason: .sleep, at: start.addingTimeInterval(Double(index) * 60 - 30)) }
            try await store.record(snapshot(index, start: start, identity: index < 300 ? "battery" : "replacement"))
            if index % 25 == 24 {
                let running = try await store.summary()
                let rebuilt = try await store.rebuiltSummary()
                assertEquivalent(running, rebuilt, "after \(index + 1) records")
            }
        }
        let samples = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        let summary = try await store.summary()
        XCTAssertEqual(summary.sampleCount, samples.reduce(0) { $0 + $1.aggregateCount })
        XCTAssertLessThanOrEqual(samples.count, 41, "The cap trimmed the oldest samples.")
        try await store.close()

        // The summary survives a relaunch unchanged and without a rescan.
        let reopened = try BatteryHistoryStore(url: url, configuration: configuration)
        let relaunched = try await reopened.summary()
        XCTAssertEqual(relaunched, summary)
        let diagnostics = await reopened.diagnostics()
        XCTAssertEqual(diagnostics.summaryRebuilds, 0)
        try await reopened.close()
    }

    /// Merging expired hours keeps every total; sessions keep the start observed when they were recorded (a rescan of
    /// aggregates could only place them at bucket boundaries), so only the totals are compared here.
    func testAggregationKeepsTheRunningTotals() async throws {
        let store = try BatteryHistoryStore(url: nil, configuration: .init(maximumSamples: 1000, detailedDays: 0, aggregateIntervalSeconds: 600))
        let start = Date().addingTimeInterval(-86400)
        for index in 0..<300 {
            try await store.record(snapshot(index, start: start))
            if index % 60 == 59 {
                let running = try await store.summary()
                let rebuilt = try await store.rebuiltSummary()
                XCTAssertEqual(running.sampleCount, rebuilt.sampleCount)
                XCTAssertEqual(running.monitoringStart, rebuilt.monitoringStart)
                XCTAssertEqual(running.gaps, rebuilt.gaps)
                XCTAssertEqual(running.coveredSeconds, rebuilt.coveredSeconds, accuracy: 1e-6)
                XCTAssertEqual(running.estimatedChargedWh ?? -1, rebuilt.estimatedChargedWh ?? -1, accuracy: 1e-9)
                XCTAssertEqual(running.estimatedDischargedWh ?? -1, rebuilt.estimatedDischargedWh ?? -1, accuracy: 1e-9)
                XCTAssertEqual(running.observedExternalPowerSeconds, rebuilt.observedExternalPowerSeconds, accuracy: 1e-6)
            }
        }
        let samples = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertTrue(samples.contains { $0.isAggregate }, "Aggregation ran.")
        let summary = try await store.summary()
        XCTAssertEqual(summary.sampleCount, 300)
        XCTAssertEqual(summary.sampleCount, samples.reduce(0) { $0 + $1.aggregateCount })
        try await store.close()
    }

    func testAMissingOrStaleSummaryRowIsRebuiltOnOpen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySummaryRepair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let store = try BatteryHistoryStore(url: url)
        let start = Date().addingTimeInterval(-3600)
        for index in 0..<30 { try await store.record(snapshot(index, start: start)) }
        let expected = try await store.summary()
        try await store.close()
        // Damage the persisted summary: the store must notice and rescan instead of reporting stale totals.
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: BatteryHistoryStore.model(version: BatteryHistoryStore.currentSchemaVersion))
        let disk = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryRecord")
            request.predicate = NSPredicate(format: "kind == %@", "summary-state-v1")
            let row = try XCTUnwrap(context.fetch(request).first)
            row.setValue(try (Data("{}".utf8) as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
            try context.save()
        }
        try coordinator.remove(disk)
        let repaired = try BatteryHistoryStore(url: url)
        let summary = try await repaired.summary()
        XCTAssertEqual(summary, expected)
        let diagnostics = await repaired.diagnostics()
        XCTAssertEqual(diagnostics.summaryRebuilds, 1)
        try await repaired.close()
    }

    func testSleepReadsArePureAndMaintenancePrunes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySleepPrune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let store = try BatteryHistoryStore(url: url, configuration: .init(detailedDays: 30))
        let old = Date().addingTimeInterval(-10 * 86400)
        let stamp = SleepObservationStamp(wallDate: old, continuousSeconds: 100, runID: UUID())
        let endpoint = SleepBatteryEndpoint(snapshot: BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: old), collectedAt: old), stamp: stamp)
        try await store.upsertSleepSession(.init(sleepBoundary: stamp, before: endpoint, phase: .awaitingWake))
        try await store.close()
        // A 7-day period hides the row from reads; only maintenance removes it.
        let reopened = try BatteryHistoryStore(url: url, configuration: .init(detailedDays: 7))
        let visible = try await reopened.sleepSessions()
        XCTAssertTrue(visible.isEmpty)
        try await reopened.close()
        XCTAssertEqual(try VersionTwoFixture.rawRows(at: url, kind: "sleep").count, 1, "A read never deletes.")
        let maintained = try BatteryHistoryStore(url: url, configuration: .init(detailedDays: 7))
        try await maintained.maintain()
        try await maintained.close()
        XCTAssertTrue(try VersionTwoFixture.rawRows(at: url, kind: "sleep").isEmpty)
    }

    func testStorageUsageReportsDatabaseAndLog() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryUsage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try BatteryHistoryStore(url: folder.appendingPathComponent("History.sqlite"))
        let usage = try await store.storageUsage()
        XCTAssertGreaterThan(usage.bytes, 0)
        XCTAssertEqual(usage.limitBytes, 512 * 1024 * 1024)
        XCTAssertEqual(usage.limitMegabytes, 512)
        XCTAssertGreaterThanOrEqual(usage.megabytes, 1, "A non-empty store never reads 0 MB.")
        let ephemeral = try BatteryHistoryStore(url: nil)
        let none = try await ephemeral.storageUsage()
        XCTAssertEqual(none.bytes, 0)
        try await store.close(); try await ephemeral.close()
    }

    func testFullVacuumPolicyIsWeeklyIdleAndOnAdapterOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let big: Int64 = 100 * 1024 * 1024
        let week = HistoryVacuumPolicy.minimumInterval
        XCTAssertTrue(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: nil, onExternalPower: true, idle: true, fileBytes: big))
        XCTAssertTrue(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: now.addingTimeInterval(-week), onExternalPower: true, idle: true, fileBytes: big))
        XCTAssertFalse(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: now.addingTimeInterval(-week + 60), onExternalPower: true, idle: true, fileBytes: big))
        XCTAssertFalse(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: nil, onExternalPower: false, idle: true, fileBytes: big))
        XCTAssertFalse(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: nil, onExternalPower: nil, idle: true, fileBytes: big), "Unknown power is not the adapter.")
        XCTAssertFalse(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: nil, onExternalPower: true, idle: false, fileBytes: big))
        XCTAssertFalse(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: nil, onExternalPower: true, idle: true, fileBytes: 1024 * 1024))
        XCTAssertTrue(HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: now.addingTimeInterval(2 * week), onExternalPower: true, idle: true, fileBytes: big),
                      "A clock set far back cannot postpone the rewrite forever.")
    }

    func testVacuumIfDueRunsOnceAWeekAndRecordsTheRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryVacuum-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        try VersionTwoFixture.write(try SyntheticHistory.versionTwoRows(now: Date(), detailed: 12000, spacing: 60, aggregates: 0, noise: true), to: url)
        let store = try await BatteryHistoryStore.open(url: url)
        try await store.completeBackfill()
        let now = Date()
        let notIdle = try await store.vacuumIfDue(now: now, onExternalPower: true, idle: false)
        XCTAssertFalse(notIdle)
        let usage = try await store.storageUsage()
        XCTAssertGreaterThanOrEqual(usage.bytes, HistoryVacuumPolicy.minimumFileBytes, "Fixture must be above the vacuum threshold.")
        let first = try await store.vacuumIfDue(now: now, onExternalPower: true, idle: true)
        XCTAssertTrue(first)
        let second = try await store.vacuumIfDue(now: now.addingTimeInterval(3600), onExternalPower: true, idle: true)
        XCTAssertFalse(second, "At most weekly.")
        let samples = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertEqual(samples.count, 12000, "A vacuum never changes data.")
        try await store.close()
    }
}
