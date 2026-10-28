import Foundation

/// App-observed boundaries use a sleep-inclusive clock supplied by the caller.
public struct SleepObservationStamp: Codable, Sendable, Equatable {
    public let wallDate: Date
    public let continuousSeconds: Double
    public let runID: UUID
    public init(wallDate: Date, continuousSeconds: Double, runID: UUID) {
        self.wallDate = wallDate; self.continuousSeconds = continuousSeconds; self.runID = runID
    }
    public var isValid: Bool { wallDate.timeIntervalSince1970.isFinite && continuousSeconds.isFinite && continuousSeconds >= 0 }
}

/// Raw provider evidence only. Retained display values and simulation cannot become endpoints.
public struct SleepBatteryEndpoint: Codable, Sendable, Equatable {
    public let stamp: SleepObservationStamp
    public let collectedAt: Date
    public let sourceSampleAt: Date?
    public let chargePercent: Double
    public let isExternalPower: Bool?
    public let isCharging: Bool?
    /// Existing salted local identity; never exported by the ordinary history exporter.
    public let batteryIdentityToken: String?
    public let source: String

    public init?(snapshot: BatterySnapshot, stamp: SleepObservationStamp) {
        guard !snapshot.isDemo, stamp.isValid,
              let reading = snapshot.catalog.first(where: { $0.id == "011" }),
              reading.availability == .available, reading.freshness == .fresh,
              let percent = reading.value?.doubleValue, percent.isFinite, (0...100).contains(percent),
              reading.monotonicAgeSeconds.map({ $0 <= 60 && $0 >= 0 && $0.isFinite }) ?? true else { return nil }
        let age = stamp.wallDate.timeIntervalSince(reading.collectedAt)
        guard age.isFinite, age >= -1, age <= 60,
              reading.sourceSampleAt.map({ $0.timeIntervalSince(reading.collectedAt) <= 1 && $0.timeIntervalSince1970.isFinite
                  && stamp.wallDate.timeIntervalSince($0) <= 60 }) ?? true else { return nil }
        func boolean(_ id: String) -> Bool? {
            guard let field = snapshot.catalog.first(where: { $0.id == id }), field.availability == .available,
                  field.freshness == .fresh, abs(field.collectedAt.timeIntervalSince(reading.collectedAt)) <= 60,
                  case .boolean(let value)? = field.value else { return nil }
            return value
        }
        self.stamp = stamp; collectedAt = reading.collectedAt; sourceSampleAt = reading.sourceSampleAt
        chargePercent = percent; isExternalPower = boolean("015"); isCharging = boolean("013")
        batteryIdentityToken = snapshot.batteryIdentityToken.flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
        let sources = ["IOPowerSources", "AppleSmartBattery", "PowerTelemetry", "fixture"]
        source = sources.contains(reading.source) ? reading.source : "Other provider"
    }
    public var measurementContinuousSeconds: Double { stamp.continuousSeconds - max(0, stamp.wallDate.timeIntervalSince(collectedAt)) }
    public var isValid: Bool {
        stamp.isValid && chargePercent.isFinite && (0...100).contains(chargePercent)
            && collectedAt.timeIntervalSince1970.isFinite && stamp.wallDate.timeIntervalSince(collectedAt) >= -1
            && stamp.wallDate.timeIntervalSince(collectedAt) <= 60
            && (sourceSampleAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince(collectedAt) <= 1
                && stamp.wallDate.timeIntervalSince($0) <= 60 } ?? true)
            && (batteryIdentityToken.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? true)
            && ["IOPowerSources", "AppleSmartBattery", "PowerTelemetry", "fixture", "Other provider"].contains(source)
    }
}

public enum SleepSessionPhase: String, Codable, Sendable { case awaitingWake, awaitingReading, closed, incomplete }
public enum SleepSessionIssue: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case preReadingMissing, postReadingMissing, sleepBoundaryMissing, batteryIdentityMissing, batteryIdentityChanged
    case clockChanged, applicationRestarted, applicationStopped, historyDisabled, historyErased, supersededBySleep
}
public enum SleepInterruptionReason: String, Sendable { case applicationRestarted, applicationStopped, historyDisabled, historyErased, supersededBySleep }
public enum SleepPowerEvidence: String, Codable, Sendable { case batteryAtBothObservations, externalPowerObserved, unavailable }

