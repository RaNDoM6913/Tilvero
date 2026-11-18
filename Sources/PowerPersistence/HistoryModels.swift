// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore

public struct HistoryConfiguration: Sendable, Equatable {
    /// The on-disk ceiling for History.sqlite and its WAL, sleep reports included (owner: "about half a gigabyte").
    public static let defaultStorageLimitBytes: Int64 = 512 * 1024 * 1024
    public var retentionDays: Int
    public var maximumSamples: Int
    public var maximumGapSeconds: TimeInterval
    public var detailedDays: Int
    public var aggregateIntervalSeconds: TimeInterval
    /// Above 90 % of this the oldest hourly aggregates go first, then the oldest detailed days; never `protectedDays`.
    public var maximumStorageBytes: Int64
    public var protectedDays: Int
    public init(retentionDays: Int = 365, maximumSamples: Int = 60000, maximumGapSeconds: TimeInterval = 120,
                detailedDays: Int = 30, aggregateIntervalSeconds: TimeInterval = 3600,
                maximumStorageBytes: Int64 = HistoryConfiguration.defaultStorageLimitBytes, protectedDays: Int = 7) {
        self.retentionDays = min(365, max(1, retentionDays))
        self.maximumSamples = min(100000, max(2, maximumSamples))
        self.maximumGapSeconds = max(1, maximumGapSeconds.isFinite ? maximumGapSeconds : 120)
        self.detailedDays = min(self.retentionDays, max(0, detailedDays))
        self.aggregateIntervalSeconds = max(1, aggregateIntervalSeconds.isFinite ? aggregateIntervalSeconds : 3600)
        self.maximumStorageBytes = max(1024 * 1024, maximumStorageBytes)
        self.protectedDays = min(self.retentionDays, max(0, protectedDays))
    }
}
public enum HistoryGapReason: String, Codable, Sendable {
    case sleep, offline, providerUnavailable, batteryReplacement, clockChange, launch, explicitBoundary
    /// Older history was removed to keep the store under its size limit; the chart starts at a boundary.
    case storageLimit
}

/// What the store occupies on disk (database plus write-ahead log) against its ceiling.
public struct HistoryStorageUsage: Sendable, Equatable {
    public let bytes: Int64
    public let limitBytes: Int64
    public init(bytes: Int64, limitBytes: Int64) { self.bytes = bytes; self.limitBytes = limitBytes }
    /// Whole megabytes (MiB), rounded up so a non-empty store never reads "0 MB".
    public var megabytes: Int64 { bytes <= 0 ? 0 : (bytes + 1_048_575) / 1_048_576 }
    public var limitMegabytes: Int64 { limitBytes / 1_048_576 }
}

/// A full VACUUM rewrites the whole file: at most weekly, only while nobody looks at the app and it runs on the adapter.
/// Incremental vacuum (auto_vacuum = INCREMENTAL) reclaims freed pages in small steps in between.
public enum HistoryVacuumPolicy {
    public static let minimumInterval: TimeInterval = 7 * 86400
    /// Below this a defragmenting rewrite saves too little to be worth the I/O.
    public static let minimumFileBytes: Int64 = 16 * 1024 * 1024
    public static func fullVacuumIsDue(now: Date, lastFullVacuum: Date?, onExternalPower: Bool?, idle: Bool, fileBytes: Int64) -> Bool {
        guard idle, onExternalPower == true, fileBytes >= minimumFileBytes else { return false }
        guard let lastFullVacuum else { return true }
        // A clock set backwards must not postpone the rewrite forever, nor run it on every check.
        let elapsed = now.timeIntervalSince(lastFullVacuum)
        return elapsed >= minimumInterval || elapsed < -minimumInterval
    }
}
public struct HistoryGap: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let reason: HistoryGapReason
    public init(start: Date, end: Date, reason: HistoryGapReason) {
        self.init(id: UUID(), start: start, end: end, reason: reason)
    }
    init(id: UUID, start: Date, end: Date, reason: HistoryGapReason) {
        self.id = id; self.start = start; self.end = end; self.reason = reason
    }
}
public struct HistorySample: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let collectedAt: Date
    public var date: Date { collectedAt }
    public let monotonicTime: TimeInterval?
    public let timeZoneOffsetSeconds: Int
    /// Random segment ID exposes a boundary without exposing a battery serial or identity token.
    public let segmentID: UUID
    public let chargePercent: Double?
    public let temperatureCelsius: Double?
    public let batteryPowerWatts: Double?
    public let capacityRetentionPercent: Double?
    public let cycleCount: Int?
    public let isCharging: Bool?
    public let isExternalPower: Bool?
    public let isAggregate: Bool
    public let aggregateCount: Int
    public let readings: [CatalogReading]
    public let observedFrom: Date
    public let coveredSeconds: Double
    public let energyEvidenceVersion: Int?
    public let chargedWh: Double?
    public let dischargedWh: Double?
    public let externalPowerSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id, collectedAt, monotonicTime, timeZoneOffsetSeconds, segmentID, chargePercent, temperatureCelsius
        case batteryPowerWatts, capacityRetentionPercent, cycleCount, isCharging, isExternalPower, isAggregate
        case aggregateCount, readings, observedFrom, coveredSeconds, energyEvidenceVersion, chargedWh, dischargedWh
        case externalPowerSeconds
    }
}

