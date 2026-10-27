import Foundation
import PowerCore

public struct HistoryConfiguration: Sendable, Equatable {
    public var retentionDays: Int
    public var maximumSamples: Int
    public var maximumGapSeconds: TimeInterval
    public var detailedDays: Int
    public var aggregateIntervalSeconds: TimeInterval
    public init(retentionDays: Int = 365, maximumSamples: Int = 60000, maximumGapSeconds: TimeInterval = 120,
                detailedDays: Int = 30, aggregateIntervalSeconds: TimeInterval = 3600) {
        self.retentionDays = min(365, max(1, retentionDays))
        self.maximumSamples = min(100000, max(2, maximumSamples))
        self.maximumGapSeconds = max(1, maximumGapSeconds.isFinite ? maximumGapSeconds : 120)
        self.detailedDays = min(self.retentionDays, max(0, detailedDays))
        self.aggregateIntervalSeconds = max(1, aggregateIntervalSeconds.isFinite ? aggregateIntervalSeconds : 3600)
    }
}
public enum HistoryGapReason: String, Codable, Sendable {
    case sleep, offline, providerUnavailable, batteryReplacement, clockChange, launch, explicitBoundary
}
public struct HistoryGap: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let reason: HistoryGapReason
    public init(start: Date, end: Date, reason: HistoryGapReason) {
        self.id = UUID(); self.start = start; self.end = end; self.reason = reason
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