public struct SleepSessionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sleepBoundary: SleepObservationStamp?
    public let wakeBoundary: SleepObservationStamp?
    public let before: SleepBatteryEndpoint?
    public let after: SleepBatteryEndpoint?
    public let phase: SleepSessionPhase
    public let issues: [SleepSessionIssue]
    public let endedAt: SleepObservationStamp?

    public init(id: UUID = UUID(), sleepBoundary: SleepObservationStamp?, wakeBoundary: SleepObservationStamp? = nil,
                before: SleepBatteryEndpoint? = nil, after: SleepBatteryEndpoint? = nil,
                phase: SleepSessionPhase, issues: [SleepSessionIssue] = [], endedAt: SleepObservationStamp? = nil) {
        self.id = id; self.sleepBoundary = sleepBoundary; self.wakeBoundary = wakeBoundary
        self.before = before; self.after = after; self.phase = phase
        self.issues = Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }; self.endedAt = endedAt
    }
    public var isPending: Bool { phase == .awaitingWake || phase == .awaitingReading }
    public var observedAt: Date? { sleepBoundary?.wallDate ?? wakeBoundary?.wallDate }
    public var chargeChangePercentagePoints: Double? {
        guard let before, let after, before.isValid, after.isValid,
              let identity = before.batteryIdentityToken, identity == after.batteryIdentityToken else { return nil }
        return before.chargePercent - after.chargePercent
    }
    public var powerEvidence: SleepPowerEvidence {
        if before?.isExternalPower == true || after?.isExternalPower == true { return .externalPowerObserved }
        if before?.isExternalPower == false && after?.isExternalPower == false { return .batteryAtBothObservations }
        return .unavailable
    }
    public var notificationIntervalSeconds: Double? {
        guard !issues.contains(.clockChanged), let start = sleepBoundary, let end = wakeBoundary else { return nil }
        return Self.duration(start, end)
    }
    public var measurementIntervalSeconds: Double? {
        guard !issues.contains(.clockChanged), let before, let after, before.stamp.runID == after.stamp.runID else { return nil }
        let elapsed = after.measurementContinuousSeconds - before.measurementContinuousSeconds
        let wall = after.collectedAt.timeIntervalSince(before.collectedAt)
        return elapsed > 0 && abs(wall - elapsed) <= 5 ? elapsed : nil
    }
    public func interrupted(reason: SleepInterruptionReason, at stamp: SleepObservationStamp) -> Self {
        guard isPending else { return self }
        var flags = issues + [SleepSessionIssue(rawValue: reason.rawValue)!]
        if after == nil { flags.append(.postReadingMissing) }
        return .init(id: id, sleepBoundary: sleepBoundary, wakeBoundary: wakeBoundary, before: before, after: after,
                     phase: .incomplete, issues: flags, endedAt: stamp)
    }
    public var isValidForPersistence: Bool {
        guard let observedAt, observedAt.timeIntervalSince1970.isFinite,
              [sleepBoundary, wakeBoundary, endedAt].compactMap({ $0 }).allSatisfy(\.isValid),
              [before, after].compactMap({ $0 }).allSatisfy(\.isValid), issues.count <= SleepSessionIssue.allCases.count else { return false }
        if let before {
            guard let sleepBoundary, before.stamp.runID == sleepBoundary.runID else { return false }
            let age = sleepBoundary.continuousSeconds - before.measurementContinuousSeconds
            guard age >= 0, age <= 60 else { return false }
        }
        if let after {
            guard let wakeBoundary, after.stamp.runID == wakeBoundary.runID else { return false }
            let delay = after.stamp.continuousSeconds - wakeBoundary.continuousSeconds
            let measurementDelay = after.measurementContinuousSeconds - wakeBoundary.continuousSeconds
            guard delay >= 0, delay <= 60, measurementDelay >= 0, measurementDelay <= 60 else { return false }
        }
        switch phase {
        case .awaitingWake: return sleepBoundary != nil && wakeBoundary == nil && after == nil && endedAt == nil
        case .awaitingReading: return sleepBoundary != nil && wakeBoundary != nil && after == nil && endedAt == nil
        case .closed: return sleepBoundary != nil && wakeBoundary != nil && after != nil && endedAt != nil
        case .incomplete: return endedAt != nil
        }
    }
    fileprivate static func duration(_ start: SleepObservationStamp, _ end: SleepObservationStamp) -> Double? {
        let continuous = end.continuousSeconds - start.continuousSeconds
        let wall = end.wallDate.timeIntervalSince(start.wallDate)
        return start.runID == end.runID && continuous > 0 && wall > 0 && abs(continuous - wall) <= 5 ? continuous : nil
    }
}

public enum SleepObservationEvent: Sendable {
    case willSleep(stamp: SleepObservationStamp, latestEndpoint: SleepBatteryEndpoint?)
    case didWake(stamp: SleepObservationStamp, epoch: UInt64)
    case freshReading(endpoint: SleepBatteryEndpoint, epoch: UInt64)
    case expire(stamp: SleepObservationStamp)
    case interrupted(reason: SleepInterruptionReason, stamp: SleepObservationStamp)
}

