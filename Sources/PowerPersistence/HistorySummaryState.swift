// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// The scalar projection of one stored sample: everything summaries, charts and the weekly capacity need, no catalog.
struct HistoryScalars: Equatable {
    var id: UUID
    var sequence: Int64
    var collectedAt: Date
    var observedFrom: Date
    var segmentID: UUID
    var chargePercent: Double?
    var temperatureCelsius: Double?
    var batteryPowerWatts: Double?
    var capacityRetentionPercent: Double?
    var cycleCount: Int?
    var isCharging: Bool?
    var isExternalPower: Bool?
    var isAggregate: Bool
    var aggregateCount: Int
    var coveredSeconds: Double
    var chargedWh: Double?
    var dischargedWh: Double?
    var externalPowerSeconds: Double

    init(_ sample: HistorySample, sequence: Int64) {
        id = sample.id; self.sequence = sequence; collectedAt = sample.collectedAt; observedFrom = sample.observedFrom
        segmentID = sample.segmentID; chargePercent = sample.chargePercent; temperatureCelsius = sample.temperatureCelsius
        batteryPowerWatts = sample.batteryPowerWatts; capacityRetentionPercent = sample.capacityRetentionPercent
        cycleCount = sample.cycleCount; isCharging = sample.isCharging; isExternalPower = sample.isExternalPower
        isAggregate = sample.isAggregate; aggregateCount = sample.aggregateCount; coveredSeconds = sample.coveredSeconds
        chargedWh = sample.chargedWh; dischargedWh = sample.dischargedWh; externalPowerSeconds = sample.externalPowerSeconds
    }

    init(id: UUID, sequence: Int64, collectedAt: Date, observedFrom: Date, segmentID: UUID, chargePercent: Double?,
         temperatureCelsius: Double?, batteryPowerWatts: Double?, capacityRetentionPercent: Double?, cycleCount: Int?,
         isCharging: Bool?, isExternalPower: Bool?, isAggregate: Bool, aggregateCount: Int, coveredSeconds: Double,
         chargedWh: Double?, dischargedWh: Double?, externalPowerSeconds: Double) {
        self.id = id; self.sequence = sequence; self.collectedAt = collectedAt; self.observedFrom = observedFrom
        self.segmentID = segmentID; self.chargePercent = chargePercent; self.temperatureCelsius = temperatureCelsius
        self.batteryPowerWatts = batteryPowerWatts; self.capacityRetentionPercent = capacityRetentionPercent
        self.cycleCount = cycleCount; self.isCharging = isCharging; self.isExternalPower = isExternalPower
        self.isAggregate = isAggregate; self.aggregateCount = aggregateCount; self.coveredSeconds = coveredSeconds
        self.chargedWh = chargedWh; self.dischargedWh = dischargedWh; self.externalPowerSeconds = externalPowerSeconds
    }

    /// The catalog series 078-081 count retained points that carry a value.
    var seriesValues: [(String, Double?)] {
        [("078", chargePercent), ("079", temperatureCelsius), ("080", batteryPowerWatts), ("081", capacityRetentionPercent)]
    }
    var hasEnergy: Bool { chargedWh != nil || dischargedWh != nil }
}

/// Running totals of the retained samples, kept current on every record and persisted in one small row, so a launch
/// reads the summary instead of decoding the store. Folding every retained sample in sequence order from an empty
/// state gives the same values (`HistoryStoreCore.rebuildSummary`, used only after migration, erase or repair).
struct HistorySummaryState: Codable, Equatable {
    static let currentVersion = 1
    static let sessionKinds = ["charging", "externalPower", "onBattery"]

    struct Series: Codable, Equatable {
        var count: Int
        var latest: Double
        var latestSequence: Int64
    }
    struct Previous: Codable, Equatable {
        var segmentID: UUID
        var collectedAt: Date
        var isCharging: Bool?
        var isExternalPower: Bool?
    }

    var version = currentVersion
    var monitoringStart: Date?
    var sampleCount = 0
    var coveredSeconds = 0.0
    var chargedWh = 0.0
    var dischargedWh = 0.0
    /// Rows with a qualified energy interval; none means "no evidence", never a measured zero.
    var energyRows = 0
    var externalPowerSeconds = 0.0
    var chargingSessionCount = 0
    var series: [String: Series] = [:]
    var open: [String: HistorySession] = [:]
    var previous: Previous?
    /// Sequence of the newest folded sample; a mismatch with the newest stored sample means the state is stale.
    var lastSequence: Int64 = 0
    /// Maintenance bookkeeping: hour buckets before this were aggregated; the last full VACUUM.
    var aggregatedThrough: Date?
    var lastFullVacuum: Date?

    static func active(_ isCharging: Bool?, _ isExternalPower: Bool?, _ kind: String) -> Bool? {
        kind == "charging" ? isCharging : kind == "externalPower" ? isExternalPower : isExternalPower.map { !$0 }
    }

