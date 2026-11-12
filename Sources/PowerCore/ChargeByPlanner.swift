// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// When must a Mac that holds its charge limit start charging to be at its target by a chosen time?
///
/// A pure estimate, deliberately conservative: the adapter's rated power is derated, what the Mac itself draws is
/// subtracted (a Mac that keeps working while it "sleeps" charges more slowly), the bulk rate is capped relative to
/// the battery's size, charging above 80 % is modelled as a slow taper, the total is stretched by a safety factor, and
/// the result is due `reserveSeconds` (10 minutes) before the requested time. It never claims a measured value: the
/// plan is an estimate and the interface says so.
public enum ChargeByPlanner {
    /// The charge must be finished this long before the requested time.
    public static let reserveSeconds: TimeInterval = 600
    /// Assumed when the adapter's rating is unknown (no adapter connected yet).
    public static let fallbackAdapterWatts = 30.0
    /// A sleeping Mac still draws a little; used when nothing better is known.
    public static let defaultSleepDrawWatts = 3.0
    public static let adapterEfficiency = 0.85
    /// Bulk charging never exceeds this many battery capacities per hour.
    public static let bulkCRate = 0.8
    public static let taperStartPercent = 80.0
    /// Average charging power above 80 % relative to the bulk rate.
    public static let taperPowerFactor = 0.4
    public static let safetyFactor = 1.2

    public struct Input: Equatable, Sendable {
        public var now: Date
        public var deadline: Date
        public var currentPercent: Double
        public var targetPercent: Int
        /// Rated adapter power; nil means unknown and `fallbackAdapterWatts` is assumed.
        public var adapterWatts: Double?
        /// What the Mac itself draws while the charge runs.
        public var systemDrawWatts: Double
        /// Energy of a full battery.
        public var fullEnergyWh: Double
        public init(now: Date, deadline: Date, currentPercent: Double, targetPercent: Int, adapterWatts: Double?,
                    systemDrawWatts: Double = ChargeByPlanner.defaultSleepDrawWatts, fullEnergyWh: Double) {
            self.now = now; self.deadline = deadline; self.currentPercent = currentPercent; self.targetPercent = targetPercent
            self.adapterWatts = adapterWatts; self.systemDrawWatts = systemDrawWatts; self.fullEnergyWh = fullEnergyWh
        }
    }

    public struct Plan: Equatable, Sendable {
        /// When charging has to begin (the limit has to be lifted).
        public let startAt: Date
        /// Where the estimate says the battery stands at `readyBy`, never above the target.
        public let expectedPercentAtReady: Double
        /// The target time minus the reserve.
        public let readyBy: Date
        public let chargeSeconds: TimeInterval
        /// Starting later than now would miss the target.
        public let mustStartNow: Bool
        /// False when even starting now cannot reach the target by `readyBy`.
        public let reachesTarget: Bool
        public let netChargeWatts: Double
        public let adapterAssumed: Bool
        /// The battery is already at or above the target: nothing has to be done.
        public let alreadyReached: Bool
    }

    public static func plan(_ input: Input) -> Plan? {
        guard input.fullEnergyWh.isFinite, input.fullEnergyWh > 5, input.currentPercent.isFinite,
              (0...100).contains(input.currentPercent), (50...100).contains(input.targetPercent),
              input.systemDrawWatts.isFinite, input.systemDrawWatts >= 0 else { return nil }
        let assumed = input.adapterWatts.map { !($0.isFinite && $0 > 0) } ?? true
        let adapter = assumed ? fallbackAdapterWatts : input.adapterWatts!
        let net = max(1.0, adapter * adapterEfficiency - input.systemDrawWatts)
        let bulk = min(net, bulkCRate * input.fullEnergyWh)
        let readyBy = input.deadline.addingTimeInterval(-reserveSeconds)
        let target = Double(input.targetPercent)
        if input.currentPercent >= target {
            return Plan(startAt: readyBy, expectedPercentAtReady: input.currentPercent, readyBy: readyBy, chargeSeconds: 0,
                        mustStartNow: false, reachesTarget: true, netChargeWatts: net, adapterAssumed: assumed, alreadyReached: true)
        }
        let seconds = chargeSeconds(from: input.currentPercent, to: target, bulkWatts: bulk, fullEnergyWh: input.fullEnergyWh) * safetyFactor
        let startAt = readyBy.addingTimeInterval(-seconds)
        let reaches = startAt >= input.now
        var expected = target
        if !reaches {
            let available = max(0, readyBy.timeIntervalSince(input.now)) / safetyFactor
            expected = min(target, percent(from: input.currentPercent, after: available, bulkWatts: bulk, fullEnergyWh: input.fullEnergyWh))
        }
        return Plan(startAt: reaches ? startAt : input.now, expectedPercentAtReady: expected, readyBy: readyBy, chargeSeconds: seconds,
                    mustStartNow: !reaches, reachesTarget: reaches, netChargeWatts: net, adapterAssumed: assumed, alreadyReached: false)
    }

    /// Seconds of charging from `start` to `end` percent (no safety factor).
    static func chargeSeconds(from start: Double, to end: Double, bulkWatts: Double, fullEnergyWh: Double) -> TimeInterval {
        let bulkEnd = min(end, taperStartPercent)
        let bulkPercent = max(0, bulkEnd - start)
        let taperPercent = max(0, end - max(start, taperStartPercent))
        let bulkSeconds = bulkPercent / 100 * fullEnergyWh / bulkWatts * 3600
        let taperSeconds = taperPercent / 100 * fullEnergyWh / (bulkWatts * taperPowerFactor) * 3600
        return bulkSeconds + taperSeconds
    }

    /// The inverse: where the battery stands after `seconds` of charging from `start` percent.
    static func percent(from start: Double, after seconds: TimeInterval, bulkWatts: Double, fullEnergyWh: Double) -> Double {
        var level = start, left = seconds
        if level < taperStartPercent {
            let toTaper = chargeSeconds(from: level, to: taperStartPercent, bulkWatts: bulkWatts, fullEnergyWh: fullEnergyWh)
            if left <= toTaper { return level + left / 3600 * bulkWatts / fullEnergyWh * 100 }
            left -= toTaper; level = taperStartPercent
        }
        return min(100, level + left / 3600 * bulkWatts * taperPowerFactor / fullEnergyWh * 100)
    }
}