/// No IO, OS inference or hardware writes. A change array preserves both rows on supersession.
public struct SleepSessionTracker: Sendable {
    public private(set) var pending: SleepSessionRecord?
    private var wakeEpoch: UInt64?
    private var lastWasWake = false
    public init() {}
    public mutating func accept(_ event: SleepObservationEvent) -> [SleepSessionRecord] {
        switch event {
        case .willSleep(let stamp, let endpoint):
            guard stamp.isValid else { return [] }
            if pending?.phase == .awaitingWake, pending?.sleepBoundary?.runID == stamp.runID { return [] }
            var changes: [SleepSessionRecord] = []
            if let pending { changes.append(pending.interrupted(reason: pending.sleepBoundary?.runID == stamp.runID ? .supersededBySleep : .applicationRestarted, at: stamp)) }
            let before = endpoint.flatMap { endpoint -> SleepBatteryEndpoint? in
                let elapsed = stamp.continuousSeconds - endpoint.measurementContinuousSeconds
                let wall = stamp.wallDate.timeIntervalSince(endpoint.collectedAt)
                return endpoint.isValid && endpoint.stamp.runID == stamp.runID && elapsed >= 0 && elapsed <= 60
                    && wall >= -1 && wall <= 60 && abs(wall - elapsed) <= 5 ? endpoint : nil
            }
            let record = SleepSessionRecord(sleepBoundary: stamp, before: before, phase: .awaitingWake,
                                            issues: before == nil ? [.preReadingMissing] : [])
            pending = record; wakeEpoch = nil; lastWasWake = false
            return changes + [record]
        case .didWake(let stamp, let epoch):
            guard stamp.isValid, !lastWasWake else { return [] }
            lastWasWake = true
            guard let current = pending, let start = current.sleepBoundary, start.runID == stamp.runID else {
                var changes = pending.map { [$0.interrupted(reason: .applicationRestarted, at: stamp)] } ?? []
                changes.append(.init(sleepBoundary: nil, wakeBoundary: stamp, phase: .incomplete,
                                     issues: [.sleepBoundaryMissing, .preReadingMissing, .postReadingMissing], endedAt: stamp))
                pending = nil; wakeEpoch = nil; return changes
            }
            var flags = current.issues
            if SleepSessionRecord.duration(start, stamp) == nil { flags.append(.clockChanged) }
            let record = SleepSessionRecord(id: current.id, sleepBoundary: start, wakeBoundary: stamp,
                                           before: current.before, phase: .awaitingReading, issues: flags)
            pending = record; wakeEpoch = epoch; return [record]
        case .freshReading(let endpoint, let epoch):
            guard let current = pending, current.phase == .awaitingReading, wakeEpoch == epoch,
                  let wake = current.wakeBoundary, endpoint.isValid, endpoint.stamp.runID == wake.runID else { return [] }
            let elapsed = endpoint.stamp.continuousSeconds - wake.continuousSeconds
            if elapsed > 60 { return accept(.expire(stamp: endpoint.stamp)) }
            let measurementDelay = endpoint.measurementContinuousSeconds - wake.continuousSeconds
            let wallDelay = endpoint.collectedAt.timeIntervalSince(wake.wallDate)
            guard elapsed >= 0, measurementDelay >= 0, measurementDelay <= 60,
                  wallDelay >= -1, wallDelay <= 60 else { return [] }
            var flags = current.issues
            if abs(wallDelay - measurementDelay) > 5 { flags.append(.clockChanged) }
            if let before = current.before {
                if before.batteryIdentityToken == nil || endpoint.batteryIdentityToken == nil { flags.append(.batteryIdentityMissing) }
                else if before.batteryIdentityToken != endpoint.batteryIdentityToken { flags.append(.batteryIdentityChanged) }
                if SleepSessionRecord.duration(before.stamp, endpoint.stamp) == nil { flags.append(.clockChanged) }
            }
            let record = SleepSessionRecord(id: current.id, sleepBoundary: current.sleepBoundary, wakeBoundary: wake,
                before: current.before, after: endpoint, phase: .closed, issues: flags, endedAt: endpoint.stamp)
            pending = nil; wakeEpoch = nil; return [record]
        case .expire(let stamp):
            guard let current = pending, current.phase == .awaitingReading, let wake = current.wakeBoundary,
                  stamp.isValid, stamp.runID == wake.runID, stamp.continuousSeconds - wake.continuousSeconds > 60 else { return [] }
            let record = SleepSessionRecord(id: current.id, sleepBoundary: current.sleepBoundary, wakeBoundary: wake,
                before: current.before, phase: .incomplete, issues: current.issues + [.postReadingMissing], endedAt: stamp)
            pending = nil; wakeEpoch = nil; return [record]
        case .interrupted(let reason, let stamp):
            guard let current = pending, stamp.isValid else { return [] }
            pending = nil; wakeEpoch = nil; return [current.interrupted(reason: reason, at: stamp)]
        }
    }
}