    /// Adds one sample (the next in sequence order) and returns the sessions it closed.
    mutating func fold(_ sample: HistoryScalars) -> [HistorySession] {
        if monitoringStart == nil { monitoringStart = sample.observedFrom }
        sampleCount += sample.aggregateCount; coveredSeconds += sample.coveredSeconds
        if sample.hasEnergy { energyRows += 1 }
        chargedWh += sample.chargedWh ?? 0; dischargedWh += sample.dischargedWh ?? 0
        externalPowerSeconds += sample.externalPowerSeconds
        for (id, value) in sample.seriesValues {
            if let value { series[id] = Series(count: (series[id]?.count ?? 0) + 1, latest: value, latestSequence: sample.sequence) }
        }
        let sameSegment = previous?.segmentID == sample.segmentID
        var closed: [HistorySession] = []
        for kind in Self.sessionKinds {
            let isActive = Self.active(sample.isCharging, sample.isExternalPower, kind)
            if let ongoing = open[kind], !sameSegment || isActive != true {
                closed.append(HistorySession(id: ongoing.id, segmentID: ongoing.segmentID, kind: kind,
                    observedFrom: ongoing.observedFrom, endedAt: sameSegment ? sample.observedFrom : previous?.collectedAt,
                    originalStartKnown: ongoing.originalStartKnown))
                open[kind] = nil
            }
            if isActive == true, open[kind] == nil {
                let known = sameSegment && previous.map { Self.active($0.isCharging, $0.isExternalPower, kind) == false } == true
                open[kind] = Self.session(startingAt: sample, kind: kind, known: known)
                if kind == "charging", known { chargingSessionCount += 1 }
            }
        }
        previous = Previous(segmentID: sample.segmentID, collectedAt: sample.collectedAt,
                            isCharging: sample.isCharging, isExternalPower: sample.isExternalPower)
        lastSequence = max(lastSequence, sample.sequence)
        return closed
    }

    /// A session derived from the sample that started it; the identity is stable across rebuilds.
    static func session(startingAt sample: HistoryScalars, kind: String, known: Bool) -> HistorySession {
        var identity = sample.id.uuid
        identity.0 ^= kind == "charging" ? 1 : kind == "externalPower" ? 2 : 3
        return HistorySession(id: UUID(uuid: identity), segmentID: sample.segmentID, kind: kind,
                              observedFrom: sample.observedFrom, endedAt: nil, originalStartKnown: known)
    }

    /// Takes deleted samples (the oldest ones) out of the totals. Sessions are reconciled separately.
    mutating func subtract(_ removed: [HistoryScalars]) {
        guard !removed.isEmpty else { return }
        for sample in removed {
            sampleCount -= sample.aggregateCount; coveredSeconds -= sample.coveredSeconds
            if sample.hasEnergy { energyRows -= 1 }
            chargedWh -= sample.chargedWh ?? 0; dischargedWh -= sample.dischargedWh ?? 0
            externalPowerSeconds -= sample.externalPowerSeconds
            for (id, value) in sample.seriesValues where value != nil {
                guard var entry = series[id] else { continue }
                entry.count -= 1
                series[id] = entry.count > 0 ? entry : nil
            }
        }
        normalize()
    }

    /// Sums cannot go negative; rounding left by subtraction is cleared when nothing remains.
    mutating func normalize() {
        sampleCount = max(0, sampleCount); energyRows = max(0, energyRows)
        coveredSeconds = max(0, coveredSeconds); externalPowerSeconds = max(0, externalPowerSeconds)
        chargedWh = max(0, chargedWh); dischargedWh = max(0, dischargedWh)
        if energyRows == 0 { chargedWh = 0; dischargedWh = 0 }
        if sampleCount == 0 {
            let keep = (aggregatedThrough, lastFullVacuum)
            self = HistorySummaryState()
            (aggregatedThrough, lastFullVacuum) = keep
        }
    }

    func summary(gaps: [HistoryGap], closed: [HistorySession]) -> HistorySummary {
        let order = Dictionary(uniqueKeysWithValues: Self.sessionKinds.enumerated().map { ($1, $0) })
        let sessions = (closed.suffix(1000) + Self.sessionKinds.compactMap { open[$0] }).enumerated().sorted { a, b in
            a.element.observedFrom != b.element.observedFrom ? a.element.observedFrom < b.element.observedFrom
                : a.element.endedAt != nil && b.element.endedAt == nil ? true
                : a.element.endedAt == nil && b.element.endedAt != nil ? false
                : order[a.element.kind, default: 0] != order[b.element.kind, default: 0] ? order[a.element.kind, default: 0] < order[b.element.kind, default: 0]
                : a.offset < b.offset
        }.map(\.element)
        return HistorySummary(monitoringStart: monitoringStart, sampleCount: sampleCount, gaps: gaps, sessions: sessions,
            observedExternalPowerSeconds: externalPowerSeconds, estimatedChargedWh: energyRows > 0 ? chargedWh : nil,
            estimatedDischargedWh: energyRows > 0 ? dischargedWh : nil, coveredSeconds: coveredSeconds,
            chargingSessionCount: chargingSessionCount)
    }
}
