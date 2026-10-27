import Foundation
import PowerCore

public struct SimulationControlSnapshot: Sendable {
    public let charge: ChargePolicyState
    public let fans: FanPolicyState
    public let fanDescriptors: [FanDescriptor]
    public let acceptedTargets: [Int]
    public let isSimulation = true
    public let elapsedSeconds: Double
    public let events: [String]
}

/// Explicit simulator only. This module imports no platform-write backend or privileged service.
public actor SimulationController: ChargeControlling, FanControlling {
    private var charge: ChargePolicyEngine
    private var fans: FanPolicyEngine
    private var observation = ChargeObservation(percent: 76, externalPower: true, effectiveTarget: 100)
    private var effectiveTarget: Int? = 100
    private var elapsed: Double = 0
    private var events: [String] = []
    private let originalTarget: Int? = 100
    private struct Saved: Codable { let charge: ChargePolicyEngine; let observation: ChargeObservation }

    public init(savedState: Data? = nil, fanCount: Int = 2) throws {
        let descriptors = (0..<max(0, min(fanCount, 4))).map { FanDescriptor(id: String($0), minimumRPM: 1200, maximumRPM: 6000) }
        fans = FanPolicyEngine(fans: descriptors)
        if let savedState {
            guard savedState.count <= 65_536 else { throw PolicyError.invalidPolicy }
            let saved = try JSONDecoder().decode(Saved.self, from: savedState)
            charge = saved.charge; observation = saved.observation; effectiveTarget = saved.charge.state.appliedTarget ?? 100
            let effects = charge.restart(observation: observation)
            for effect in effects {
                switch effect {
                case let .apply(target, _): try charge.acknowledge(effect, effectiveTarget: target); effectiveTarget = target
                case .restore: try charge.acknowledge(effect, effectiveTarget: 100, restorationVerified: true); effectiveTarget = 100
                }
            }
        } else { charge = try ChargePolicyEngine(acceptedTargets: Array(80...100), loweringBehavior: .yes) }
    }

    public func snapshot() -> SimulationControlSnapshot {
        SimulationControlSnapshot(charge: charge.state, fans: fans.state, fanDescriptors: fans.fans, acceptedTargets: charge.acceptedTargets, elapsedSeconds: elapsed, events: events)
    }
    public func exportState() throws -> Data { try JSONEncoder().encode(Saved(charge: charge, observation: observation)) }
    public func submit(_ request: ChargeControlRequest) async throws {
        let effects: [ChargeEffect]
        switch request {
        case let .setCeiling(percent): effects = try charge.submit(.ceiling(percent), observation: observation)
        case .chargeToFullOnce: effects = try charge.submit(.fullOnce, observation: observation)
        case .cancelOneShot: effects = charge.cancelOneShot(observation: observation)
        case .returnToSystemControl: effects = try charge.submit(.system, observation: observation)
        }
        try apply(effects)
    }
    public func submit(_ request: FanControlRequest) async throws {
        switch request {
        case .returnToSystemAuto: try setFanPolicy(.systemAuto)
        case let .setManualRPM(fanID, rpm):
            guard fans.fans.contains(where: { $0.id == fanID }) else { throw PolicyError.invalidPolicy }
            var values = Dictionary(uniqueKeysWithValues: fans.fans.map { ($0.id, fans.state.appliedRPM[$0.id] ?? $0.minimumRPM) })
            values[fanID] = rpm; try setFanPolicy(.manual(values))
        }
    }
    public func cancelPendingCharge() throws { try apply(charge.cancelPending()) }
    public func observeCharge(percent: Int?, externalPower: Bool?, fresh: Bool = true, systemOverride: Bool = false, isCharging: Bool? = nil) throws {
        observation = ChargeObservation(percent: percent, externalPower: externalPower, fresh: fresh, effectiveTarget: effectiveTarget, systemOverride: systemOverride, isCharging: isCharging, fullyCharged: percent == 100 && isCharging == false)
        try apply(charge.observe(observation))
    }
    public func setFanPolicy(_ policy: FanPolicy) throws { try applyFans(fans.submit(policy, now: elapsed)) }
    public func renewFanLease(seconds: Double = 15) throws { try fans.renewLease(now: elapsed, seconds: seconds) }
    public func advance(seconds: Double, sensorTemperature: Double? = 50, sensorFresh: Bool = true, sleeping: Bool = false) throws {
        guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw PolicyError.invalidPolicy }
        elapsed += seconds
        try applyFans(fans.tick(now: elapsed, sensorTemperature: sensorTemperature, sensorFresh: sensorFresh, sleeping: sleeping))
    }
    public func applyProfile(_ profile: PowerProfile) async -> ProfileApplicationResult {
        var result = ProfileApplicationResult()
        if profile.oneShotFullCharge {
            do { try await submit(ChargeControlRequest.chargeToFullOnce) } catch { result.charge = String(describing: error) }
        } else if let target = profile.chargeTarget {
            do { try await submit(ChargeControlRequest.setCeiling(percent: target)) } catch { result.charge = String(describing: error) }
        }
        do { try setFanPolicy(profile.fanPolicy) } catch { result.fans = String(describing: error) }
        append("SIMULATED power mode: \(profile.mode.rawValue)")
        return result
    }
    public func releaseAll() async throws {
        try await submit(ChargeControlRequest.returnToSystemControl)
        try setFanPolicy(.systemAuto)
    }
    private func apply(_ effects: [ChargeEffect]) throws {
        for effect in effects {
            switch effect {
            case let .apply(target, _): effectiveTarget = target; try charge.acknowledge(effect, effectiveTarget: target)
            case .restore: effectiveTarget = originalTarget; try charge.acknowledge(effect, effectiveTarget: originalTarget, restorationVerified: true)
            }
            append("SIMULATED \(effect)")
        }
    }
    private func applyFans(_ effects: [FanEffect]) throws {
        for effect in effects {
            switch effect {
            case let .setRPM(values, _): try fans.acknowledge(effect, observedRPM: values, auto: false)
            case .systemAuto: try fans.acknowledge(effect, observedRPM: [:], auto: true)
            }
            append("SIMULATED \(effect)")
        }
    }
    private func append(_ event: String) { events.append(event); if events.count > 100 { events.removeFirst(events.count - 100) } }
}