public extension CodingUserInfoKey {
    /// Set to `true` on a decoder to skip the 115-entry catalog of each stored sample (`readings` becomes empty).
    /// Summaries and long charts need only the scalar fields; decoding every reading dominated the app's CPU use.
    static let skipHistoryReadings = CodingUserInfoKey(rawValue: "tilvero.skipHistoryReadings")!
}

extension HistorySample {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        collectedAt = try c.decode(Date.self, forKey: .collectedAt)
        monotonicTime = try c.decodeIfPresent(TimeInterval.self, forKey: .monotonicTime)
        timeZoneOffsetSeconds = try c.decode(Int.self, forKey: .timeZoneOffsetSeconds)
        segmentID = try c.decode(UUID.self, forKey: .segmentID)
        chargePercent = try c.decodeIfPresent(Double.self, forKey: .chargePercent)
        temperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .temperatureCelsius)
        batteryPowerWatts = try c.decodeIfPresent(Double.self, forKey: .batteryPowerWatts)
        capacityRetentionPercent = try c.decodeIfPresent(Double.self, forKey: .capacityRetentionPercent)
        cycleCount = try c.decodeIfPresent(Int.self, forKey: .cycleCount)
        isCharging = try c.decodeIfPresent(Bool.self, forKey: .isCharging)
        isExternalPower = try c.decodeIfPresent(Bool.self, forKey: .isExternalPower)
        isAggregate = try c.decode(Bool.self, forKey: .isAggregate)
        aggregateCount = try c.decode(Int.self, forKey: .aggregateCount)
        readings = decoder.userInfo[.skipHistoryReadings] as? Bool == true ? [] : try c.decode([CatalogReading].self, forKey: .readings)
        observedFrom = try c.decode(Date.self, forKey: .observedFrom)
        coveredSeconds = try c.decode(Double.self, forKey: .coveredSeconds)
        energyEvidenceVersion = try c.decodeIfPresent(Int.self, forKey: .energyEvidenceVersion)
        chargedWh = try c.decodeIfPresent(Double.self, forKey: .chargedWh)
        dischargedWh = try c.decodeIfPresent(Double.self, forKey: .dischargedWh)
        externalPowerSeconds = try c.decode(Double.self, forKey: .externalPowerSeconds)
    }
}
/// A private-history projection. Battery identity is never part of this value.
public struct WeeklyCapacity: Codable, Sendable, Equatable {
    public let percent: Double
    public let observedDays: Int
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let publishedAt: Date
    public var nextEligibleAt: Date { publishedAt.addingTimeInterval(7 * 86400) }
}

public struct HistorySession: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let segmentID: UUID
    public let kind: String
    public let observedFrom: Date
    public let endedAt: Date?
    public let originalStartKnown: Bool
}
public struct HistorySummary: Codable, Sendable, Equatable {
    public let monitoringStart: Date?
    public let sampleCount: Int
    public let gaps: [HistoryGap]
    public let sessions: [HistorySession]
    public let observedExternalPowerSeconds: TimeInterval
    public let estimatedChargedWh: Double?
    public let estimatedDischargedWh: Double?
    public let coveredSeconds: TimeInterval
    public let chargingSessionCount: Int
}
public enum HistoryStoreError: Error, LocalizedError, Sendable, Equatable {
    case unavailable, corruptRecord, unsupportedSchema, simulationExcluded
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The local history store is unavailable. Existing files were preserved."
        case .corruptRecord: return "A history record is invalid; existing data was preserved."
        case .unsupportedSchema: return "This history schema is not supported by this app version."
        case .simulationExcluded: return "Simulation samples are excluded from live history."
        }
    }
}
