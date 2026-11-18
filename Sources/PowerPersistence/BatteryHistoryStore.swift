// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreData
import PowerCore

/// The local battery history. Every fetch, decode and write runs on the store's private Core Data queue, never on the
/// caller's thread (2026-11-05: decoding the history on the main actor froze the UI and drew "high energy" notices);
/// only immutable values cross this boundary. Calls are serialised in the order they are made.
///
/// Opening is synchronous for tools and tests; the app uses `open(url:)`, which runs migration and the first loads off
/// the main thread. A store migrated from schema version 2 backfills its scalar columns in batches (`completeBackfill`);
/// until then `summaryIfReady()` reports nothing rather than a partial or zero summary.
public final class BatteryHistoryStore: @unchecked Sendable {
    private let core: HistoryStoreCore
    private let context: NSManagedObjectContext
    public let url: URL?
    public let retentionDays: Int

    public init(url: URL?, configuration: HistoryConfiguration = .init()) throws {
        core = try HistoryStoreCore(url: url, configuration: configuration)
        context = core.context
        self.url = url
        retentionDays = configuration.retentionDays
    }

    /// Opens (and if needed migrates) the store off the calling actor.
    public static func open(url: URL?, configuration: HistoryConfiguration = .init()) async throws -> BatteryHistoryStore {
        try await Task.detached(priority: .utility) { try BatteryHistoryStore(url: url, configuration: configuration) }.value
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (HistoryStoreCore) throws -> T) async throws -> T {
        let core = self.core
        return try await context.perform {
            if Thread.isMainThread { core.mainThreadOperations += 1 }
            return try body(core)
        }
    }

    // MARK: Recording

    public func record(_ snapshot: BatterySnapshot) async throws { try await run { try $0.record(snapshot) } }
    public func markGap(reason: HistoryGapReason, at: Date = Date()) async throws { try await run { try $0.markGap(reason: reason, at: at) } }
    public func markGap(_ reason: HistoryGapReason, at: Date = Date()) async throws { try await markGap(reason: reason, at: at) }

    // MARK: Reading

    /// `readingsSince` keeps the full catalog only for samples at or after that date; older ones carry scalars only.
    public func samples(since: Date? = nil, limit: Int = 20000, readingsSince: Date? = nil) async throws -> [HistorySample] {
        try await run { try $0.samples(since: since, limit: limit, readingsSince: readingsSince) }
    }

    public func weeklyCapacity(for snapshot: BatterySnapshot, at now: Date = Date(), calendar: Calendar = .current) async throws -> WeeklyCapacity? {
        try await run { try $0.weeklyCapacity(for: snapshot, at: now, calendar: calendar) }
    }

    /// The summary of all retained history; finishes a pending column backfill first.
    public func summary() async throws -> HistorySummary {
        try await run { core in
            guard let summary = try core.summary(waitForBackfill: true) else { throw HistoryStoreError.unavailable }
            return summary
        }
    }

    /// The running summary, or nil while a migrated store is still backfilling (never a partial or zero summary).
    public func summaryIfReady() async throws -> HistorySummary? { try await run { try $0.summary(waitForBackfill: false) } }

    /// `summaryMaxAge` lets a frequent caller reuse a recent summary. With `waitForBackfill: false` a store that is still
    /// backfilling returns no rows, so those catalog fields stay unavailable instead of showing a partial count.
    public func catalogReadings(at date: Date = Date(), summaryMaxAge: TimeInterval = 0, waitForBackfill: Bool = true) async throws -> [CatalogReading] {
        try await run { try $0.catalogReadings(at: date, summaryMaxAge: summaryMaxAge, waitForBackfill: waitForBackfill) }
    }

    // MARK: Sleep reports

    public func upsertSleepSession(_ record: SleepSessionRecord) async throws { try await run { try $0.upsertSleepSession(record) } }
    /// A pure read of the reports inside the detailed-history period (pruning happens in maintenance).
    public func sleepSessions(limit: Int = 2000) async throws -> [SleepSessionRecord] { try await run { try $0.sleepSessions(limit: limit) } }

    // MARK: Maintenance

    public func configureRetention(_ days: Int) async throws { try await run { try $0.configureRetention(days) } }
    public func maintain(referenceDate: Date = Date()) async throws { try await run { try $0.maintain(referenceDate: referenceDate) } }

