// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import SQLite3
@testable import PowerCore
@testable import PowerPersistence

/// A full-size store (60,000 samples: about a month of detailed rows plus hourly aggregates) with explicit time budgets.
/// Budgets are generous for local, CI-less runs on a laptop; what they guard against is the old behaviour (seconds of
/// payload decoding on the main thread), not a few milliseconds. All work is called from the main actor and must run off it.
@MainActor final class HistoryPerformanceTests: XCTestCase {
    private func seconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func liveSnapshot(at date: Date, uptime: TimeInterval, charge: Int) -> BatterySnapshot {
        let ids = ["011", "013", "015", "023", "024", "025", "026", "027", "029", "030", "031", "035", "036", "038", "039", "041", "042",
                   "043", "044", "050", "054", "055", "056", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112", "113", "115"]
        let fields = ids.map { id in
            CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(Double(charge) + Double(id.hashValue % 7)), source: "fixture",
                           keyPath: "Voltage", collectedAt: date, provenance: id == "026" ? .estimated : .measured, freshness: .fresh)
        }
        return BatterySnapshot(chargePercent: .init(value: charge, source: "fixture", collectedAt: date),
            isCharging: .init(value: true, source: "fixture", collectedAt: date), isExternalPower: .init(value: true, source: "fixture", collectedAt: date),
            collectedAt: date, catalog: fields, monotonicTime: uptime, batteryIdentityToken: "fixture-battery")
    }

    func testSixtyThousandSamplesStayOffTheMainThreadWithinBudgets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistoryPerformance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let now = Date()
        // 52,000 detailed rows 49.8 s apart (29.97 days) + 8,000 hourly aggregates before them = 60,000 samples.
        let spacing = 49.8
        try VersionTwoFixture.write(try SyntheticHistory.versionTwoRows(now: now, detailed: 52000, spacing: spacing, aggregates: 8000), to: url)

        // Migration (in place) and backfill throughput.
        var store: BatteryHistoryStore!
        let openSeconds = try await seconds { store = try await BatteryHistoryStore.open(url: url) }
        let backfillSeconds = try await seconds { try await store.completeBackfill() }
        let throughput = 60000 / backfillSeconds
        var diagnostics = await store.diagnostics()
        XCTAssertTrue(diagnostics.backfillComplete)
        XCTAssertEqual(diagnostics.sampleRows, 60000)
        let summary = try await store.summary()
        XCTAssertEqual(summary.sampleCount, 52000 + 8000 * 60)
        XCTAssertLessThan(openSeconds, 10, "Opening and migrating 60,000 rows took \(openSeconds) s.")
        XCTAssertGreaterThan(throughput, 1500, "Backfill ran at \(Int(throughput)) rows/s.")

        // An ordinary launch: the persisted summary is read, the samples are not rescanned.
        try await store.close()
        var relaunched: BatteryHistoryStore!
        let launchSeconds = try await seconds { relaunched = try await BatteryHistoryStore.open(url: url) }
        var launchSummary: HistorySummary?
        let summarySeconds = try await seconds { launchSummary = try await relaunched.summaryIfReady() }
        diagnostics = await relaunched.diagnostics()
        XCTAssertEqual(diagnostics.summaryRebuilds, 0, "A launch must not rescan the store for its summary.")
        XCTAssertEqual(launchSummary, summary)
        XCTAssertLessThan(launchSeconds, 2, "Relaunch took \(launchSeconds) s.")
        XCTAssertLessThan(summarySeconds, 0.05, "Reading the summary after launch took \(summarySeconds) s.")
        // The week the charts load: columns for old rows, payloads only for the last three hours.
        let weekSeconds = try await seconds {
            let week = try await relaunched.samples(since: now.addingTimeInterval(-7 * 86400), readingsSince: now.addingTimeInterval(-3 * 3600))
            XCTAssertEqual(week.count, Int(7 * 86400 / spacing) + 1)
        }
        XCTAssertLessThan(weekSeconds, 2, "Loading the chart week took \(weekSeconds) s.")

