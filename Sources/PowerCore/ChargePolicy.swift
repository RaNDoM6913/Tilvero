import Foundation

public enum PolicyError: Error, Equatable, Sendable {
    case invalidContract, unsupportedTarget, staleGeneration, readbackMismatch, unavailable, invalidPolicy
}

public enum ChargeIntent: Codable, Sendable, Equatable {
    case ceiling(Int)
    case fullOnce
    case system
}

public enum ChargePhase: String, Codable, Sendable { case observing, applying, managed, pendingLowerLimit, systemOverride, externalChange, restoring, fault }

public struct ChargePolicyState: Codable, Sendable, Equatable {
    public var requested: ChargeIntent?
    public var appliedTarget: Int?
    public var pendingTarget: Int?
    public var phase: ChargePhase = .observing
    public var generation: UInt64 = 0
    public var reason: String?
    public var observation: ChargeObservation?
    public init() {}
}

public struct ChargeObservation: Codable, Sendable, Equatable {
    public let percent: Int?
    public let externalPower: Bool?
    public let fresh: Bool
    public let effectiveTarget: Int?
    public let systemOverride: Bool
    public let isCharging: Bool?
    public let fullyCharged: Bool?
    public init(percent: Int?, externalPower: Bool?, fresh: Bool = true, effectiveTarget: Int? = nil, systemOverride: Bool = false, isCharging: Bool? = nil, fullyCharged: Bool? = nil) {
        self.percent = percent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.externalPower = externalPower; self.fresh = fresh
        self.effectiveTarget = effectiveTarget.flatMap { (0...100).contains($0) ? $0 : nil }
        self.systemOverride = systemOverride; self.isCharging = isCharging
        self.fullyCharged = fullyCharged
    }
}

public enum ChargeEffect: Codable, Sendable, Equatable {
    case apply(target: Int, generation: UInt64)
    case restore(generation: UInt64)
    public var generation: UInt64 { switch self { case let .apply(_, generation), let .restore(generation): generation } }
}

/// Deterministic domain policy. Effects are intentions; only independent readback acknowledges application.
public struct ChargePolicyEngine: Codable, Sendable {
    public let acceptedTargets: [Int]
    private let loweringRawValue: String
    public var loweringBehavior: LoweringBehavior { LoweringBehavior(rawValue: loweringRawValue) ?? .unknown }
    public private(set) var state = ChargePolicyState()
    private var previousOneShotIntent: ChargeIntent?
    private var previousPendingIntent: ChargeIntent?
    private var inFlight: ChargeEffect?
    private var superseded: [ChargeEffect] = []
    private var lateTargets: Set<Int> = []
    private enum CodingKeys: String, CodingKey { case version, acceptedTargets, loweringBehavior, state, previousOneShotIntent, previousPendingIntent, inFlight, superseded, lateTargets }

