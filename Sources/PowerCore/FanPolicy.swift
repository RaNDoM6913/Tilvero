import Foundation

public struct FanDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let minimumRPM: Int
    public let maximumRPM: Int
    public init(id: String, minimumRPM: Int, maximumRPM: Int) { self.id = id; self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM }
    public func accepts(_ rpm: Int) -> Bool { minimumRPM > 0 && minimumRPM < maximumRPM && (minimumRPM...maximumRPM).contains(rpm) }
}

public struct FanCurve: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public let celsius: Double; public let rpm: Int
        public init(celsius: Double, rpm: Int) { self.celsius = celsius; self.rpm = rpm }
    }
    public let points: [Point]
    public init(points: [Point]) throws {
        guard (2...16).contains(points.count), points.allSatisfy({ $0.celsius.isFinite && (0...120).contains($0.celsius) && $0.rpm > 0 }),
              zip(points, points.dropFirst()).allSatisfy({ $0.celsius < $1.celsius && $0.rpm <= $1.rpm }) else { throw PolicyError.invalidPolicy }
        self.points = points
    }
    public func rpm(at celsius: Double) -> Int {
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.rpm }; if celsius >= last.celsius { return last.rpm }
        for (lower, upper) in zip(points, points.dropFirst()) where celsius <= upper.celsius {
            let fraction = (celsius - lower.celsius) / (upper.celsius - lower.celsius)
            return Int((Double(lower.rpm) + fraction * Double(upper.rpm - lower.rpm)).rounded())
        }
        return last.rpm
    }
}

public enum FanPolicy: Codable, Sendable, Equatable { case systemAuto, manual([String: Int]), curve(FanCurve), boost(rpm: Int, seconds: Double) }
public enum FanPhase: String, Codable, Sendable { case systemAuto, acquiring, managed, releasing, recoveryRequired }
public struct FanPolicyState: Codable, Sendable, Equatable {
    public var requested: FanPolicy = .systemAuto
    public var phase: FanPhase = .systemAuto
    public var generation: UInt64 = 0
    public var appliedRPM: [String: Int] = [:]
    public var observedRPM: [String: Int] = [:]
    public var reason: String?
    public init() {}
}
public enum FanEffect: Codable, Sendable, Equatable {
    case setRPM([String: Int], generation: UInt64)
    case systemAuto(generation: UInt64)
    public var generation: UInt64 { switch self { case let .setRPM(_, generation), let .systemAuto(generation): generation } }
}

/// Time is monotonic elapsed seconds supplied by the controller, never wall-clock dates.
public struct FanPolicyEngine: Sendable {
    public let fans: [FanDescriptor]
    public private(set) var state = FanPolicyState()
    private var leaseExpiry: Double?
    private var boostExpiry: Double?
    private var lastCurveTemperature: Double?
    private var lastWriteTime: Double?
    private var pending: FanEffect?
    public init(fans: [FanDescriptor]) { self.fans = fans }