        // Catch-up maintenance at "now", then exactly one hour bucket expires.
        try await relaunched.maintain(referenceDate: now)
        let oldestDetailed = now.addingTimeInterval(-Double(52000 - 1) * spacing)
        let oneHourLater = oldestDetailed.addingTimeInterval(30 * 86400 + 3600)
        let maintenanceSeconds = try await seconds { try await relaunched.maintain(referenceDate: oneHourLater) }
        diagnostics = await relaunched.diagnostics()
        XCTAssertGreaterThan(diagnostics.lastAggregationRows, 0)
        XCTAssertLessThan(diagnostics.lastAggregationRows, Int(2 * 3600 / spacing) + 2, "Only the newly expired hour is read.")
        XCTAssertLessThan(maintenanceSeconds, 1, "Maintaining one expired hour took \(maintenanceSeconds) s.")
        let afterMaintenance = try await relaunched.summary()
        XCTAssertEqual(afterMaintenance.sampleCount, summary.sampleCount, "Aggregation keeps every sample's weight.")

        // record() p95 on the full store (each also updates the running summary; every 60th runs maintenance).
        var durations: [Double] = []
        for index in 0..<240 {
            let at = now.addingTimeInterval(Double(index + 1) * 60)
            let snapshot = liveSnapshot(at: at, uptime: at.timeIntervalSince1970, charge: 50 + index % 40)
            durations.append(try await seconds { try await relaunched.record(snapshot) })
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        XCTAssertLessThan(p95, 0.03, "record() p95 was \(p95) s (max \(durations.last ?? 0) s).")
        diagnostics = await relaunched.diagnostics()
        XCTAssertNil(diagnostics.lastMaintenanceError)
        XCTAssertEqual(diagnostics.mainThreadOperations, 0, "No store work may run on the main thread.")
        let rebuilt = try await relaunched.rebuiltSummary()
        let running = try await relaunched.summary()
        XCTAssertEqual(running.sampleCount, rebuilt.sampleCount)
        XCTAssertEqual(running.coveredSeconds, rebuilt.coveredSeconds, accuracy: 1e-3)
        try await relaunched.close()
        print("HISTORY-PERF open+migrate \(openSeconds)s backfill \(Int(throughput)) rows/s relaunch \(launchSeconds)s summary \(summarySeconds * 1000) ms week \(weekSeconds)s maintenance(1h) \(maintenanceSeconds * 1000) ms record p95 \(p95 * 1000) ms max \((durations.last ?? 0) * 1000) ms")
    }

    /// Over 90 % of the size budget the oldest history goes first (aggregates, then detailed days), never the last 7 days,
    /// and the cut is a labelled boundary.
    func testSizeBudgetRemovesOldestFirstAndKeepsTheLastSevenDays() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let now = Date()
        // 30 days of hourly detailed rows plus 170 days of hourly aggregates, with weakly compressible payloads: several MB.
        try VersionTwoFixture.write(try SyntheticHistory.versionTwoRows(now: now, detailed: 720, spacing: 3600, aggregates: 4080, noise: true), to: url)
        let limit: Int64 = 1024 * 1024
        let configuration = HistoryConfiguration(maximumStorageBytes: limit)
        let store = try await BatteryHistoryStore.open(url: url, configuration: configuration)
        try await store.completeBackfill()
        let before = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        let startUsage = try await store.storageUsage()
        XCTAssertGreaterThan(startUsage.bytes, 3 * limit, "Fixture must exceed the budget.")
        let protectedFrom = now.addingTimeInterval(-7 * 86400)
        let protected = Set(before.filter { $0.collectedAt >= protectedFrom }.map(\.id))