    public init(acceptedTargets: [Int], loweringBehavior: LoweringBehavior) throws {
        guard !acceptedTargets.isEmpty, acceptedTargets == acceptedTargets.sorted(), Set(acceptedTargets).count == acceptedTargets.count,
              acceptedTargets.allSatisfy({ (1...100).contains($0) }) else { throw PolicyError.invalidContract }
        self.acceptedTargets = acceptedTargets; loweringRawValue = loweringBehavior.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw PolicyError.invalidContract }
        let targets = try values.decode([Int].self, forKey: .acceptedTargets)
        let lowering = try values.decode(String.self, forKey: .loweringBehavior)
        guard let behavior = LoweringBehavior(rawValue: lowering) else { throw PolicyError.invalidContract }
        try self.init(acceptedTargets: targets, loweringBehavior: behavior)
        state = try values.decode(ChargePolicyState.self, forKey: .state)
        previousOneShotIntent = try values.decodeIfPresent(ChargeIntent.self, forKey: .previousOneShotIntent)
        previousPendingIntent = try values.decodeIfPresent(ChargeIntent.self, forKey: .previousPendingIntent)
        inFlight = try values.decodeIfPresent(ChargeEffect.self, forKey: .inFlight)
        superseded = try values.decodeIfPresent([ChargeEffect].self, forKey: .superseded) ?? []
        lateTargets = try values.decodeIfPresent(Set<Int>.self, forKey: .lateTargets) ?? []
        for intent in [state.requested, previousOneShotIntent, previousPendingIntent].compactMap({ $0 }) {
            if case let .ceiling(target) = intent, !targets.contains(target) { throw PolicyError.unsupportedTarget }
            if intent == .fullOnce && !targets.contains(100) { throw PolicyError.unsupportedTarget }
        }
        guard state.generation < UInt64.max - 1,
              state.pendingTarget.map(targets.contains) ?? true,
              state.appliedTarget.map({ (1...100).contains($0) }) ?? true,
              inFlight.map({ $0.generation == state.generation }) ?? true else { throw PolicyError.invalidContract }
        if case let .apply(target, _) = inFlight, !targets.contains(target) { throw PolicyError.unsupportedTarget }
        guard superseded.count <= 64, superseded.allSatisfy({ $0.generation < state.generation }), lateTargets.allSatisfy({ (1...100).contains($0) }) else { throw PolicyError.invalidContract }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version); try values.encode(acceptedTargets, forKey: .acceptedTargets)
        try values.encode(loweringRawValue, forKey: .loweringBehavior); try values.encode(state, forKey: .state)
        try values.encodeIfPresent(previousOneShotIntent, forKey: .previousOneShotIntent)
        try values.encodeIfPresent(previousPendingIntent, forKey: .previousPendingIntent); try values.encodeIfPresent(inFlight, forKey: .inFlight)
        try values.encode(superseded, forKey: .superseded); try values.encode(lateTargets, forKey: .lateTargets)
    }

    public mutating func submit(_ intent: ChargeIntent, observation: ChargeObservation) throws -> [ChargeEffect] {
        if case let .ceiling(target) = intent, !acceptedTargets.contains(target) { throw PolicyError.unsupportedTarget }
        if intent == .fullOnce, !acceptedTargets.contains(100) { throw PolicyError.unsupportedTarget }
        if state.requested == intent, state.phase != .fault && state.phase != .externalChange { return [] }
        let before = state.requested
        if intent == .fullOnce, state.requested != .fullOnce { previousOneShotIntent = before }
        else if intent != .fullOnce { previousOneShotIntent = nil }
        if state.pendingTarget == nil { previousPendingIntent = before }
        if let inFlight { superseded.append(inFlight) }
        guard superseded.count <= 64 else { throw PolicyError.invalidPolicy }
        state.requested = intent; state.generation &+= 1; state.reason = nil
        state.observation = observation; inFlight = nil
        return decide(observation)
    }

    public mutating func cancelPending() throws -> [ChargeEffect] {
        guard state.pendingTarget != nil else { return [] }
        state.generation &+= 1
        state.requested = previousPendingIntent
        state.pendingTarget = nil
        previousPendingIntent = nil; inFlight = nil
        guard state.requested != nil else { state.phase = .observing; return [] }
        return decide(state.observation ?? .init(percent: nil, externalPower: nil, fresh: false))
    }

    public mutating func cancelOneShot(observation: ChargeObservation) -> [ChargeEffect] {
        guard state.requested == .fullOnce else { return [] }
        return returnFromOneShot(observation)
    }

    public mutating func observe(_ observation: ChargeObservation) -> [ChargeEffect] {
        state.observation = observation
        guard observation.fresh else { state.reason = "Fresh observations are required before policy transitions."; return [] }
        if state.requested == .fullOnce,
           observation.externalPower == false || (observation.fullyCharged == true && observation.isCharging == false) {
            return returnFromOneShot(observation)
        }
        if observation.systemOverride, state.requested != nil {
            state.phase = .systemOverride; state.reason = "macOS is temporarily overriding charging for battery maintenance."; return []
        }
        if inFlight == nil, let effective = observation.effectiveTarget {
            if let applied = state.appliedTarget, effective != applied, state.requested != nil {
                let expectedLateChange = lateTargets.contains(effective) || superseded.contains { if case let .apply(target, _) = $0 { target == effective } else { false } }
                if expectedLateChange {
                    state.appliedTarget = effective; state.phase = .applying
                    return decide(observation)
                }
                state.appliedTarget = effective; state.phase = .externalChange
                state.reason = "An external controller changed the effective setting. Explicit reconciliation is required."; return []
            }
            state.appliedTarget = effective
            if superseded.isEmpty { lateTargets.removeAll() }
        }
        guard state.phase != .externalChange, state.phase != .fault, inFlight == nil else { return [] }
        if state.phase == .systemOverride { state.phase = state.pendingTarget == nil ? .managed : .pendingLowerLimit; state.reason = nil }
        if state.pendingTarget != nil { return decide(observation) }
        return []
    }

    public mutating func acknowledge(_ effect: ChargeEffect, effectiveTarget: Int?, restorationVerified: Bool = false) throws {
        guard effect.generation == state.generation, inFlight == effect else {
            if let index = superseded.firstIndex(of: effect) {
                superseded.remove(at: index)
                if let effectiveTarget, (1...100).contains(effectiveTarget) { lateTargets.insert(effectiveTarget) }
            }
            throw PolicyError.staleGeneration
        }
        switch effect {
        case let .apply(target, _):
            guard effectiveTarget == target else { fail(generation: effect.generation, reason: "Applied setting did not match readback."); throw PolicyError.readbackMismatch }
            state.appliedTarget = effectiveTarget; state.pendingTarget = nil; state.phase = .managed
        case .restore:
            guard restorationVerified else { fail(generation: effect.generation, reason: "Original settings restoration remains unverified."); throw PolicyError.readbackMismatch }
            state.appliedTarget = effectiveTarget; state.pendingTarget = nil; state.requested = nil; state.phase = .observing
        }
        inFlight = nil; state.reason = nil
    }

    public mutating func fail(generation: UInt64, reason: String) {
        guard generation == state.generation else { return }
        inFlight = nil; state.phase = .fault; state.reason = String(reason.prefix(512))
    }

    /// A transient full-charge intent is cancelled after relaunch; the prior app intent still follows drain deferral.
    public mutating func restart(observation: ChargeObservation) -> [ChargeEffect] {
        inFlight = nil; state.generation &+= 1
        if state.requested == .fullOnce { return returnFromOneShot(observation) }
        guard state.requested != nil else { state.phase = .observing; return [] }
        return decide(observation)
    }

    private mutating func returnFromOneShot(_ observation: ChargeObservation) -> [ChargeEffect] {
        if let inFlight { superseded.append(inFlight) }
        state.requested = previousOneShotIntent ?? .system
        previousOneShotIntent = nil; state.generation &+= 1; inFlight = nil
        previousPendingIntent = state.appliedTarget.map(ChargeIntent.ceiling)
        return decide(observation)
    }

    private mutating func decide(_ observation: ChargeObservation) -> [ChargeEffect] {
        guard let intent = state.requested else { return [] }
        if intent == .system {
            state.pendingTarget = nil; state.phase = .restoring
            let effect = ChargeEffect.restore(generation: state.generation); inFlight = effect; return [effect]
        }
        let target: Int
        switch intent { case let .ceiling(value): target = value; case .fullOnce: target = 100; case .system: return [] }
        guard observation.fresh, observation.percent != nil else {
            state.pendingTarget = target; state.phase = .pendingLowerLimit; state.reason = "Waiting for a fresh battery level."; return []
        }
        if loweringBehavior != .no, target < 100, observation.percent! > target {
            state.pendingTarget = target; state.phase = .pendingLowerLimit
            state.reason = "Waiting for natural discharge. The existing effective limit remains in force."; return []
        }
        if state.appliedTarget == target, superseded.isEmpty, lateTargets.isEmpty { state.pendingTarget = nil; state.phase = .managed; return [] }
        state.pendingTarget = nil; state.phase = .applying; state.reason = nil
        let effect = ChargeEffect.apply(target: target, generation: state.generation); inFlight = effect; return [effect]
    }
}
