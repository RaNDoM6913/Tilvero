// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreData
import Synchronization
import PowerCore

/// Set when the store is closing for termination: long work (export, backfill, rebuild, size trims, VACUUM) stops at
/// its next batch boundary so the final close is not held up behind it.
final class HistoryInterruption: Sendable {
    private let flag = Atomic<Bool>(false)
    var isRequested: Bool { flag.load(ordering: .acquiring) }
    func request() { flag.store(true, ordering: .releasing) }
}

/// Diagnostics a test or the app can read without touching Core Data objects.
public struct HistoryStoreDiagnostics: Sendable, Equatable {
    /// Store operations that ran on the main thread (the app opens and calls the store off it: expected 0).
    public let mainThreadOperations: Int
    /// Full summary rebuilds (sample scans) since the store opened; a launch with a current summary needs none.
    public let summaryRebuilds: Int
    public let backfillComplete: Bool
    /// Sample and gap rows whose payload could not be decoded; they stay on disk and keep summaries unavailable.
    public let corruptRows: Int
    public let sampleRows: Int
    /// Sample rows the last maintenance read to aggregate expired hours.
    public let lastAggregationRows: Int
    public let lastMaintenanceError: String?
}

/// All Core Data work of the history store. Confined to `context`'s private queue: `BatteryHistoryStore` calls it only
/// inside `perform`/`performAndWait`, and only immutable values leave it. `@unchecked Sendable` states that confinement.
final class HistoryStoreCore: @unchecked Sendable {
    let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext
    let url: URL?
    /// Where the SQLite file lives: `url`, or a private temporary file for an ephemeral (url == nil) store.
    let fileURL: URL
    private let ephemeralDirectory: URL?
    private(set) var configuration: HistoryConfiguration
    private var sleepRetentionDays: Int
    private var latest: HistorySample?
    private var latestIdentity: String?
    private var sequence: Int64 = 0
    private var needsLaunchBoundary = true
    private var pendingGap: (HistoryGapReason, Date)?
    private(set) var closed = false
    private var writesSinceMaintenance = 0
    private var maintenanceBacklog = false
    private var sampleRows = 0
    private var corruptRows = 0
    private(set) var backfillComplete = false
    /// nil while columns are being backfilled or the persisted state must be rebuilt.
    private var state: HistorySummaryState?
    private var gaps: [HistoryGap] = []
    private var closedSessions: [HistorySession] = []
    private var weeklyCapacityMiss: (identity: String, start: Date)?
    private var cycleBaseline: (segment: UUID, initial: Int?, checkedSequence: Int64)?
    private var catalogSummary: (summary: HistorySummary, series: [String: HistorySummaryState.Series], at: Date)?
    private var lastAggregationRows = 0
    private var lastMaintenanceError: String?
    var mainThreadOperations = 0
    private var summaryRebuilds = 0

    static let weeklyCapacityKind = "weekly-capacity-v1"
    static let stateKind = "summary-state-v1"
    static let sessionKind = "session"
    private static let maintenanceRowBudget = 20000
    private static let sleepRowLimit = 2000

    /// Set by the facade when the store closes for termination; long work stops at its next batch boundary.
    let interruption: HistoryInterruption