        // One run removes at most 10 % of the samples; the remainder follows with later maintenance (each record continues).
        let firstRun = try await seconds { try await store.maintain(referenceDate: now) }
        let afterFirstRun = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertGreaterThanOrEqual(afterFirstRun.count, before.count - before.count / 10, "At most 10 % per maintenance run.")
        var elapsed = firstRun
        var usage = try await store.storageUsage()
        for _ in 0..<40 where Double(usage.bytes) > 0.9 * Double(limit) {
            elapsed += try await seconds { try await store.maintain(referenceDate: now) }
            usage = try await store.storageUsage()
        }
        let after = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertLessThanOrEqual(Double(usage.bytes), 0.9 * Double(limit), "Usage after enforcement: \(usage.bytes) bytes")
        XCTAssertTrue(protected.isSubset(of: Set(after.map(\.id))), "The last 7 days are never removed.")
        let kept = Set(after.map(\.id))
        let removed = before.filter { !kept.contains($0.id) }
        XCTAssertFalse(removed.isEmpty)
        XCTAssertLessThan(removed.map(\.collectedAt).max()!, after.map(\.collectedAt).min()!, "Oldest first: what remains is a suffix.")
        XCTAssertTrue(removed.contains { $0.isAggregate } && !after.contains { $0.isAggregate }, "Aggregates go before detailed days.")
        let summary = try await store.summary()
        XCTAssertTrue(summary.gaps.contains { $0.reason == .storageLimit }, "The cut is a labelled boundary.")
        XCTAssertEqual(summary.sampleCount, after.reduce(0) { $0 + $1.aggregateCount })
        XCTAssertEqual(summary.monitoringStart, after.first?.observedFrom)
        let rebuilt = try await store.rebuiltSummary()
        XCTAssertEqual(summary.sampleCount, rebuilt.sampleCount)
        XCTAssertEqual(summary.chargingSessionCount, rebuilt.chargingSessionCount)
        XCTAssertEqual(summary.sessions.map(\.id), rebuilt.sessions.map(\.id))
        XCTAssertLessThan(elapsed, 10, "Size enforcement took \(elapsed) s.")
        let diagnostics = await store.diagnostics()
        XCTAssertEqual(diagnostics.mainThreadOperations, 0)
        try await store.close()
    }

    /// A reader holding an old snapshot blocks the WAL checkpoint, so the files stay large while the data shrinks. The
    /// budget follows pages in use, removes at most 10 % per run and stops when a step frees nothing: history is never wiped.
    func testSizeBudgetWithABlockedCheckpointNeverWipesHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySizeReader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let now = Date()
        try VersionTwoFixture.write(try SyntheticHistory.versionTwoRows(now: now, detailed: 720, spacing: 3600, aggregates: 4080, noise: true), to: url)
        let limit: Int64 = 1024 * 1024
        let store = try await BatteryHistoryStore.open(url: url, configuration: .init(maximumStorageBytes: limit))
        try await store.completeBackfill()
        let before = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        let reader = try HeldReader(url)
        for _ in 0..<3 { try await store.maintain(referenceDate: now) }
        let held = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        var budget = before.count
        for _ in 0..<3 { budget -= budget / 10 }
        XCTAssertGreaterThanOrEqual(held.count, budget - 3, "Three runs remove at most 10 % each, checkpoint or not.")
        XCTAssertLessThan(held.count, before.count, "Pages in use still fall, so trimming proceeds.")
        let blocked = try await store.storageUsage()
        reader.release()
        var usage = try await store.storageUsage()
        for _ in 0..<40 where Double(usage.bytes) > 0.9 * Double(limit) {
            try await store.maintain(referenceDate: now)
            usage = try await store.storageUsage()
        }
        XCTAssertLessThanOrEqual(Double(usage.bytes), 0.9 * Double(limit), "Released: the files shrink (\(blocked.bytes) → \(usage.bytes)).")
        let after = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertTrue(Set(before.filter { $0.collectedAt >= now.addingTimeInterval(-7 * 86400) }.map(\.id)).isSubset(of: Set(after.map(\.id))))
        try await store.close()
    }

    /// When the protected week alone exceeds the budget nothing inside it is touched.
    func testSizeBudgetNeverCutsIntoTheProtectedWeek() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroHistorySizeWeek-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("History.sqlite")
        let now = Date()
        try VersionTwoFixture.write(try SyntheticHistory.versionTwoRows(now: now, detailed: 4000, spacing: 120, aggregates: 0, noise: true), to: url)
        let store = try await BatteryHistoryStore.open(url: url, configuration: .init(maximumStorageBytes: 1024 * 1024))
        try await store.completeBackfill()
        let before = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        try await store.maintain(referenceDate: now)
        let after = try await store.samples(limit: 100000, readingsSince: .distantFuture)
        XCTAssertEqual(after.map(\.id), before.map(\.id), "All rows are inside the protected 7 days.")
        let summary = try await store.summary()
        XCTAssertFalse(summary.gaps.contains { $0.reason == .storageLimit })
        try await store.close()
    }
}

/// A second connection that keeps a read transaction open, as another process reading the file would.
private final class HeldReader {
    private var db: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw HistoryStoreError.unavailable }
        guard sqlite3_exec(db, "BEGIN; SELECT count(*) FROM ZHISTORYRECORD;", nil, nil, nil) == SQLITE_OK else { throw HistoryStoreError.unavailable }
    }
    func release() {
        guard let db else { return }
        sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db); self.db = nil
    }
    deinit { release() }
}