    public mutating func submit(_ policy: FanPolicy, now: Double, leaseSeconds: Double = 15) throws -> [FanEffect] {
        guard now.isFinite, (1...60).contains(leaseSeconds) else { throw PolicyError.invalidPolicy }
        if policy == .systemAuto { return release(reason: nil) }
        guard !fans.isEmpty, Set(fans.map(\.id)).count == fans.count else { throw PolicyError.unavailable }
        let targets: [String: Int]
        switch policy {
        case let .manual(values): targets = values
        case let .boost(rpm, seconds):
            guard seconds.isFinite, (1...300).contains(seconds) else { throw PolicyError.invalidPolicy }
            targets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, rpm) })
        case let .curve(curve): targets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, curve.points.first?.rpm ?? 0) })
        case .systemAuto: return []
        }
        try validate(targets)
        if case let .curve(curve) = policy { for point in curve.points { try validate(Dictionary(uniqueKeysWithValues: fans.map { ($0.id, point.rpm) })) } }
        state.generation &+= 1; state.requested = policy; state.phase = .acquiring; state.reason = nil
        leaseExpiry = now + leaseSeconds; lastWriteTime = now; lastCurveTemperature = nil
        if case let .boost(_, seconds) = policy { boostExpiry = now + seconds } else { boostExpiry = nil }
        // A curve must receive its actual controlling sensor before making any write.
        if case .curve = policy { pending = nil; return [] }
        let effect = FanEffect.setRPM(targets, generation: state.generation); pending = effect; return [effect]
    }

    public mutating func renewLease(now: Double, seconds: Double = 15) throws {
        guard now.isFinite, (1...60).contains(seconds), state.requested != .systemAuto else { throw PolicyError.invalidPolicy }
        leaseExpiry = now + seconds
    }

    public mutating func tick(now: Double, sensorTemperature: Double?, sensorFresh: Bool, sleeping: Bool = false, externalConflict: Bool = false) -> [FanEffect] {
        guard state.requested != .systemAuto else { return [] }
        guard now.isFinite, !sleeping, !externalConflict, leaseExpiry.map({ now < $0 }) == true,
              boostExpiry.map({ now < $0 }) ?? true else { return release(reason: "Control lease expired, sleep began, or a competing controller was detected.") }
        if case let .curve(curve) = state.requested {
            guard sensorFresh, let temperature = sensorTemperature, temperature.isFinite, (0...120).contains(temperature) else { return release(reason: "The controlling temperature sensor is missing or stale.") }
            guard pending == nil, lastWriteTime.map({ now - $0 >= 1 }) ?? true else { return [] }
            if let previous = lastCurveTemperature, abs(previous - temperature) < 2 { return [] }
            let targets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, curve.rpm(at: temperature)) })
            guard (try? validate(targets)) != nil else { return release(reason: "Curve exceeded validated fan bounds.") }
            lastCurveTemperature = temperature; lastWriteTime = now
            if targets == state.appliedRPM { return [] }
            state.generation &+= 1
            let effect = FanEffect.setRPM(targets, generation: state.generation); pending = effect; return [effect]
        }
        return []
    }

    public mutating func acknowledge(_ effect: FanEffect, observedRPM: [String: Int], auto: Bool) throws {
        guard effect.generation == state.generation, effect == pending else { throw PolicyError.staleGeneration }
        switch effect {
        case let .setRPM(targets, _):
            guard !auto, targets.allSatisfy({ entry in observedRPM[entry.key].map { abs($0 - entry.value) <= 250 } ?? false }) else {
                state.phase = .recoveryRequired; state.reason = "Fan readback diverged; Auto recovery is required."; throw PolicyError.readbackMismatch
            }
            state.appliedRPM = targets; state.observedRPM = observedRPM; state.phase = .managed
        case .systemAuto:
            guard auto else { state.phase = .recoveryRequired; throw PolicyError.readbackMismatch }
            state.appliedRPM = [:]; state.observedRPM = observedRPM; state.phase = .systemAuto
        }
        pending = nil
    }

    public mutating func release(reason: String?) -> [FanEffect] {
        guard state.phase != .systemAuto || state.requested != .systemAuto else { return [] }
        state.generation &+= 1; state.requested = .systemAuto; state.phase = .releasing; state.reason = reason
        leaseExpiry = nil; boostExpiry = nil; lastCurveTemperature = nil
        let effect = FanEffect.systemAuto(generation: state.generation); pending = effect; return [effect]
    }
    public mutating func markRecoveryRequired(reason: String) {
        state.generation &+= 1; state.requested = .systemAuto; state.phase = .recoveryRequired; state.reason = reason
        pending = nil; leaseExpiry = nil; boostExpiry = nil
    }
    private func validate(_ targets: [String: Int]) throws {
        guard targets.count == fans.count, fans.allSatisfy({ fan in targets[fan.id].map(fan.accepts) == true }) else { throw PolicyError.invalidPolicy }
    }
}