    /// Backfills version-2 rows in small batches, each its own queue turn, so recording and reads interleave with it.
    public func completeBackfill(batchSize: Int = 1000) async throws {
        while try await run({ try $0.backfill(limit: batchSize) }) == false {}
    }

    public func storageUsage() async throws -> HistoryStorageUsage { try await run { try $0.storageUsage() } }

    /// Runs a full VACUUM when `HistoryVacuumPolicy` allows it (weekly at most, idle, on external power).
    @discardableResult
    public func vacuumIfDue(now: Date = Date(), onExternalPower: Bool?, idle: Bool) async throws -> Bool {
        try await run { try $0.vacuumIfDue(now: now, onExternalPower: onExternalPower, idle: idle) }
    }

    public func erase() async throws { try await run { try $0.erase() } }

    public func close() async throws { try await run { try $0.close() } }

    /// For application termination only: writes the final sleep reports and closes, blocking the caller until the
    /// queue has finished earlier work. Everything else goes through the asynchronous API.
    public func closeImmediately(upserting records: [SleepSessionRecord]) throws {
        let core = self.core
        try context.performAndWait {
            var failure: Error?
            for record in records {
                do { try core.upsertSleepSession(record) } catch { failure = failure ?? error }
            }
            try core.close()
            if let failure { throw failure }
        }
    }

    // MARK: Export (payload-based, off the caller's thread)

    public func exportJSON() async throws -> Data { try await run { try $0.exportJSON() } }
    public func exportCSV() async throws -> Data { try await run { try $0.exportCSV() } }

    public func diagnostics() async -> HistoryStoreDiagnostics {
        (try? await run { $0.diagnostics() }) ?? HistoryStoreDiagnostics(mainThreadOperations: 0, summaryRebuilds: 0, backfillComplete: false,
            corruptRows: 0, sampleRows: 0, lastAggregationRows: 0, lastMaintenanceError: nil)
    }

    // MARK: Test hooks (internal)

    /// One backfill batch, as the background loop runs it (resumability tests).
    func backfillOnce(limit: Int) async throws -> Bool { try await run { try $0.backfill(limit: limit) } }

    /// The summary a full rescan of the retained samples gives, to compare with the running one.
    func rebuiltSummary() async throws -> HistorySummary {
        try await run { core in
            try core.rebuildSummary()
            guard let summary = try core.summary(waitForBackfill: true) else { throw HistoryStoreError.unavailable }
            return summary
        }
    }

    // MARK: Files

    /// Copies a consistent SQLite/WAL snapshot through Core Data without opening the source writable.
    /// The destination is new, private and detached; its standalone SQLite file can be promoted atomically.
    public static func copyForPrototypeMigration(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path) else { throw HistoryStoreError.unavailable }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: source, options: [NSReadOnlyPersistentStoreOption: true])
        guard let version = HistorySchema.compatibleVersion(metadata) else { throw HistoryStoreError.unsupportedSchema }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model(version: version))
        try coordinator.replacePersistentStore(at: destination,
            destinationOptions: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]],
            withPersistentStoreFrom: source, sourceOptions: [NSReadOnlyPersistentStoreOption: true], ofType: NSSQLiteStoreType)
        // Upgrade only the private copy before its stable identity enters the migration journal.
        let copy = try HistoryStoreCore(url: destination, configuration: .init())
        try copy.context.performAndWait { try copy.close() }
        // Opening only the copy with DELETE consolidates any copied WAL before a single-file promotion.
        let detachedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model(version: HistorySchema.currentVersion))
        let detached = try detachedCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: destination, options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        try detachedCoordinator.remove(detached)
        guard !FileManager.default.fileExists(atPath: destination.path + "-wal") else { throw HistoryStoreError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static func persistentStoreIdentifier(at url: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
            at: url, options: [NSReadOnlyPersistentStoreOption: true])
        guard let identifier = metadata[NSStoreUUIDKey] as? String else { throw HistoryStoreError.unavailable }
        return identifier
    }

    public static let currentSchemaVersion = HistorySchema.currentVersion

    /// Versions 1 and 2 are retained for real migration fixtures, never used for a new production store.
    static func model(version: Int) -> NSManagedObjectModel { HistorySchema.model(version: version) }
}
