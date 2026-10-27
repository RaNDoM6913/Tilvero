import Foundation

public enum PowerProfileSource: String, Codable, Sendable, CaseIterable { case battery, adapter }
public enum EnergyMode: String, Codable, Sendable, CaseIterable { case automatic, low, high }
public struct PowerProfile: Codable, Sendable, Equatable {
    public var name: String
    public var chargeTarget: Int?
    public var mode: EnergyMode
    public var fanPolicy: FanPolicy
    public var oneShotFullCharge: Bool
    public init(name: String, chargeTarget: Int? = nil, mode: EnergyMode = .automatic, fanPolicy: FanPolicy = .systemAuto, oneShotFullCharge: Bool = false) {
        self.name = String(name.prefix(80)); self.chargeTarget = chargeTarget; self.mode = mode; self.fanPolicy = fanPolicy
        self.oneShotFullCharge = oneShotFullCharge
    }
}
public enum MissedSchedulePolicy: String, Codable, Sendable { case skip, applyOnceWhenAvailable }
public struct ScheduleRule: Codable, Sendable, Equatable {
    public let id: UUID
    public let fireDate: Date
    public let profile: PowerProfile
    public let missedPolicy: MissedSchedulePolicy
    public init(id: UUID = UUID(), fireDate: Date, profile: PowerProfile, missedPolicy: MissedSchedulePolicy) throws {
        guard fireDate.timeIntervalSince1970.isFinite else { throw PolicyError.invalidPolicy }
        self.id = id; self.fireDate = fireDate; self.profile = profile; self.missedPolicy = missedPolicy
    }
}
public struct ProfileArbiter: Codable, Sendable {
    private var profiles: [PowerProfileSource: PowerProfile] = [:]
    private var completed: Set<UUID> = []
    private var lastManualAction: Date?
    public var restoring = false
    public init() {}
    public mutating func set(_ profile: PowerProfile, for source: PowerProfileSource) { profiles[source] = profile }
    public func profile(for source: PowerProfileSource) -> PowerProfile? { profiles[source] }
    public mutating func recordManualAction(at date: Date) { lastManualAction = date }
    /// Called only when the process is awake; no wake events or background launches are scheduled.
    public mutating func evaluate(_ rule: ScheduleRule, now: Date) -> PowerProfile? {
        guard !restoring, now >= rule.fireDate, !completed.contains(rule.id) else { return nil }
        completed.insert(rule.id)
        guard lastManualAction.map({ $0 < rule.fireDate }) ?? true else { return nil }
        guard rule.missedPolicy == .applyOnceWhenAvailable || now.timeIntervalSince(rule.fireDate) <= 60 else { return nil }
        return rule.profile
    }
}

public struct ProfileApplicationResult: Codable, Sendable, Equatable {
    public var charge: String?
    public var powerMode: String?
    public var fans: String?
    public var isComplete: Bool { charge == nil && powerMode == nil && fans == nil }
    public init(charge: String? = nil, powerMode: String? = nil, fans: String? = nil) { self.charge = charge; self.powerMode = powerMode; self.fans = fans }
}
