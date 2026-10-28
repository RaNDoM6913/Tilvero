import Foundation
import CoreData
import PowerCore

/// All Core Data objects stay on the main actor; only immutable values leave this boundary.
@MainActor public final class BatteryHistoryStore {
    private let coordinator: NSPersistentStoreCoordinator
    private let context: NSManagedObjectContext
    private var configuration: HistoryConfiguration
    private var sleepRetentionDays: Int
    private var latest: HistorySample?
    private var latestIdentity: String?
    private var sequence: Int64 = 0
    private var needsLaunchBoundary = true
    private var pendingGap: (HistoryGapReason, Date)?
    private var closed = false
    private var writesSinceMaintenance = 0
    private var summaryCache: HistorySummary?
    private var seriesCache: [String: (count: Int, latest: Double)] = [:]
    public let url: URL?
    public var retentionDays: Int { configuration.retentionDays }

    public init(url: URL?, configuration: HistoryConfiguration = .init()) throws {
        self.url = url; self.configuration = configuration
        sleepRetentionDays = max(1, configuration.detailedDays)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model(version: 2))
        self.coordinator = coordinator
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        self.context = context
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                if FileManager.default.fileExists(atPath: url.path) {
                    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
                    let versions = metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []
                    if versions.contains(where: { version in
                        guard version.hasPrefix("TilveroHistory-v"), let n = Int(version.dropFirst("TilveroHistory-v".count)) else { return false }
                        return n > 2
                    }) { throw HistoryStoreError.unsupportedSchema }
                    if !Self.model(version: 2).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                        guard Self.model(version: 1).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { throw HistoryStoreError.unsupportedSchema }
                        try Self.migrateVersionOneStore(at: url, coordinator: coordinator)
                    }
                }
            }
            let store = try coordinator.addPersistentStore(ofType: url == nil ? NSInMemoryStoreType : NSSQLiteStoreType,
                configurationName: nil, at: url, options: [NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true, NSSQLitePragmasOption: ["journal_mode": "WAL"]])
            _ = store // Core Data persists the model version identifiers with the schema.
            let last = try records(kind: nil, ascending: false, limit: 1).first
            sequence = last?.value(forKey: "sequence") as? Int64 ?? 0
            if let lastSample = try records(kind: "sample", ascending: false, limit: 1).first {
                latest = try decode(HistorySample.self, object: lastSample)
                latestIdentity = lastSample.value(forKey: "identityToken") as? String
            }
            if let url { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        } catch let error as HistoryStoreError { throw error }
        catch { throw HistoryStoreError.unavailable }
    }

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
        let sourceModel: NSManagedObjectModel
        if model(version: 2).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { sourceModel = model(version: 2) }
        else if model(version: 1).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { sourceModel = model(version: 1) }
        else { throw HistoryStoreError.unsupportedSchema }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
        try coordinator.replacePersistentStore(at: destination,
            destinationOptions: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]],
            withPersistentStoreFrom: source, sourceOptions: [NSReadOnlyPersistentStoreOption: true], ofType: NSSQLiteStoreType)
        // Upgrade only the private copy before its stable identity enters the migration journal.
        let copy = try BatteryHistoryStore(url: destination)
        try copy.close()
        // Opening only the copy with DELETE consolidates any copied WAL before a single-file promotion.
        let detachedCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model(version: 2))
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

    public func record(_ snapshot: BatterySnapshot) throws {
        try ensureOpen()
        guard !snapshot.isDemo else { throw HistoryStoreError.simulationExcluded }
        let at = snapshot.collectedAt
        let previous = latest
        let numeric: (String) -> Double? = { id in
            guard let r = snapshot.catalog.first(where: { $0.id == id }), r.availability == .available, r.freshness != .stale,
                  let value = r.value?.doubleValue, value.isFinite else { return nil }
            return value
        }
        let charge = numeric("011") ?? valid(snapshot.chargePercent).map(Double.init)
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
        let external = valid(snapshot.isExternalPower)
        let historyIDs: Set<String> = ["011", "013", "015", "023", "024", "025", "026", "027", "035", "036", "038", "039", "044", "050", "054", "055", "056"]
        let safeReadings = snapshot.catalog.filter { $0.privacy == .operational && historyIDs.contains($0.id) }.map(Self.redactedReading)
        let sample = HistorySample(id: UUID(), collectedAt: at, monotonicTime: snapshot.monotonicTime,
            timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: at), segmentID: segment,
            chargePercent: charge, temperatureCelsius: numeric("039") ?? valid(snapshot.temperatureCelsius),
            batteryPowerWatts: power, capacityRetentionPercent: numeric("026"), cycleCount: valid(snapshot.cycleCount),
            isCharging: valid(snapshot.isCharging), isExternalPower: external, isAggregate: false, aggregateCount: 1,
            readings: safeReadings, observedFrom: at, coveredSeconds: contiguous ? elapsed : 0,
            energyEvidenceVersion: 1, chargedWh: energy.map { max(0, $0) }, dischargedWh: energy.map { max(0, -$0) },
            externalPowerSeconds: contiguous && external == true && previous?.isExternalPower == true ? elapsed : 0)
        do {
            if let gap { try insert(gap, kind: "gap", at: at) }
            try insert(sample, kind: "sample", at: at, identity: currentIdentity)
            let exceedsLimit = try sampleCount() > configuration.maximumSamples
            let maintenanceDue = writesSinceMaintenance + 1 >= 60 || exceedsLimit
            if maintenanceDue { try maintain(referenceDate: at) }
            else { try context.save() }
            latest = sample; latestIdentity = currentIdentity; pendingGap = nil; needsLaunchBoundary = false
            writesSinceMaintenance = maintenanceDue ? 0 : writesSinceMaintenance + 1
            summaryCache = nil
        } catch { context.rollback(); throw clean(error) }
    }

    public func samples(since: Date? = nil, limit: Int = 20000) throws -> [HistorySample] {
        try ensureOpen()
        do {
            let request = request(kind: "sample", ascending: false, limit: min(100000, max(1, limit)))
            if let since { request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [request.predicate!, NSPredicate(format: "atDate >= %@", since as NSDate)]) }
            return try context.fetch(request).reversed().map { try decode(HistorySample.self, object: $0) }
        } catch { throw clean(error) }
    }
    private struct SleepPayload: Codable { let version: Int; let record: SleepSessionRecord }

    /// Updates one stable observation row. Assertions and process details never enter this payload.
    public func upsertSleepSession(_ record: SleepSessionRecord) throws {
        try ensureOpen()
        guard record.isValidForPersistence, let at = record.observedAt else { throw HistoryStoreError.corruptRecord }
        let previousSequence = sequence
        do {
            // Fail closed before changing anything if a future/corrupt sleep codec is present.
            var existing = try validatedSleepRows()
            let encoded = try JSONEncoder().encode(SleepPayload(version: 1, record: record))
            guard encoded.count <= 131072 else { throw HistoryStoreError.corruptRecord }
            let object: NSManagedObject
            if let index = existing.firstIndex(where: { $0.1.id == record.id }) {
                object = existing[index].0
                existing[index] = (object, record)
            }
            else {
                object = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
                sequence += 1
                object.setValue(record.id, forKey: "id"); object.setValue("sleep", forKey: "kind")
                object.setValue(sequence, forKey: "sequence")
                existing.append((object, record))
            }
            object.setValue(at, forKey: "atDate")
            object.setValue(try (encoded as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
            pruneSleepRows(existing, referenceDate: Date())
            try context.save()
        } catch { context.rollback(); sequence = previousSequence; throw clean(error) }
    }

    /// Old rows use the selected detailed-history period; battery aggregates keep their own retention.
    public func sleepSessions(limit: Int = 2000) throws -> [SleepSessionRecord] {
        try ensureOpen()
        do {
            let rows = try validatedSleepRows()
            let cutoff = Date().addingTimeInterval(-Double(sleepRetentionDays) * 86400)
            let retained = rows.filter { $0.1.observedAt! >= cutoff }
            for (object, record) in rows where record.observedAt! < cutoff { context.delete(object) }
            for (object, _) in retained.dropLast(2000) { context.delete(object) }
            if context.hasChanges { try context.save() }
            return Array(retained.suffix(min(2000, max(0, limit))).map(\.1))
        } catch { context.rollback(); throw clean(error) }
    }

    private func validatedSleepRows() throws -> [(NSManagedObject, SleepSessionRecord)] {
        try records(kind: "sleep", ascending: true, limit: 0).map { object in
            guard let payload = object.value(forKey: "payload") as? Data, payload.count <= 131072 else { throw HistoryStoreError.corruptRecord }
            do {
                let data = try (payload as NSData).decompressed(using: .lzfse) as Data
                guard data.count <= 131072 else { throw HistoryStoreError.corruptRecord }
                let decoded = try JSONDecoder().decode(SleepPayload.self, from: data)
                guard decoded.version == 1, decoded.record.isValidForPersistence,
                      object.value(forKey: "id") as? UUID == decoded.record.id,
                      object.value(forKey: "atDate") as? Date == decoded.record.observedAt else { throw HistoryStoreError.corruptRecord }
                return (object, decoded.record)
            } catch { throw HistoryStoreError.corruptRecord }
        }
    }

    private func pruneSleepRows(_ rows: [(NSManagedObject, SleepSessionRecord)], referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-Double(sleepRetentionDays) * 86400)
        let retained = rows.filter { $0.1.observedAt! >= cutoff }
        for (object, record) in rows where record.observedAt! < cutoff { context.delete(object) }
        for (object, _) in retained.dropLast(2000) { context.delete(object) }
    }
    public func summary() throws -> HistorySummary {
        try ensureOpen()
        if let summaryCache { return summaryCache }
        var start: Date?, count = 0, covered = 0.0, charged = 0.0, discharged = 0.0, external = 0.0
        var sessions: [HistorySession] = [], current: [String: HistorySession] = [:]
        var previous: HistorySample?, knownChargingStarts = 0
        var hasQualifiedEnergy = false
        var series: [String: (count: Int, latest: Double)] = [:]
        func active(_ sample: HistorySample, _ kind: String) -> Bool? {
            kind == "charging" ? sample.isCharging : kind == "externalPower" ? sample.isExternalPower : sample.isExternalPower.map { !$0 }
        }
        for object in try records(kind: "sample", ascending: true, limit: configuration.maximumSamples) {
            let sample = try decode(HistorySample.self, object: object)
            if start == nil { start = sample.observedFrom }
            count += sample.aggregateCount; covered += sample.coveredSeconds
            hasQualifiedEnergy = hasQualifiedEnergy || sample.chargedWh != nil || sample.dischargedWh != nil
            charged += sample.chargedWh ?? 0; discharged += sample.dischargedWh ?? 0; external += sample.externalPowerSeconds
            for (id, value) in [("078", sample.chargePercent), ("079", sample.temperatureCelsius), ("080", sample.batteryPowerWatts), ("081", sample.capacityRetentionPercent)] {
                if let value { series[id] = ((series[id]?.count ?? 0) + 1, value) }
            }
            let sameSegment = previous?.segmentID == sample.segmentID
            for kind in ["charging", "externalPower", "onBattery"] {
                if let ongoing = current[kind], !sameSegment || active(sample, kind) != true {
                    sessions.append(HistorySession(id: ongoing.id, segmentID: ongoing.segmentID, kind: kind,
                        observedFrom: ongoing.observedFrom, endedAt: sameSegment ? sample.observedFrom : previous?.collectedAt,
                        originalStartKnown: ongoing.originalStartKnown))
                    current[kind] = nil
                }
                if active(sample, kind) == true, current[kind] == nil {
                    let known = sameSegment && previous.map { active($0, kind) == false } == true
                    var identity = sample.id.uuid
                    identity.0 ^= kind == "charging" ? 1 : kind == "externalPower" ? 2 : 3
                    current[kind] = HistorySession(id: UUID(uuid: identity), segmentID: sample.segmentID, kind: kind,
                        observedFrom: sample.observedFrom, endedAt: nil, originalStartKnown: known)
                    if kind == "charging", known { knownChargingStarts += 1 }
                }
            }
            if sessions.count > 1000 { sessions.removeFirst(sessions.count - 1000) }
            previous = sample
            // Release loaded binary payloads instead of retaining a full year of envelopes.
            if !object.hasChanges { context.refresh(object, mergeChanges: false) }
        }
        sessions += current.values
        let gaps = try records(kind: "gap", ascending: true, limit: 1000).map { try decode(HistoryGap.self, object: $0) }
        let summary = HistorySummary(monitoringStart: start, sampleCount: count, gaps: gaps,
            sessions: sessions.sorted { $0.observedFrom < $1.observedFrom }, observedExternalPowerSeconds: external,
            estimatedChargedWh: hasQualifiedEnergy ? charged : nil, estimatedDischargedWh: hasQualifiedEnergy ? discharged : nil, coveredSeconds: covered,
            chargingSessionCount: knownChargingStarts)
        summaryCache = summary; seriesCache = series
        return summary
    }
    public func markGap(reason: HistoryGapReason, at: Date = Date()) throws { try ensureOpen(); pendingGap = (reason, at) }
    public func markGap(_ reason: HistoryGapReason, at: Date = Date()) throws { try markGap(reason: reason, at: at) }
    public func configureRetention(_ days: Int) throws {
        configuration.detailedDays = min(configuration.retentionDays, min(30, max(1, days)))
        sleepRetentionDays = max(1, configuration.detailedDays)
        try maintain(referenceDate: Date())
        do { pruneSleepRows(try validatedSleepRows(), referenceDate: Date()); try context.save() }
        catch { context.rollback(); throw clean(error) }
    }
    public func erase() throws {
        try ensureOpen()
        do {
            for object in try records(kind: nil, ascending: true, limit: 200000) { context.delete(object) }
            try context.save()
            latest = nil; latestIdentity = nil; pendingGap = nil; needsLaunchBoundary = true; sequence = 0
            summaryCache = nil; seriesCache = [:]
        } catch { context.rollback(); throw clean(error) }
    }
    public func close() throws {
        guard !closed else { return }
        do {
            if context.hasChanges { try context.save() }
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
            closed = true
        } catch { throw HistoryStoreError.unavailable }
    }
    public func exportJSON() throws -> Data {
        struct Export: Codable { let formatVersion: Int; let units: [String: String]; let summary: HistorySummary; let samples: [HistorySample] }
        let payload = Export(formatVersion: 2, units: ["chargePercent": "%", "temperatureCelsius": "°C", "batteryPowerWatts": "W", "energy": "Wh", "duration": "s"], summary: try summary(), samples: try samples(limit: configuration.maximumSamples))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }
    public func exportCSV() throws -> Data {
        var rows = ["record_type,date,segment,field,value,unit,source,provenance,availability,freshness,reason,coverage_seconds,aggregate_count"]
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String {
            // Avoid formula execution when an export is opened by a spreadsheet application.
            let numeric = Double(value)?.isFinite == true
            let text = !numeric && ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        for sample in try samples(limit: configuration.maximumSamples) {
            for field in sample.readings {
                rows.append(["sample", formatter.string(from: sample.collectedAt), sample.segmentID.uuidString, field.id,
                    field.value.map { value in
                        switch value { case .decimal(let v): return String(v); case .integer(let v): return String(v); default: return value.displayText }
                    } ?? "", field.unit ?? "", field.source, field.provenance.rawValue,
                    field.availability.rawValue, field.freshness.rawValue, field.reason ?? "", String(sample.coveredSeconds), String(sample.aggregateCount)].map(cell).joined(separator: ","))
            }
        }
        for gap in try summary().gaps {
            rows.append(["gap", formatter.string(from: gap.start), "", "086", formatter.string(from: gap.end), "", "PowerPersistence", "recorded", "available", "unknown", gap.reason.rawValue, "0", "0"].map(cell).joined(separator: ","))
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }
    public func catalogReadings(at date: Date = Date()) throws -> [CatalogReading] {
        let summary = try summary()
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
            let first = try records(kind: "sample", ascending: true, limit: configuration.maximumSamples).first { object in
                guard let sample = try? decode(HistorySample.self, object: object) else { return false }
                return sample.segmentID == last.segmentID && sample.cycleCount != nil
            }
            if let first, let initial = try decode(HistorySample.self, object: first).cycleCount, final >= initial {
                fields.append(reading("082", .integer(Int64(final - initial))))
            }
        }
        let sessions = summary.sessions
        if let session = sessions.last(where: { $0.kind == "externalPower" && $0.endedAt == nil && $0.originalStartKnown }) { fields.append(reading("072", .date(session.observedFrom))) }
        if let session = sessions.last(where: { $0.kind == "onBattery" && $0.endedAt == nil && $0.originalStartKnown }) { fields.append(reading("073", .date(session.observedFrom))) }
        if let session = sessions.last(where: { $0.kind == "charging" && $0.endedAt == nil && $0.originalStartKnown }), let last = latest { fields.append(reading("074", .decimal(max(0, last.collectedAt.timeIntervalSince(session.observedFrom))))) }
        return fields
    }

    private func valid<T>(_ reading: TelemetryReading<T>) -> T? { reading.availability == .available && reading.freshness != .stale ? reading.value : nil }
    private func ensureOpen() throws { if closed { throw HistoryStoreError.unavailable } }
    private func clean(_ error: Error) -> HistoryStoreError { error as? HistoryStoreError ?? .unavailable }
    private func request(kind: String?, ascending: Bool, limit: Int) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryRecord")
        if let kind { request.predicate = NSPredicate(format: "kind == %@", kind) }
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: ascending)]
        request.fetchLimit = limit; request.fetchBatchSize = 200
        return request
    }
    private func records(kind: String?, ascending: Bool, limit: Int) throws -> [NSManagedObject] { try ensureOpen(); return try context.fetch(request(kind: kind, ascending: ascending, limit: limit)) }
    private func sampleCount() throws -> Int { try context.count(for: request(kind: "sample", ascending: true, limit: 0)) }
    private func insert<T: Encodable>(_ value: T, kind: String, at: Date, identity: String? = nil) throws {
        let object = NSEntityDescription.insertNewObject(forEntityName: "HistoryRecord", into: context)
        sequence += 1
        object.setValue(UUID(), forKey: "id"); object.setValue(at, forKey: "atDate"); object.setValue(kind, forKey: "kind")
        object.setValue(sequence, forKey: "sequence"); object.setValue(identity, forKey: "identityToken")
        let data = try JSONEncoder().encode(value)
        object.setValue(try (data as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
    }
    private func decode<T: Decodable>(_ type: T.Type, object: NSManagedObject) throws -> T {
        guard let payload = object.value(forKey: "payload") as? Data, payload.count <= 2_000_000 else { throw HistoryStoreError.corruptRecord }
        do {
            let data = try (payload as NSData).decompressed(using: .lzfse) as Data
            guard data.count <= 8_000_000 else { throw HistoryStoreError.corruptRecord }
            if type == HistorySample.self,
               var legacy = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               legacy["energyEvidenceVersion"] as? Int != 1 {
                // Early payloads encoded absence as zero. Retain their measurements,
                // but never upgrade unsupported energy totals into evidence.
                legacy.removeValue(forKey: "chargedWh"); legacy.removeValue(forKey: "dischargedWh")
                return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: legacy))
            }
            return try JSONDecoder().decode(type, from: data)
        } catch { throw HistoryStoreError.corruptRecord }
    }
    private func maintain(referenceDate: Date) throws {
        try ensureOpen()
        do {
            let cutoff = referenceDate.addingTimeInterval(-Double(configuration.retentionDays) * 86400)
            let old = request(kind: nil, ascending: true, limit: 200000)
            // Sleep payloads have their own validated retention pass. Unknown or
            // corrupt versions must not disappear in ordinary sample maintenance.
            old.predicate = NSPredicate(format: "atDate < %@ AND kind != %@", cutoff as NSDate, "sleep")
            for object in try context.fetch(old) { context.delete(object) }
            let detailCutoff = referenceDate.addingTimeInterval(-Double(configuration.detailedDays) * 86400)
            let candidates = try records(kind: "sample", ascending: true, limit: configuration.maximumSamples + 1)
            var groups: [String: [(NSManagedObject, HistorySample)]] = [:]
            for object in candidates {
                guard let date = object.value(forKey: "atDate") as? Date, date < detailCutoff else { continue }
                let sample = try decode(HistorySample.self, object: object)
                let bucket = Int64(date.timeIntervalSince1970 / configuration.aggregateIntervalSeconds)
                let key = "\(sample.segmentID)-\(bucket)-\(String(describing: sample.isCharging))-\(String(describing: sample.isExternalPower))"
                groups[key, default: []].append((object, sample))
            }
            for group in groups.values where group.count > 1 {
                let sorted = group.sorted { $0.1.collectedAt < $1.1.collectedAt }
                let samples = sorted.map(\.1), last = samples.last!
                // Preserve weighted observed values and independently accumulated interval integrals.
                func average(_ path: KeyPath<HistorySample, Double?>) -> Double? {
                    let valid = samples.compactMap { sample in sample[keyPath: path].map { ($0, sample.aggregateCount) } }
                    let count = valid.reduce(0) { $0 + $1.1 }
                    return count == 0 ? nil : valid.reduce(0) { $0 + $1.0 * Double($1.1) } / Double(count)
                }
                let aggregate = HistorySample(id: last.id, collectedAt: last.collectedAt, monotonicTime: last.monotonicTime,
                    timeZoneOffsetSeconds: last.timeZoneOffsetSeconds, segmentID: last.segmentID,
                    chargePercent: average(\.chargePercent), temperatureCelsius: average(\.temperatureCelsius), batteryPowerWatts: average(\.batteryPowerWatts),
                    capacityRetentionPercent: average(\.capacityRetentionPercent), cycleCount: last.cycleCount,
                    isCharging: last.isCharging, isExternalPower: last.isExternalPower, isAggregate: true,
                    aggregateCount: samples.reduce(0) { $0 + $1.aggregateCount }, readings: last.readings.map { field in
                        let value: Double?
                        switch field.id { case "011": value = average(\.chargePercent); case "039": value = average(\.temperatureCelsius); case "038": value = average(\.batteryPowerWatts); case "026": value = average(\.capacityRetentionPercent); default: return field }
                        return CatalogReading(definition: field.definition, value: value.map(CatalogValue.decimal), unit: field.unit,
                            source: "PowerPersistence", keyPath: "hourlyWeightedMean/\(field.id)", collectedAt: last.collectedAt,
                            provenance: .recorded, freshness: .unknown, reason: "Weighted aggregate of recorded samples; gaps and segment boundaries are preserved.")
                    },
                    observedFrom: samples.first!.observedFrom, coveredSeconds: samples.reduce(0) { $0 + $1.coveredSeconds },
                    energyEvidenceVersion: 1, chargedWh: samples.contains { $0.chargedWh != nil } ? samples.reduce(0) { $0 + ($1.chargedWh ?? 0) } : nil, dischargedWh: samples.contains { $0.dischargedWh != nil } ? samples.reduce(0) { $0 + ($1.dischargedWh ?? 0) } : nil, externalPowerSeconds: samples.reduce(0) { $0 + $1.externalPowerSeconds })
                let data = try JSONEncoder().encode(aggregate)
                sorted.last!.0.setValue(try (data as NSData).compressed(using: .lzfse) as Data, forKey: "payload")
                for (object, _) in sorted.dropLast() { context.delete(object) }
            }
            let remaining = try records(kind: "sample", ascending: false, limit: 200000)
            for object in remaining.dropFirst(configuration.maximumSamples) { context.delete(object) }
            let gaps = try records(kind: "gap", ascending: false, limit: 200000)
            for object in gaps.dropFirst(1000) { context.delete(object) }
            try context.save()
            summaryCache = nil
        } catch { context.rollback(); throw clean(error) }
    }
    private static func redactedReading(_ reading: CatalogReading) -> CatalogReading {
        // Operational schema is allowlisted; arbitrary source strings are not persisted.
        let knownSources = ["IOPowerSources", "AppleSmartBattery", "ProcessInfo", "sysctl", "PowerTelemetry", "IOPSGetTimeRemainingEstimate", "IOPSCopyExternalPowerAdapterDetails", "PowerPersistence", "Demo fixture", "fixture"]
        let source = knownSources.contains(reading.source) ? reading.source : "Other provider"
        return CatalogReading(definition: reading.definition, value: reading.value, rawValue: nil,
            unit: reading.unit, source: source, keyPath: reading.id, collectedAt: reading.collectedAt,
            sourceSampleAt: reading.sourceSampleAt, monotonicAgeSeconds: reading.monotonicAgeSeconds,
            provenance: reading.provenance, availability: reading.availability, freshness: reading.freshness,
            reason: reading.value == nil ? "The qualified provider did not supply a usable value." : nil)
    }
    private static func migrateVersionOneStore(at url: URL, coordinator: NSPersistentStoreCoordinator) throws {
        let source = model(version: 1), destination = model(version: 2)
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: destination)
        let manager = NSMigrationManager(sourceModel: source, destinationModel: destination)
        let migratedURL = url.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: migratedURL.path + suffix) }
        }
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil, with: mapping,
            toDestinationURL: migratedURL, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        // Core Data replaces the destination only after a complete successful migration.
        // A failed migration preserves the original store and is surfaced to the app.
        try coordinator.replacePersistentStore(at: url, destinationOptions: nil,
            withPersistentStoreFrom: migratedURL, sourceOptions: nil, ofType: NSSQLiteStoreType)
    }
    /// Version 1 is retained for real inferred-migration fixtures, never used for a new production store.
    static func model(version: Int) -> NSManagedObjectModel {
        let model = NSManagedObjectModel(); model.versionIdentifiers = ["TilveroHistory-v\(version)"]
        let entity = NSEntityDescription(); entity.name = "HistoryRecord"; entity.managedObjectClassName = "NSManagedObject"
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional; return a
        }
        var properties: [NSPropertyDescription] = [attribute("id", .UUIDAttributeType), attribute("atDate", .dateAttributeType),
            attribute("kind", .stringAttributeType), attribute("payload", .binaryDataAttributeType), attribute("sequence", .integer64AttributeType)]
        if version >= 2 { properties.append(attribute("identityToken", .stringAttributeType, optional: true)) }
        entity.properties = properties
        entity.indexes = [NSFetchIndexDescription(name: "bySequence", elements: [NSFetchIndexElementDescription(property: properties.first { $0.name == "sequence" }!, collationType: .binary)])]
        model.entities = [entity]
        return model
    }
}