    init(url: URL?, configuration: HistoryConfiguration, interruption: HistoryInterruption = HistoryInterruption(),
         makesMigrationBackup: Bool = true) throws {
        self.url = url; self.configuration = configuration; self.interruption = interruption
        sleepRetentionDays = max(1, configuration.detailedDays)
        if let url { fileURL = url; ephemeralDirectory = nil }
        else {
            // An ephemeral store is a private SQLite file, so it behaves exactly like the real one (batch work, pragmas).
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroEphemeralHistory-\(UUID().uuidString)")
            ephemeralDirectory = directory; fileURL = directory.appendingPathComponent("History.sqlite")
        }
        let model = HistorySchema.model(version: HistorySchema.currentVersion)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        noteThread()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var options: [String: Any] = [NSSQLitePragmasOption: ["journal_mode": "WAL", "auto_vacuum": "INCREMENTAL"]]
            if url != nil { HistoryMigrationBackup.removeExpired(for: fileURL) }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: fileURL)
                if HistorySchema.declaresNewerVersion(metadata) { throw HistoryStoreError.unsupportedSchema }
                guard let version = HistorySchema.compatibleVersion(metadata) else { throw HistoryStoreError.unsupportedSchema }
                if version < HistorySchema.currentVersion {
                    // A rollback to the previous app needs the old schema: back it up first, or do not migrate now.
                    if url != nil, makesMigrationBackup { try HistoryMigrationBackup.ensure(for: fileURL, version: version) }
                    options[NSMigratePersistentStoresAutomaticallyOption] = true
                    options[NSInferMappingModelAutomaticallyOption] = true
                    options[NSPersistentStoreStagedMigrationManagerOptionKey] = HistorySchema.stagedMigrationManager()
                }
                // Core Data creates stores with incremental auto-vacuum; convert one that predates that, once.
                if let mode = HistorySQLiteFile.autoVacuumMode(fileURL), mode != 2 { HistorySQLiteFile.vacuum(fileURL) }
            }
            _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: fileURL, options: options)
            try context.performAndWait { try loadAfterOpen() }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as HistoryStoreError { removeEphemeralFiles(); throw error }
        catch { removeEphemeralFiles(); throw HistoryStoreError.unavailable }
    }

    deinit { removeEphemeralFiles() }

    /// Counts store work that ran on the main thread. Called at the entry of every operation, wherever it executes
    /// (the synchronous open and the termination close run on their caller's thread; everything else on the queue).
    func noteThread() { if Thread.isMainThread { mainThreadOperations += 1 } }

    private func checkInterruption() throws { if interruption.isRequested { throw HistoryStoreError.unavailable } }

    private func removeEphemeralFiles() {
        if let ephemeralDirectory { try? FileManager.default.removeItem(at: ephemeralDirectory) }
    }

    // MARK: - Opening

    private func loadAfterOpen() throws {
        sequence = try objects(nil, sort: "sequence", ascending: false, limit: 1).first?.value(forKey: "sequence") as? Int64 ?? 0
        if let newest = try objects(kind("sample"), sort: "sequence", ascending: false, limit: 1).first {
            // A damaged newest row only starts a new segment; the row itself stays flagged for summaries and charts.
            latest = try? decode(HistorySample.self, object: newest)
            latestIdentity = newest.value(forKey: "identityToken") as? String
        }
        sampleRows = try count(kind("sample"))
        backfillComplete = try count(NSPredicate(format: "columnsVersion == %d", HistorySchema.Columns.pending)) == 0
        corruptRows = try countCorrupt()
        context.reset()
        guard backfillComplete else { return }
        if let saved = try loadState(), try saved.lastSequence == newestValidSampleSequence() {
            state = saved
            try reloadGapsAndSessions()
        } else {
            try rebuildSummary()
        }
    }

    private func countCorrupt() throws -> Int {
        try count(NSPredicate(format: "columnsVersion == %d AND (kind == %@ OR kind == %@)", HistorySchema.Columns.corrupt, "sample", "gap"))
    }

    private func newestValidSampleSequence() throws -> Int64 {
        let request = dictionaryRequest(NSPredicate(format: "kind == %@ AND columnsVersion == %d", "sample", HistorySchema.Columns.valid),
                                        keys: ["sequence"], sort: "sequence", ascending: false, limit: 1)
        return (try context.fetch(request).first?["sequence"] as? NSNumber)?.int64Value ?? 0
    }

    private func loadState() throws -> HistorySummaryState? {
        guard let object = try objects(kind(Self.stateKind), sort: "sequence", ascending: true, limit: 1).first,
              let state = try? decode(HistorySummaryState.self, object: object),
              state.version == HistorySummaryState.currentVersion else { return nil }
        return state
    }

    // MARK: - Backfill (version 2 → 3)

    /// Fills the scalar columns of up to `limit` version-2 rows from their payloads. Idempotent and resumable: a row is
    /// selected only while `columnsVersion` is 0. Returns true once nothing is left (and the summary is current).
    func backfill(limit: Int) throws -> Bool {
        try ensureOpen(); try checkInterruption()
        if backfillComplete { if state == nil { try rebuildSummary() }; return true }
        let pending = try objects(NSPredicate(format: "columnsVersion == %d", HistorySchema.Columns.pending), sort: "sequence",
                                  ascending: true, limit: max(1, limit))
        do {
            for object in pending {
                autoreleasepool {
                    let kind = object.value(forKey: "kind") as? String
                    switch kind {
                    case "sample":
                        if let sample = try? decode(HistorySample.self, object: object) { writeColumns(sample, to: object) }
                        else { object.setValue(HistorySchema.Columns.corrupt, forKey: "columnsVersion") }
                    case "gap":
                        if let gap = try? decode(HistoryGap.self, object: object) { writeColumns(gap, to: object) }
                        else { object.setValue(HistorySchema.Columns.corrupt, forKey: "columnsVersion") }
                    case "sleep":
                        object.setValue(validatedSleep(object) == nil ? HistorySchema.Columns.corrupt : HistorySchema.Columns.valid,
                                        forKey: "columnsVersion")
                    default:
                        object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
                    }
                }
            }
            if context.hasChanges { try context.save() }
            context.reset()
        } catch { context.rollback(); throw clean(error) }
        guard pending.count < max(1, limit) else { return false }
        backfillComplete = true
        corruptRows = try countCorrupt()
        try rebuildSummary()
        return true
    }

    func completeBackfill() throws { while try !backfill(limit: 1000) {} }

    // MARK: - Recording

    func record(_ snapshot: BatterySnapshot) throws {
        try ensureOpen()
        guard !snapshot.isDemo else { throw HistoryStoreError.simulationExcluded }
        let at = snapshot.collectedAt
        let previous = latest
        let numeric: (String) -> Double? = { id in
            guard let r = snapshot.catalog.first(where: { $0.id == id }), r.availability == .available, r.freshness != .stale,
                  let value = r.value?.doubleValue, value.isFinite else { return nil }
            return value
        }
        let charge = numeric("011") ?? Self.valid(snapshot.chargePercent).map(Double.init)
        var reason: HistoryGapReason?
        let previousValid = previous?.chargePercent != nil
        let currentIdentity = snapshot.batteryIdentityToken
        var elapsed: TimeInterval = 0
        if let previous {
            let wallDelta = at.timeIntervalSince(previous.collectedAt)
            let monoDelta = snapshot.monotonicTime.flatMap { current in previous.monotonicTime.map { current - $0 } }
            elapsed = monoDelta ?? wallDelta
            if let pendingGap { reason = pendingGap.0 }
            else if needsLaunchBoundary { reason = .launch }
            else if currentIdentity != latestIdentity { reason = .batteryReplacement }
            else if elapsed <= 0 || wallDelta <= 0 || (monoDelta != nil && abs(wallDelta - elapsed) > 5) { reason = .clockChange }
            else if elapsed > configuration.maximumGapSeconds { reason = .offline }
            else if charge == nil || !previousValid { reason = .providerUnavailable }
        }
        let segment = reason != nil ? UUID() : previous?.segmentID ?? UUID()
        let gap: HistoryGap? = previous.flatMap { previous in
            guard let reason else { return nil }
            let gapStart = pendingGap?.1 ?? previous.collectedAt
            return HistoryGap(start: min(gapStart, at), end: max(gapStart, at), reason: reason)
        }
        let contiguous = previous != nil && reason == nil && elapsed > 0 && elapsed <= configuration.maximumGapSeconds
        let power = numeric("038")
        let previousPower = previous?.batteryPowerWatts
        // Only fresh measured/qualified estimated power can contribute energy. Missing is never zero.
        let powerFresh = snapshot.catalog.first { $0.id == "038" }?.freshness == .fresh
        let previousPowerFresh = previous?.readings.first { $0.id == "038" }?.freshness == .fresh
        let energy: Double? = contiguous && powerFresh && previousPowerFresh && power != nil && previousPower != nil
            ? (power! + previousPower!) * 0.5 * elapsed / 3600 : nil
        let external = Self.valid(snapshot.isExternalPower)
        let historyIDs: Set<String> = ["011", "013", "015", "023", "024", "025", "026", "027", "029", "030", "031", "035", "036", "038", "039", "041", "042", "043", "044", "050", "054", "055", "056", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112", "113", "115"]
        let safeReadings = snapshot.catalog.filter { $0.privacy == .operational && historyIDs.contains($0.id) }.map(Self.redactedReading)
        let sample = HistorySample(id: UUID(), collectedAt: at, monotonicTime: snapshot.monotonicTime,
            timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: at), segmentID: segment,
            chargePercent: charge, temperatureCelsius: numeric("039") ?? Self.valid(snapshot.temperatureCelsius),
            batteryPowerWatts: power, capacityRetentionPercent: numeric("026"), cycleCount: Self.valid(snapshot.cycleCount),
            isCharging: Self.valid(snapshot.isCharging), isExternalPower: external, isAggregate: false, aggregateCount: 1,
            readings: safeReadings, observedFrom: at, coveredSeconds: contiguous ? elapsed : 0,
            energyEvidenceVersion: 1, chargedWh: energy.map { max(0, $0) }, dischargedWh: energy.map { max(0, -$0) },
            externalPowerSeconds: contiguous && external == true && previous?.isExternalPower == true ? elapsed : 0)
        let previousSequence = sequence
        do {
            if let gap { try insert(gap, at: at) }
            let object = try insert(sample, kind: "sample", at: at, identity: currentIdentity)
            writeColumns(sample, to: object)
            var nextState = state
            var closed: [HistorySession] = []
            if var folded = nextState {
                closed = folded.fold(HistoryScalars(sample, sequence: sequence))
                for session in closed { insertSession(session) }
                nextState = folded
                try writeState(folded)
            }
            try context.save()
            context.reset()
            state = nextState
            if let gap { gaps.append(gap); if gaps.count > 1000 { gaps.removeFirst(gaps.count - 1000) } }
            closedSessions += closed
            if closedSessions.count > 1000 { closedSessions.removeFirst(closedSessions.count - 1000) }
            latest = sample; latestIdentity = currentIdentity; pendingGap = nil; needsLaunchBoundary = false
            sampleRows += 1
        } catch { context.rollback(); sequence = previousSequence; throw clean(error) }
        writesSinceMaintenance += 1
        if writesSinceMaintenance >= 60 || sampleRows > configuration.maximumSamples || maintenanceBacklog {
            writesSinceMaintenance = 0
            // The sample is already saved: a failed maintenance step is retried with the next record, never loses it.
            do { try maintain(referenceDate: at); lastMaintenanceError = nil }
            catch { context.rollback(); context.reset(); lastMaintenanceError = String(describing: error); maintenanceBacklog = true }
        }
    }

    func markGap(reason: HistoryGapReason, at: Date) throws { try ensureOpen(); pendingGap = (reason, at) }

    // MARK: - Reading

    /// `readingsSince` keeps the full catalog only for samples at or after that date; older ones carry scalars only and
    /// are built from columns without touching their payloads.
    func samples(since: Date?, limit: Int, readingsSince: Date?) throws -> [HistorySample] {
        try ensureOpen()
        do {
            var predicate = kind("sample")
            if let since { predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, NSPredicate(format: "atDate >= %@", since as NSDate)]) }
            let rows = try context.fetch(dictionaryRequest(predicate, keys: Self.sampleKeys, sort: "sequence", ascending: false,
                                                           limit: min(100000, max(1, limit)), objectID: true)).reversed()
            guard !rows.contains(where: { Self.int16($0["columnsVersion"]) == HistorySchema.Columns.corrupt }) else {
                throw HistoryStoreError.corruptRecord
            }
            let needsPayload = rows.filter { row in
                Self.int16(row["columnsVersion"]) != HistorySchema.Columns.valid
                    || readingsSince.map { cutoff in (row["atDate"] as? Date).map { $0 >= cutoff } ?? true } ?? true
            }.compactMap { $0["objectID"] as? NSManagedObjectID }
            var decoded: [NSManagedObjectID: HistorySample] = [:]
            if !needsPayload.isEmpty {
                for chunk in stride(from: 0, to: needsPayload.count, by: 500).map({ Array(needsPayload[$0..<min($0 + 500, needsPayload.count)]) }) {
                    try checkInterruption()
                    let request = NSFetchRequest<NSManagedObject>(entityName: HistorySchema.entityName)
                    request.predicate = NSPredicate(format: "self IN %@", chunk)
                    for object in try context.fetch(request) {
                        try autoreleasepool {
                            let light = readingsSince.map { cutoff in (object.value(forKey: "atDate") as? Date).map { $0 < cutoff } ?? false } ?? false
                            decoded[object.objectID] = try decode(HistorySample.self, object: object, light: light)
                        }
                    }
                    context.reset()
                }
            }
            return try rows.map { row in
                if let id = row["objectID"] as? NSManagedObjectID, let sample = decoded[id] { return sample }
                guard let sample = Self.sample(fromColumns: row) else { throw HistoryStoreError.corruptRecord }
                return sample
            }
        } catch { context.reset(); throw clean(error) }
    }

    /// Uses the existing private record identity, across launch and sleep segments.
    /// Only the frozen aggregate leaves the store, with no token or raw telemetry.
    func weeklyCapacity(for snapshot: BatterySnapshot, at now: Date, calendar: Calendar) throws -> WeeklyCapacity? {
        try ensureOpen()
        guard !snapshot.isDemo, let identity = snapshot.batteryIdentityToken, !identity.isEmpty,
              let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else { return nil }
        defer { context.reset() }
        let publications = try objects(kind(Self.weeklyCapacityKind), sort: "sequence", ascending: false, limit: 0)
        if let saved = publications.first, saved.value(forKey: "identityToken") as? String == identity {
            let result = try decode(WeeklyCapacity.self, object: saved)
            guard result.percent.isFinite, result.percent > 0, (1...7).contains(result.observedDays),
                  result.firstObservedAt <= result.lastObservedAt, result.lastObservedAt <= result.publishedAt else {
                throw HistoryStoreError.corruptRecord
            }
            guard result.publishedAt <= now else { return nil }
            if now < result.nextEligibleAt { return result }
        }

        if weeklyCapacityMiss?.identity == identity, weeklyCapacityMiss?.start == start,
           Self.capacityEstimate(snapshot.catalog.first { $0.id == "026" }) == nil { return nil }

        let predicate = NSPredicate(format: "kind == %@ AND identityToken == %@ AND atDate >= %@ AND atDate <= %@",
                                    "sample", identity, start as NSDate, now as NSDate)
        let rows = try context.fetch(dictionaryRequest(predicate, keys: ["atDate", "capacityEstimate", "isAggregate", "columnsVersion"],
                                                       sort: "sequence", ascending: true, limit: 0, objectID: true))
        var byDay: [Date: [Double]] = [:]
        var first: Date?, last: Date?
        for row in rows {
            let observation: (Date, Double)?
            switch Self.int16(row["columnsVersion"]) {
            case HistorySchema.Columns.valid:
                guard (row["isAggregate"] as? Bool) != true, let date = row["atDate"] as? Date,
                      let estimate = (row["capacityEstimate"] as? NSNumber)?.doubleValue else { continue }
                observation = (date, estimate)
            case HistorySchema.Columns.pending:
                // Not backfilled yet: this one row is still read from its payload.
                guard let id = row["objectID"] as? NSManagedObjectID else { continue }
                let sample = try decode(HistorySample.self, object: context.object(with: id))
                observation = sample.isAggregate ? nil : Self.capacityEstimate(sample.readings.first { $0.id == "026" }).map { (sample.collectedAt, $0) }
            default:
                throw HistoryStoreError.corruptRecord
            }
            guard let (date, estimate) = observation else { continue }
            byDay[calendar.startOfDay(for: date), default: []].append(estimate)
            first = min(first ?? date, date); last = max(last ?? date, date)
        }
        guard let first, let last else { weeklyCapacityMiss = (identity, start); return nil }
        let result = WeeklyCapacity(percent: Self.median(byDay.values.map(Self.median)), observedDays: byDay.count,
                                    firstObservedAt: first, lastObservedAt: last, publishedAt: now)
        let previousSequence = sequence
        do {
            for publication in publications { context.delete(publication) }
            let object = try insert(result, kind: Self.weeklyCapacityKind, at: now, identity: identity)
            object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
            try context.save()
            weeklyCapacityMiss = nil
            return result
        } catch {
            context.rollback(); sequence = previousSequence
            throw clean(error)
        }
    }

    // MARK: - Summary

    /// The running summary. Throws while flagged rows exist: a preserved corrupt record is never summarised as empty.
    func summary(waitForBackfill: Bool) throws -> HistorySummary? {
        try ensureOpen()
        if state == nil {
            guard waitForBackfill else { return nil }
            try completeBackfill()
        }
        guard corruptRows == 0 else { throw HistoryStoreError.corruptRecord }
        guard let state else { throw HistoryStoreError.unavailable }
        return state.summary(gaps: gaps, closed: closedSessions)
    }

    /// Folds every retained sample from an empty state (columns only, batched). Used after migration, erase or when the
    /// persisted state is missing or stale; never on an ordinary launch.
    func rebuildSummary() throws {
        summaryRebuilds += 1
        var rebuilt = HistorySummaryState()
        rebuilt.aggregatedThrough = state?.aggregatedThrough
        rebuilt.lastFullVacuum = state?.lastFullVacuum
        if state == nil, let saved = try? loadState() {
            rebuilt.aggregatedThrough = saved.aggregatedThrough; rebuilt.lastFullVacuum = saved.lastFullVacuum
        }
        var closed: [HistorySession] = []
        var after: Int64 = Int64.min
        while true {
            try checkInterruption()
            let predicate = NSPredicate(format: "kind == %@ AND columnsVersion == %d AND sequence > %lld", "sample", HistorySchema.Columns.valid, after)
            let rows = try context.fetch(dictionaryRequest(predicate, keys: Self.sampleKeys, sort: "sequence", ascending: true, limit: 5000))
            for row in rows { if let scalars = Self.scalars(fromColumns: row) { closed += rebuilt.fold(scalars) } }
            guard let last = rows.last, rows.count == 5000 else { break }
            after = (last["sequence"] as? NSNumber)?.int64Value ?? after
        }
        do {
            for object in try objects(kind(Self.sessionKind), sort: "sequence", ascending: true, limit: 0) { context.delete(object) }
            for session in closed { insertSession(session) }
            try writeState(rebuilt)
            try context.save()
            context.reset()
        } catch { context.rollback(); throw clean(error) }
        state = rebuilt
        try reloadGapsAndSessions()
    }

    private func reloadGapsAndSessions() throws {
        let gapRows = try context.fetch(dictionaryRequest(NSPredicate(format: "kind == %@ AND columnsVersion == %d", "gap", HistorySchema.Columns.valid),
            keys: ["id", "observedFrom", "endDate", "label"], sort: "sequence", ascending: false, limit: 1000))
        gaps = gapRows.reversed().compactMap(Self.gap(fromColumns:))
        let sessionRows = try context.fetch(dictionaryRequest(kind(Self.sessionKind),
            keys: ["id", "observedFrom", "endDate", "label", "segmentID", "startKnown"], sort: "sequence", ascending: false, limit: 1000))
        closedSessions = sessionRows.reversed().compactMap(Self.session(fromColumns:))
    }

    func catalogReadings(at date: Date, summaryMaxAge: TimeInterval, waitForBackfill: Bool) throws -> [CatalogReading] {
        try ensureOpen()
        let summary: HistorySummary
        let seriesCache: [String: HistorySummaryState.Series]
        if summaryMaxAge > 0, let cached = catalogSummary, date >= cached.at, date.timeIntervalSince(cached.at) < summaryMaxAge {
            summary = cached.summary; seriesCache = cached.series
        } else {
            guard let current = try self.summary(waitForBackfill: waitForBackfill) else { return [] }
            summary = current; seriesCache = state?.series ?? [:]
            catalogSummary = (summary, seriesCache, date)
        }
        func reading(_ id: String, _ value: CatalogValue?, reason: String? = nil, provenance: TelemetryProvenance = .recorded) -> CatalogReading {
            CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: "PowerPersistence", keyPath: "localHistory/\(id)", collectedAt: date, provenance: provenance, freshness: .fresh, reason: reason)
        }
        var fields = [reading("077", summary.monitoringStart.map(CatalogValue.date)),
            reading("083", .integer(Int64(summary.chargingSessionCount))), reading("084", .decimal(summary.observedExternalPowerSeconds)),
            reading("085", summary.estimatedChargedWh.flatMap { charged in summary.estimatedDischargedWh.map { .object(["chargedWh": .decimal(charged), "dischargedWh": .decimal($0)]) } }, reason: summary.estimatedChargedWh == nil ? "No qualified power integration intervals were observed." : nil, provenance: .estimated),
            reading("086", .object(["coveredSeconds": .decimal(summary.coveredSeconds), "gaps": .integer(Int64(summary.gaps.count))]))]
        for id in ["078", "079", "080", "081"] {
            let series = seriesCache[id]
            fields.append(reading(id, series.map { .object(["sampleCount": .integer(Int64($0.count)), "latest": .decimal($0.latest)]) },
                reason: series == nil ? "No qualified values have been recorded for this series." : "Retained points include labelled aggregates and explicit segment boundaries."))
        }
        if let last = latest, let final = last.cycleCount {
            let initial: Int?
            if let cached = cycleBaseline, cached.segment == last.segmentID, cached.initial != nil || cached.checkedSequence == sequence {
                initial = cached.initial
            } else {
                let predicate = NSPredicate(format: "kind == %@ AND segmentID == %@ AND cycleCount != nil AND columnsVersion == %d",
                                            "sample", last.segmentID as CVarArg, HistorySchema.Columns.valid)
                let row = try context.fetch(dictionaryRequest(predicate, keys: ["cycleCount"], sort: "sequence", ascending: true, limit: 1)).first
                initial = (row?["cycleCount"] as? NSNumber)?.intValue
                cycleBaseline = (last.segmentID, initial, sequence)
            }
            if let initial, final >= initial { fields.append(reading("082", .integer(Int64(final - initial)))) }
        }
        let sessions = summary.sessions
        if let session = sessions.last(where: { $0.kind == "externalPower" && $0.endedAt == nil && $0.originalStartKnown }) { fields.append(reading("072", .date(session.observedFrom))) }
        if let session = sessions.last(where: { $0.kind == "onBattery" && $0.endedAt == nil && $0.originalStartKnown }) { fields.append(reading("073", .date(session.observedFrom))) }
        if let session = sessions.last(where: { $0.kind == "charging" && $0.endedAt == nil && $0.originalStartKnown }), let last = latest { fields.append(reading("074", .decimal(max(0, last.collectedAt.timeIntervalSince(session.observedFrom))))) }
        return fields
    }

    // MARK: - Sleep reports

    private struct SleepPayload: Codable { let version: Int; let record: SleepSessionRecord }

    /// Updates one stable observation row. Assertions and process details never enter this payload.
    func upsertSleepSession(_ record: SleepSessionRecord) throws {
        try ensureOpen()
        guard record.isValidForPersistence, let at = record.observedAt else { throw HistoryStoreError.corruptRecord }
        let previousSequence = sequence
        do {
            // Fail closed before changing anything if a future/corrupt sleep codec is present.
            try ensureSleepRowsValid()
            let encoded = try JSONEncoder().encode(SleepPayload(version: 1, record: record))
            guard encoded.count <= 131072 else { throw HistoryStoreError.corruptRecord }
            let match = NSPredicate(format: "kind == %@ AND id == %@", "sleep", record.id as CVarArg)
            let object: NSManagedObject
            if let existing = try objects(match, sort: "sequence", ascending: true, limit: 1).first { object = existing }
            else {
                object = NSEntityDescription.insertNewObject(forEntityName: HistorySchema.entityName, into: context)
                sequence += 1
                object.setValue(record.id, forKey: "id"); object.setValue("sleep", forKey: "kind")
                object.setValue(sequence, forKey: "sequence")
            }
            object.setValue(at, forKey: "atDate")
            object.setValue(try (encoded as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
            object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
            try pruneSleepRows(referenceDate: Date(), failClosed: true)
            try context.save()
            context.reset()
        } catch { context.rollback(); sequence = previousSequence; throw clean(error) }
    }

    /// A pure read: rows outside the selected period are filtered here and removed by maintenance.
    func sleepSessions(limit: Int) throws -> [SleepSessionRecord] {
        try ensureOpen()
        defer { context.reset() }
        do {
            try ensureSleepRowsValid()
            guard limit > 0 else { return [] }
            let cutoff = Date().addingTimeInterval(-Double(sleepRetentionDays) * 86400)
            let rows = try objects(NSPredicate(format: "kind == %@ AND atDate >= %@", "sleep", cutoff as NSDate), sort: "sequence",
                                   ascending: false, limit: min(Self.sleepRowLimit, limit))
            return try rows.reversed().map { object in
                guard let record = validatedSleep(object) else { throw HistoryStoreError.corruptRecord }
                return record
            }
        } catch { throw clean(error) }
    }

    /// Throws if any sleep row is flagged or, not yet flagged, fails validation now (validated in memory: reads stay pure).
    private func ensureSleepRowsValid() throws {
        if try count(NSPredicate(format: "kind == %@ AND columnsVersion == %d", "sleep", HistorySchema.Columns.corrupt)) > 0 {
            throw HistoryStoreError.corruptRecord
        }
        for object in try objects(NSPredicate(format: "kind == %@ AND columnsVersion == %d", "sleep", HistorySchema.Columns.pending),
                                  sort: "sequence", ascending: true, limit: 0) where object.isInserted == false {
            guard validatedSleep(object) != nil else { throw HistoryStoreError.corruptRecord }
        }
    }

    private func validatedSleep(_ object: NSManagedObject) -> SleepSessionRecord? {
        guard let payload = object.value(forKey: "payload") as? Data, payload.count <= 131072,
              let data = try? (payload as NSData).decompressed(using: .lzfse) as Data, data.count <= 131072,
              let decoded = try? JSONDecoder().decode(SleepPayload.self, from: data),
              decoded.version == 1, decoded.record.isValidForPersistence,
              object.value(forKey: "id") as? UUID == decoded.record.id,
              object.value(forKey: "atDate") as? Date == decoded.record.observedAt else { return nil }
        return decoded.record
    }

    /// Removes rows older than the selected period and all but the newest 2000; skipped entirely (fail closed) while any
    /// sleep row is unreadable, so an unknown codec is never discarded by ordinary pruning.
    private func pruneSleepRows(referenceDate: Date, failClosed: Bool = false) throws {
        guard (try? ensureSleepRowsValid()) != nil else {
            if failClosed { throw HistoryStoreError.corruptRecord }
            return
        }
        let cutoff = referenceDate.addingTimeInterval(-Double(sleepRetentionDays) * 86400)
        for object in try objects(NSPredicate(format: "kind == %@ AND atDate < %@", "sleep", cutoff as NSDate), sort: "sequence", ascending: true, limit: 0) {
            context.delete(object)
        }
        // Counts and fetches include the pending upsert, so the cap counts it; only the excess rows are touched.
        let retained = NSPredicate(format: "kind == %@ AND atDate >= %@", "sleep", cutoff as NSDate)
        let excess = try count(retained) - Self.sleepRowLimit
        if excess > 0 { for object in try objects(retained, sort: "sequence", ascending: true, limit: excess) { context.delete(object) } }
    }

    // MARK: - Retention, maintenance, size budget

    func configureRetention(_ days: Int) throws {
        try ensureOpen()
        configuration.detailedDays = min(configuration.retentionDays, min(30, max(1, days)))
        sleepRetentionDays = max(1, configuration.detailedDays)
        try maintain(referenceDate: Date())
        // Independent history readers keep working; a corrupt sleep codec is still reported, never pruned away.
        try ensureSleepRowsValid()
    }

    /// Bounded, incremental housekeeping: retention, newly expired hour buckets, the sample cap, sleep pruning, the size
    /// budget and a small incremental vacuum step. A backlog larger than one budget continues with the next record.
    func maintain(referenceDate: Date) throws {
        try ensureOpen(); try checkInterruption()
        // A failed step must not leave half-made deletions in the context for the next save to commit.
        do { try maintainSteps(referenceDate: referenceDate) }
        catch { context.rollback(); context.reset(); throw clean(error) }
    }

    private func maintainSteps(referenceDate: Date) throws {
        maintenanceBacklog = false
        let retentionCutoff = referenceDate.addingTimeInterval(-Double(configuration.retentionDays) * 86400)
        // Samples first (their totals leave the summary), then gaps and the old capacity publication.
        try trimOldestSamples(NSPredicate(format: "kind == %@ AND atDate < %@", "sample", retentionCutoff as NSDate))
        try deleteRows(NSPredicate(format: "(kind == %@ OR kind == %@) AND atDate < %@", "gap", Self.weeklyCapacityKind, retentionCutoff as NSDate))
        if backfillComplete, state != nil { try aggregateExpiredBuckets(referenceDate: referenceDate) }
        if sampleRows > configuration.maximumSamples {
            try trimOldestSamples(kind("sample"), limit: min(Self.maintenanceRowBudget, sampleRows - configuration.maximumSamples))
            if sampleRows > configuration.maximumSamples { maintenanceBacklog = true }
        }
        let gapCount = try count(kind("gap"))
        if gapCount > 1000 {
            for object in try objects(kind("gap"), sort: "sequence", ascending: true, limit: gapCount - 1000) { context.delete(object) }
        }
        try pruneSleepRows(referenceDate: referenceDate)
        if context.hasChanges { try save() }
        try reloadGapsAndSessions()
        cycleBaseline = nil; catalogSummary = nil
        try enforceStorageBudget(referenceDate: referenceDate)
        if url != nil, let pages = HistorySQLiteFile.pages(fileURL), pages.freePages > 0 {
            HistorySQLiteFile.incrementalVacuum(fileURL, pages: min(pages.freePages, 4096))
        }
    }

    /// Hour buckets that expired since the last run (rows with isAggregate == NO in the expired window). Inside a bucket
    /// each run of consecutive rows (sequence order) with the same segment and power flags becomes one aggregate, merged
    /// with that run's earlier aggregate if the bucket was partly done before. The aggregate takes the run's first id and
    /// observedFrom and its last collectedAt, so a rescan finds the same sessions the running summary recorded.
    /// Existing aggregates contribute through their columns; only one payload per run is decoded, as the template for the
    /// aggregate's catalog, and a run without a decodable payload is aggregated from its columns alone.
    private func aggregateExpiredBuckets(referenceDate: Date) throws {
        guard var working = state else { return }
        let interval = configuration.aggregateIntervalSeconds
        func bucket(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / interval).rounded(.down)) }
        func bucketStart(_ index: Int64) -> Date { Date(timeIntervalSince1970: Double(index) * interval) }
        let cutoff = referenceDate.addingTimeInterval(-Double(configuration.detailedDays) * 86400)
        var subpredicates = [NSPredicate(format: "kind == %@ AND isAggregate == NO AND columnsVersion == %d AND atDate < %@",
                                         "sample", HistorySchema.Columns.valid, cutoff as NSDate)]
        if let lower = working.aggregatedThrough { subpredicates.append(NSPredicate(format: "atDate >= %@", lower as NSDate)) }
        var rows = try context.fetch(dictionaryRequest(NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates), keys: Self.sampleKeys,
                                                       sort: "atDate", ascending: true, limit: Self.maintenanceRowBudget + 1, objectID: true))
        var nextLower = bucketStart(bucket(cutoff))
        if rows.count > Self.maintenanceRowBudget, let rest = rows[Self.maintenanceRowBudget]["atDate"] as? Date {
            // The rest continues with the next record. A run split across passes is merged into its aggregate then.
            rows = Array(rows.prefix(Self.maintenanceRowBudget))
            nextLower = bucketStart(bucket(rest))
            maintenanceBacklog = true
        }
        lastAggregationRows = rows.count
        typealias Member = (id: NSManagedObjectID, sample: HistorySample, sequence: Int64)
        var buckets: [Int64: [Member]] = [:]
        for row in rows {
            guard let id = row["objectID"] as? NSManagedObjectID, let sample = Self.sample(fromColumns: row),
                  let sequence = (row["sequence"] as? NSNumber)?.int64Value else { continue }
            buckets[bucket(sample.collectedAt), default: []].append((id, sample, sequence))
        }
        if let first = buckets.keys.min(), let last = buckets.keys.max() {
            let existing = NSPredicate(format: "kind == %@ AND isAggregate == YES AND columnsVersion == %d AND atDate >= %@ AND atDate < %@",
                                       "sample", HistorySchema.Columns.valid, bucketStart(first) as NSDate, bucketStart(last + 1) as NSDate)
            for row in try context.fetch(dictionaryRequest(existing, keys: Self.sampleKeys, sort: "sequence", ascending: true, limit: 0, objectID: true)) {
                guard let id = row["objectID"] as? NSManagedObjectID, let sample = Self.sample(fromColumns: row),
                      let sequence = (row["sequence"] as? NSNumber)?.int64Value, buckets[bucket(sample.collectedAt)] != nil else { continue }
                buckets[bucket(sample.collectedAt)]!.append((id, sample, sequence))
            }
        }
        var runs: [[Member]] = []
        for members in buckets.values {
            var current: [Member] = []
            for member in members.sorted(by: { $0.sequence < $1.sequence }) {
                if let previous = current.last, previous.sample.segmentID != member.sample.segmentID
                    || previous.sample.isCharging != member.sample.isCharging || previous.sample.isExternalPower != member.sample.isExternalPower {
                    runs.append(current); current = []
                }
                current.append(member)
            }
            if !current.isEmpty { runs.append(current) }
        }
        var removedRows = 0
        for run in runs where run.count > 1 {
            try checkInterruption()
            autoreleasepool {
                let samples = run.map(\.sample), first = samples.first!, last = run.last!
                func average(_ path: KeyPath<HistorySample, Double?>) -> Double? {
                    let valid = samples.compactMap { sample in sample[keyPath: path].map { ($0, sample.aggregateCount) } }
                    let count = valid.reduce(0) { $0 + $1.1 }
                    return count == 0 ? nil : valid.reduce(0) { $0 + $1.0 * Double($1.1) } / Double(count)
                }
                // The newest decodable payload is the catalog template; without one the aggregate carries columns only.
                let template = run.reversed().lazy.compactMap { try? self.decode(HistorySample.self, object: self.context.object(with: $0.id)) }.first
                let readings: [CatalogReading] = (template?.readings ?? []).map { field in
                    let value: Double?
                    switch field.id { case "011": value = average(\.chargePercent); case "039": value = average(\.temperatureCelsius); case "038": value = average(\.batteryPowerWatts); case "026": value = average(\.capacityRetentionPercent); default: return field }
                    return CatalogReading(definition: field.definition, value: value.map(CatalogValue.decimal), unit: field.unit,
                        source: "PowerPersistence", keyPath: "hourlyWeightedMean/\(field.id)", collectedAt: last.sample.collectedAt,
                        provenance: .recorded, freshness: .unknown, reason: "Weighted aggregate of recorded samples; gaps and segment boundaries are preserved.")
                }
                let aggregate = HistorySample(id: first.id, collectedAt: last.sample.collectedAt, monotonicTime: last.sample.monotonicTime,
                    timeZoneOffsetSeconds: last.sample.timeZoneOffsetSeconds, segmentID: last.sample.segmentID,
                    chargePercent: average(\.chargePercent), temperatureCelsius: average(\.temperatureCelsius), batteryPowerWatts: average(\.batteryPowerWatts),
                    capacityRetentionPercent: average(\.capacityRetentionPercent), cycleCount: last.sample.cycleCount,
                    isCharging: last.sample.isCharging, isExternalPower: last.sample.isExternalPower, isAggregate: true,
                    aggregateCount: samples.reduce(0) { $0 + $1.aggregateCount }, readings: readings,
                    observedFrom: first.observedFrom, coveredSeconds: samples.reduce(0) { $0 + $1.coveredSeconds },
                    energyEvidenceVersion: 1, chargedWh: samples.contains { $0.chargedWh != nil } ? samples.reduce(0) { $0 + ($1.chargedWh ?? 0) } : nil,
                    dischargedWh: samples.contains { $0.dischargedWh != nil } ? samples.reduce(0) { $0 + ($1.dischargedWh ?? 0) } : nil,
                    externalPowerSeconds: samples.reduce(0) { $0 + $1.externalPowerSeconds })
                let lastObject = context.object(with: last.id)
                guard let payload = try? Self.compressedJSON(aggregate) else { return }
                lastObject.setValue(payload, forKey: "payload")
                writeColumns(aggregate, to: lastObject)
                for member in run.dropLast() { context.delete(context.object(with: member.id)) }
                removedRows += run.count - 1
                // Merging keeps every total. Rows with an energy interval and per-series point counts shrink to one, and
                // a series whose newest point was merged now ends at the aggregate.
                let merged = HistoryScalars(aggregate, sequence: last.sequence)
                let energyMembers = samples.filter { $0.chargedWh != nil || $0.dischargedWh != nil }.count
                working.energyRows -= max(0, energyMembers - (merged.hasEnergy ? 1 : 0))
                let removedSequences = Set(run.map(\.sequence))
                for (id, value) in merged.seriesValues {
                    guard var entry = working.series[id] else { continue }
                    let before = samples.filter { sample in HistoryScalars(sample, sequence: 0).seriesValues.first { $0.0 == id }?.1 != nil }.count
                    entry.count -= max(0, before - (value == nil ? 0 : 1))
                    if removedSequences.contains(entry.latestSequence), let value { entry.latest = value; entry.latestSequence = merged.sequence }
                    working.series[id] = entry.count > 0 ? entry : nil
                }
            }
        }
        working.normalize()
        working.aggregatedThrough = max(working.aggregatedThrough ?? .distantPast, nextLower)
        try writeState(working)
        try save()
        state = working
        sampleRows -= removedRows
    }

    /// Deletes the oldest sample rows matching `predicate` (sequence order, up to `limit`), takes them out of the
    /// summary and reconciles the sessions that started before the new oldest sample.
    @discardableResult
    private func trimOldestSamples(_ predicate: NSPredicate, limit: Int = HistoryStoreCore.maintenanceRowBudget, sortKey: String = "sequence") throws -> [HistoryScalars] {
        let rows = try context.fetch(dictionaryRequest(predicate, keys: Self.sampleKeys, sort: sortKey, ascending: true, limit: max(1, limit), objectID: true))
        guard !rows.isEmpty else { return [] }
        if rows.count >= limit { maintenanceBacklog = true }
        var removed: [HistoryScalars] = []
        var removedCorrupt = 0
        for row in rows {
            guard let id = row["objectID"] as? NSManagedObjectID else { continue }
            context.delete(context.object(with: id))
            switch Self.int16(row["columnsVersion"]) {
            case HistorySchema.Columns.valid: if let scalars = Self.scalars(fromColumns: row) { removed.append(scalars) }
            case HistorySchema.Columns.corrupt: removedCorrupt += 1
            default: break
            }
        }
        if var working = state {
            working.subtract(removed)
            try reconcileSessions(&working)
            try writeState(working)
            try save()
            state = working
        } else {
            try save()
        }
        sampleRows -= rows.count
        corruptRows = max(0, corruptRows - removedCorrupt)
        return removed
    }

    /// After the oldest samples are gone the summary must describe only what is retained: a session that started before
    /// the new oldest sample now starts there with an unknown original start; one that ended before it disappears.
    private func reconcileSessions(_ working: inout HistorySummaryState) throws {
        let oldestPredicate = NSPredicate(format: "kind == %@ AND columnsVersion == %d", "sample", HistorySchema.Columns.valid)
        let deleted = Set(context.deletedObjects.map(\.objectID))
        var request = dictionaryRequest(oldestPredicate, keys: Self.sampleKeys, sort: "sequence", ascending: true, limit: deleted.count + 1, objectID: true)
        let candidates = try context.fetch(request).filter { row in (row["objectID"] as? NSManagedObjectID).map { !deleted.contains($0) } ?? false }
        guard let oldest = candidates.first.flatMap(Self.scalars(fromColumns:)) else {
            // Nothing readable is retained: the summary is empty (maintenance bookkeeping survives).
            var empty = HistorySummaryState()
            empty.aggregatedThrough = working.aggregatedThrough; empty.lastFullVacuum = working.lastFullVacuum
            working = empty
            for object in try objects(kind(Self.sessionKind), sort: "sequence", ascending: true, limit: 0) { context.delete(object) }
            return
        }
        working.monitoringStart = oldest.observedFrom
        let boundary = oldest.observedFrom
        // A session starting at the new oldest sample was "known" only through the deleted sample before it.
        request = dictionaryRequest(NSPredicate(format: "kind == %@ AND (observedFrom < %@ OR (observedFrom == %@ AND startKnown == YES))",
                                                Self.sessionKind, boundary as NSDate, boundary as NSDate),
                                    keys: ["id", "observedFrom", "endDate", "label", "segmentID", "startKnown"], sort: "sequence",
                                    ascending: true, limit: 0, objectID: true)
        for row in try context.fetch(request) {
            guard let id = row["objectID"] as? NSManagedObjectID, let session = Self.session(fromColumns: row) else { continue }
            if session.kind == "charging", session.originalStartKnown { working.chargingSessionCount -= 1 }
            let object = context.object(with: id)
            if session.observedFrom < boundary, let ended = session.endedAt, ended <= boundary { context.delete(object); continue }
            let clamped = HistorySummaryState.session(startingAt: oldest, kind: session.kind, known: false)
            write(HistorySession(id: clamped.id, segmentID: clamped.segmentID, kind: session.kind, observedFrom: clamped.observedFrom,
                                 endedAt: session.endedAt, originalStartKnown: false), to: object)
        }
        for (kind, session) in working.open where session.observedFrom < boundary || (session.observedFrom == boundary && session.originalStartKnown) {
            if kind == "charging", session.originalStartKnown { working.chargingSessionCount -= 1 }
            working.open[kind] = HistorySummaryState.session(startingAt: oldest, kind: kind, known: false)
        }
        working.chargingSessionCount = max(0, working.chargingSessionCount)
    }

    /// Keeps History.sqlite + WAL under `maximumStorageBytes`. Above 90 % it first returns freed pages, then removes the
    /// oldest history (the hourly-aggregate era first, then detailed days older than `protectedDays`, never newer) until the
    /// pages in use are at 85 %, and records a `.storageLimit` gap so charts start at a boundary instead of implying
    /// continuity. Decisions use pages in use, not the file size: a checkpoint held up by a reader keeps the WAL file large
    /// without the data being large. One run removes at most 10 % of the samples and stops as soon as a step frees
    /// nothing, so a stuck measurement can never wipe the history; a remainder continues with the next record.
    private func enforceStorageBudget(referenceDate: Date) throws {
        guard url != nil, backfillComplete, state != nil, var pages = HistorySQLiteFile.pages(fileURL) else { return }
        let limit = Double(configuration.maximumStorageBytes)
        guard Double(max(pages.fileBytes, pages.usedBytes)) > 0.9 * limit else { return }
        HistorySQLiteFile.incrementalVacuum(fileURL, pages: nil)
        pages = HistorySQLiteFile.pages(fileURL) ?? pages
        let target = 0.85 * limit
        guard Double(pages.usedBytes) > target else { return }
        let detailCutoff = referenceDate.addingTimeInterval(-Double(configuration.detailedDays) * 86400)
        let protectedFrom = referenceDate.addingTimeInterval(-Double(configuration.protectedDays) * 86400)
        var allowance = max(1, sampleRows / 10)
        var removedFrom: Date?
        let backlog = maintenanceBacklog
        while Double(pages.usedBytes) > target, allowance > 0 {
            try checkInterruption()
            // Oldest first, by time: the aggregate era (before the detailed period), then detailed days, never the protected ones.
            var removed: [HistoryScalars] = []
            for upper in [min(detailCutoff, protectedFrom), protectedFrom] {
                removed = try trimOldestSamples(NSPredicate(format: "kind == %@ AND atDate < %@", "sample", upper as NSDate),
                                                limit: min(2000, allowance), sortKey: "atDate")
                if !removed.isEmpty { break }
            }
            guard let first = removed.map(\.observedFrom).min() else { break }
            allowance -= removed.count
            removedFrom = min(removedFrom ?? first, first)
            HistorySQLiteFile.incrementalVacuum(fileURL, pages: nil)
            guard let next = HistorySQLiteFile.pages(fileURL), next.usedBytes < pages.usedBytes else { break }
            pages = next
        }
        maintenanceBacklog = backlog || (Double(pages.usedBytes) > target && allowance <= 0)
        guard let removedFrom else { return }
        let boundary = try context.fetch(dictionaryRequest(kind("sample"), keys: ["observedFrom", "atDate"], sort: "atDate", ascending: true, limit: 1)).first
        let end = (boundary?["observedFrom"] as? Date) ?? (boundary?["atDate"] as? Date) ?? protectedFrom
        // Gaps inside the removed history (an earlier storage boundary included) describe nothing that is still kept.
        try deleteRows(NSPredicate(format: "kind == %@ AND atDate < %@", "gap", end as NSDate))
        let gap = HistoryGap(start: min(removedFrom, end), end: max(removedFrom, end), reason: .storageLimit)
        try insert(gap, at: end)
        try save()
        try reloadGapsAndSessions()
    }

    /// Current on-disk size (database + WAL) against the budget; 0 for an ephemeral store.
    func storageUsage() throws -> HistoryStorageUsage {
        try ensureOpen()
        return HistoryStorageUsage(bytes: url == nil ? 0 : HistorySQLiteFile.fileBytes(fileURL), limitBytes: configuration.maximumStorageBytes)
    }

    /// A full VACUUM when `HistoryVacuumPolicy` allows it. Returns whether it ran.
    func vacuumIfDue(now: Date, onExternalPower: Bool?, idle: Bool) throws -> Bool {
        try ensureOpen()
        guard url != nil, var working = state,
              HistoryVacuumPolicy.fullVacuumIsDue(now: now, lastFullVacuum: working.lastFullVacuum, onExternalPower: onExternalPower,
                                                  idle: idle, fileBytes: HistorySQLiteFile.fileBytes(fileURL)) else { return false }
        context.reset()
        try checkInterruption()
        guard HistorySQLiteFile.vacuum(fileURL) else { return false }
        working.lastFullVacuum = now
        try writeState(working)
        try save()
        state = working
        return true
    }

    // MARK: - Erase, close, export

    func erase() throws {
        try ensureOpen()
        do {
            let request = NSBatchDeleteRequest(fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: HistorySchema.entityName))
            try context.execute(request)
            context.reset()
            latest = nil; latestIdentity = nil; pendingGap = nil; needsLaunchBoundary = true; sequence = 0
            cycleBaseline = nil; catalogSummary = nil; weeklyCapacityMiss = nil
            sampleRows = 0; corruptRows = 0; backfillComplete = true; maintenanceBacklog = false; writesSinceMaintenance = 0
            gaps = []; closedSessions = []
            let fresh = HistorySummaryState()
            try writeState(fresh)
            try save()
            state = fresh
        } catch { context.rollback(); throw clean(error) }
        if url != nil { HistorySQLiteFile.incrementalVacuum(fileURL, pages: nil) }
    }

    func close() throws {
        guard !closed else { return }
        do {
            if context.hasChanges { try context.save() }
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
            closed = true
            removeEphemeralFiles()
        } catch { throw HistoryStoreError.unavailable }
    }

    func exportJSON() throws -> Data {
        struct Export: Codable { let formatVersion: Int; let units: [String: String]; let summary: HistorySummary; let samples: [HistorySample] }
        guard let summary = try summary(waitForBackfill: true) else { throw HistoryStoreError.unavailable }
        let payload = Export(formatVersion: 2, units: ["chargePercent": "%", "temperatureCelsius": "°C", "batteryPowerWatts": "W", "energy": "Wh", "duration": "s"],
                             summary: summary, samples: try samples(since: nil, limit: configuration.maximumSamples, readingsSince: nil))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    func exportCSV() throws -> Data {
        var rows = ["record_type,date,segment,field,value,unit,source,provenance,availability,freshness,reason,coverage_seconds,aggregate_count"]
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String {
            // Avoid formula execution when an export is opened by a spreadsheet application.
            let numeric = Double(value)?.isFinite == true
            let text = !numeric && ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        for (index, sample) in try samples(since: nil, limit: configuration.maximumSamples, readingsSince: nil).enumerated() {
            if index % 500 == 0 { try checkInterruption() }
            for field in sample.readings {
                rows.append(["sample", formatter.string(from: sample.collectedAt), sample.segmentID.uuidString, field.id,
                    field.value.map { value in
                        switch value { case .decimal(let v): return String(v); case .integer(let v): return String(v); default: return value.displayText }
                    } ?? "", field.unit ?? "", field.source, field.provenance.rawValue,
                    field.availability.rawValue, field.freshness.rawValue, field.reason ?? "", String(sample.coveredSeconds), String(sample.aggregateCount)].map(cell).joined(separator: ","))
            }
        }
        guard let summary = try summary(waitForBackfill: true) else { throw HistoryStoreError.unavailable }
        for gap in summary.gaps {
            rows.append(["gap", formatter.string(from: gap.start), "", "086", formatter.string(from: gap.end), "", "PowerPersistence", "recorded", "available", "unknown", gap.reason.rawValue, "0", "0"].map(cell).joined(separator: ","))
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    func diagnostics() -> HistoryStoreDiagnostics {
        HistoryStoreDiagnostics(mainThreadOperations: mainThreadOperations, summaryRebuilds: summaryRebuilds,
                                backfillComplete: backfillComplete, corruptRows: corruptRows, sampleRows: sampleRows,
                                lastAggregationRows: lastAggregationRows, lastMaintenanceError: lastMaintenanceError)
    }

    // MARK: - Rows and columns

    static let sampleKeys = ["id", "sequence", "atDate", "columnsVersion", "segmentID", "chargePercent", "temperature", "batteryPower",
                             "capacityRetention", "cycleCount", "isCharging", "isExternalPower", "isAggregate", "aggregateCount",
                             "coveredSeconds", "chargedWh", "dischargedWh", "externalPowerSeconds", "observedFrom", "monotonicTime",
                             "timeZoneOffset", "energyEvidenceVersion"]

    private func writeColumns(_ sample: HistorySample, to object: NSManagedObject) {
        object.setValue(sample.id, forKey: "id")
        object.setValue(sample.chargePercent, forKey: "chargePercent")
        object.setValue(sample.temperatureCelsius, forKey: "temperature")
        object.setValue(sample.batteryPowerWatts, forKey: "batteryPower")
        object.setValue(sample.capacityRetentionPercent, forKey: "capacityRetention")
        object.setValue(sample.isAggregate ? nil : Self.capacityEstimate(sample.readings.first { $0.id == "026" }), forKey: "capacityEstimate")
        object.setValue(sample.cycleCount.map { Int64($0) }, forKey: "cycleCount")
        object.setValue(sample.isCharging, forKey: "isCharging")
        object.setValue(sample.isExternalPower, forKey: "isExternalPower")
        object.setValue(sample.isAggregate, forKey: "isAggregate")
        object.setValue(Int64(sample.aggregateCount), forKey: "aggregateCount")
        object.setValue(sample.segmentID, forKey: "segmentID")
        object.setValue(sample.coveredSeconds, forKey: "coveredSeconds")
        object.setValue(sample.chargedWh, forKey: "chargedWh")
        object.setValue(sample.dischargedWh, forKey: "dischargedWh")
        object.setValue(sample.externalPowerSeconds, forKey: "externalPowerSeconds")
        object.setValue(sample.observedFrom, forKey: "observedFrom")
        object.setValue(sample.monotonicTime, forKey: "monotonicTime")
        object.setValue(Int32(clamping: sample.timeZoneOffsetSeconds), forKey: "timeZoneOffset")
        object.setValue(sample.energyEvidenceVersion.map { Int16(clamping: $0) }, forKey: "energyEvidenceVersion")
        object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
    }

    private func writeColumns(_ gap: HistoryGap, to object: NSManagedObject) {
        object.setValue(gap.id, forKey: "id")
        object.setValue(gap.start, forKey: "observedFrom"); object.setValue(gap.end, forKey: "endDate")
        object.setValue(gap.reason.rawValue, forKey: "label")
        object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
    }

    private func write(_ session: HistorySession, to object: NSManagedObject) {
        object.setValue(session.id, forKey: "id"); object.setValue(session.observedFrom, forKey: "atDate")
        object.setValue(session.observedFrom, forKey: "observedFrom"); object.setValue(session.endedAt, forKey: "endDate")
        object.setValue(session.kind, forKey: "label"); object.setValue(session.segmentID, forKey: "segmentID")
        object.setValue(session.originalStartKnown, forKey: "startKnown")
        object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
    }

    private func insertSession(_ session: HistorySession) {
        let object = NSEntityDescription.insertNewObject(forEntityName: HistorySchema.entityName, into: context)
        sequence += 1
        object.setValue(Self.sessionKind, forKey: "kind"); object.setValue(sequence, forKey: "sequence")
        object.setValue(Data(), forKey: "payload")
        write(session, to: object)
    }

    private func writeState(_ state: HistorySummaryState) throws {
        let object = try objects(kind(Self.stateKind), sort: "sequence", ascending: true, limit: 1).first ?? {
            let object = NSEntityDescription.insertNewObject(forEntityName: HistorySchema.entityName, into: context)
            object.setValue(UUID(), forKey: "id"); object.setValue(Self.stateKind, forKey: "kind")
            // Never inside a retention window, never the newest sequence.
            object.setValue(Date.distantFuture, forKey: "atDate"); object.setValue(Int64(0), forKey: "sequence")
            object.setValue(HistorySchema.Columns.valid, forKey: "columnsVersion")
            return object
        }()
        object.setValue(try Self.compressedJSON(state), forKey: "payload")
    }

    static func sample(fromColumns row: NSDictionary) -> HistorySample? {
        guard let id = row["id"] as? UUID, let collectedAt = row["atDate"] as? Date, let segment = row["segmentID"] as? UUID else { return nil }
        return HistorySample(id: id, collectedAt: collectedAt, monotonicTime: double(row["monotonicTime"]),
            timeZoneOffsetSeconds: (row["timeZoneOffset"] as? NSNumber)?.intValue ?? 0, segmentID: segment,
            chargePercent: double(row["chargePercent"]), temperatureCelsius: double(row["temperature"]),
            batteryPowerWatts: double(row["batteryPower"]), capacityRetentionPercent: double(row["capacityRetention"]),
            cycleCount: (row["cycleCount"] as? NSNumber)?.intValue, isCharging: row["isCharging"] as? Bool,
            isExternalPower: row["isExternalPower"] as? Bool, isAggregate: row["isAggregate"] as? Bool ?? false,
            aggregateCount: (row["aggregateCount"] as? NSNumber)?.intValue ?? 1, readings: [],
            observedFrom: row["observedFrom"] as? Date ?? collectedAt, coveredSeconds: double(row["coveredSeconds"]) ?? 0,
            energyEvidenceVersion: (row["energyEvidenceVersion"] as? NSNumber)?.intValue, chargedWh: double(row["chargedWh"]),
            dischargedWh: double(row["dischargedWh"]), externalPowerSeconds: double(row["externalPowerSeconds"]) ?? 0)
    }

    static func scalars(fromColumns row: NSDictionary) -> HistoryScalars? {
        guard let sample = sample(fromColumns: row), let sequence = (row["sequence"] as? NSNumber)?.int64Value else { return nil }
        return HistoryScalars(sample, sequence: sequence)
    }

    private static func gap(fromColumns row: NSDictionary) -> HistoryGap? {
        guard let id = row["id"] as? UUID, let start = row["observedFrom"] as? Date, let end = row["endDate"] as? Date,
              let reason = (row["label"] as? String).flatMap(HistoryGapReason.init(rawValue:)) else { return nil }
        return HistoryGap(id: id, start: start, end: end, reason: reason)
    }

    private static func session(fromColumns row: NSDictionary) -> HistorySession? {
        guard let id = row["id"] as? UUID, let start = row["observedFrom"] as? Date, let kind = row["label"] as? String,
              let segment = row["segmentID"] as? UUID else { return nil }
        return HistorySession(id: id, segmentID: segment, kind: kind, observedFrom: start, endedAt: row["endDate"] as? Date,
                              originalStartKnown: row["startKnown"] as? Bool ?? false)
    }

    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    static func int16(_ value: Any?) -> Int16 { (value as? NSNumber)?.int16Value ?? HistorySchema.Columns.pending }

    // MARK: - Core Data helpers

    private func ensureOpen() throws { if closed { throw HistoryStoreError.unavailable } }
    private func clean(_ error: Error) -> HistoryStoreError { error as? HistoryStoreError ?? .unavailable }
    private func save() throws {
        do { if context.hasChanges { try context.save() }; context.reset() }
        catch { context.rollback(); throw clean(error) }
    }
    private func kind(_ kind: String) -> NSPredicate { NSPredicate(format: "kind == %@", kind) }

    private func objects(_ predicate: NSPredicate?, sort: String, ascending: Bool, limit: Int) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: HistorySchema.entityName)
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: sort, ascending: ascending)]
        request.fetchLimit = limit; request.fetchBatchSize = 200
        return try context.fetch(request)
    }

    private func count(_ predicate: NSPredicate) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: HistorySchema.entityName)
        request.predicate = predicate
        return try context.count(for: request)
    }

    private func deleteRows(_ predicate: NSPredicate) throws {
        for object in try objects(predicate, sort: "sequence", ascending: true, limit: Self.maintenanceRowBudget) { context.delete(object) }
    }

    /// A dictionary fetch of columns only: the payload is never loaded.
    private func dictionaryRequest(_ predicate: NSPredicate, keys: [String], sort: String, ascending: Bool, limit: Int,
                                   objectID: Bool = false) -> NSFetchRequest<NSDictionary> {
        let request = NSFetchRequest<NSDictionary>(entityName: HistorySchema.entityName)
        request.resultType = .dictionaryResultType
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: sort, ascending: ascending)]
        request.fetchLimit = limit
        let attributes = coordinator.managedObjectModel.entitiesByName[HistorySchema.entityName]!.attributesByName
        var properties: [Any] = keys.compactMap { attributes[$0] }
        if objectID {
            let description = NSExpressionDescription()
            description.name = "objectID"; description.expression = .expressionForEvaluatedObject()
            description.expressionResultType = .objectIDAttributeType
            properties.append(description)
        }
        request.propertiesToFetch = properties
        return request
    }

    @discardableResult
    private func insert<T: Encodable>(_ value: T, kind: String, at: Date, identity: String? = nil) throws -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: HistorySchema.entityName, into: context)
        sequence += 1
        object.setValue(UUID(), forKey: "id"); object.setValue(at, forKey: "atDate"); object.setValue(kind, forKey: "kind")
        object.setValue(sequence, forKey: "sequence"); object.setValue(identity, forKey: "identityToken")
        object.setValue(try Self.compressedJSON(value), forKey: "payload")
        return object
    }

    private func insert(_ gap: HistoryGap, at: Date) throws {
        let object = try insert(gap, kind: "gap", at: at)
        writeColumns(gap, to: object)
    }

    static func compressedJSON<T: Encodable>(_ value: T) throws -> Data {
        try (JSONEncoder().encode(value) as NSData).compressed(using: .lzfse) as Data
    }

    private struct EnergyEvidenceProbe: Decodable { let energyEvidenceVersion: Int? }
    private func decode<T: Decodable>(_ type: T.Type, object: NSManagedObject, light: Bool = false) throws -> T {
        guard let payload = object.value(forKey: "payload") as? Data, payload.count <= 2_000_000 else { throw HistoryStoreError.corruptRecord }
        do {
            let data = try (payload as NSData).decompressed(using: .lzfse) as Data
            guard data.count <= 8_000_000 else { throw HistoryStoreError.corruptRecord }
            let decoder = JSONDecoder()
            if light { decoder.userInfo[.skipHistoryReadings] = true }
            // A tiny probe tells current payloads from early ones without building a Foundation object tree of the
            // whole payload (its autoreleased copy of every reading cost ~500 MB while summarising a month of samples).
            if type == HistorySample.self, (try? decoder.decode(EnergyEvidenceProbe.self, from: data))?.energyEvidenceVersion != 1,
               var legacy = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               legacy["energyEvidenceVersion"] as? Int != 1 {
                // Early payloads encoded absence as zero. Retain their measurements,
                // but never upgrade unsupported energy totals into evidence.
                legacy.removeValue(forKey: "chargedWh"); legacy.removeValue(forKey: "dischargedWh")
                return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: legacy))
            }
            return try decoder.decode(type, from: data)
        } catch { throw HistoryStoreError.corruptRecord }
    }

    private static func valid<T>(_ reading: TelemetryReading<T>) -> T? { reading.availability == .available && reading.freshness != .stale ? reading.value : nil }

    static func capacityEstimate(_ reading: CatalogReading?) -> Double? {
        guard let reading, reading.availability == .available, reading.freshness != .stale,
              reading.provenance == .estimated, let value = reading.value?.doubleValue,
              value.isFinite, value > 0 else { return nil }
        return value
    }

    static func median(_ observations: [Double]) -> Double {
        let sorted = observations.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? sorted[middle - 1] / 2 + sorted[middle] / 2
            : sorted[middle]
    }

    private static func redactedReading(_ reading: CatalogReading) -> CatalogReading {
        // Operational schema is allowlisted; arbitrary source strings are not persisted.
        let knownSources = ["IOPowerSources", "AppleSmartBattery", "ProcessInfo", "sysctl", "PowerTelemetry", "IOPSGetTimeRemainingEstimate", "IOPSCopyExternalPowerAdapterDetails", "PowerPersistence", "Demo fixture", "fixture"]
        let source = knownSources.contains(reading.source) ? reading.source : "Other provider"
        return CatalogReading(definition: reading.definition, value: reading.value, rawValue: nil,
            unit: reading.unit, source: source, keyPath: safeChannel(reading, sourceKnown: source != "Other provider"), collectedAt: reading.collectedAt,
            sourceSampleAt: reading.sourceSampleAt, monotonicAgeSeconds: reading.monotonicAgeSeconds,
            provenance: reading.provenance, availability: reading.availability, freshness: reading.freshness,
            reason: reading.value == nil ? "The qualified provider did not supply a usable value." : nil)
    }

    private static func safeChannel(_ reading: CatalogReading, sourceKnown: Bool) -> String {
        // Only schema/property names may survive privacy redaction, never arbitrary paths.
        let tokens: Set<String> = ["BatteryData", "AppleSmartBatteryPack", "LifetimeData", "PowerTelemetryData", "Temperature", "CellVoltage", "CycleCount",
            "Current Capacity", "Max Capacity", "Is Charging", "Power Source State", "BatteryHealth", "BatteryHealthCondition", "Voltage", "Amperage", "Voltage×Amperage",
            "DesignCapacity", "AppleRawMaxCapacity", "NominalChargeCapacity", "FullChargeCapacity", "AppleRawCurrentCapacity", "RemainingCapacity",
            "SystemLoad", "SystemPowerIn", "SystemVoltageIn", "SystemCurrentIn", "thermalState", "Watts", "MaximumTemperature", "MinimumTemperature", "AverageTemperature",
            "MaximumPackVoltage", "MinimumPackVoltage", "MaximumChargeCurrent", "MaximumDischargeCurrent", "TemperatureSamples", "UpdateTime",
            "capacityRetention", "capacityDifference", "nominalCapacityRatio", "max(CellVoltage) - min(CellVoltage)"]
        let components = reading.keyPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard sourceKnown, !components.isEmpty, components.count <= 8, components.allSatisfy(tokens.contains) else { return reading.id }
        return "observed-v2/" + components.joined(separator: "/")
    }
}
