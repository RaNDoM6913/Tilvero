// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore

/// An extrapolation of a recent continuous discharge, not a battery-life promise.
enum DischargeForecast {
    struct Sample: Sendable {
        let date: Date
        let percent: Double?
        let segment: String
        let externalPower: Bool?
        let charging: Bool?
        let monotonic: Double?
        var aggregate = false
    }
    struct Estimate: Sendable {
        let lowerSeconds: Double
        let upperSeconds: Double
        let observedSeconds: Double
        /// The straight extrapolation of the observed rate (between the bounds).
        var seconds: Double = 0
        /// The observed discharge, oldest first (the chart draws it before the dashed extrapolation).
        var points: [(date: Date, percent: Double)] = []
    }
    /// An app relaunch inside a discharge: the history starts a new segment, but nothing was missed when the gap was
    /// this short and the clocks agree, so the forecast may continue across it. Other boundaries (sleep, battery
    /// replacement, clock change, offline) always end the observed discharge.
    struct LaunchBoundary: Sendable {
        let start: Date
        let end: Date
        func joins(older: Date, newer: Date) -> Bool {
            abs(start.timeIntervalSince(older)) < 2 && abs(end.timeIntervalSince(newer)) < 2
        }
    }
    /// Current-reading gates for `estimate`. IOPowerSources rows with unknown source freshness count
    /// when the app collected them just now (`CurrentObservation`); retained or stale values never do.
    /// Typed readings are stamped with the snapshot's own time, so here the source/key-path checks (not the
    /// 60 s window) are what gate the input; `estimate` separately bounds the history age.
    static func currentInputs(_ snapshot: BatterySnapshot) -> (percent: Int?, fresh: Bool, onBattery: Bool) {
        let at = snapshot.collectedAt
        return (snapshot.chargePercent.value,
                snapshot.chargePercent.isCurrentObservation(catalogID: "011", at: at),
                snapshot.isExternalPower.isCurrentObservation(catalogID: "015", at: at) && snapshot.isExternalPower.value == false)
    }
    static func estimate(_ samples: [Sample], currentPercent: Int?, currentFresh: Bool, onBattery: Bool, now: Date = Date(),
                         launches: [LaunchBoundary] = []) -> Estimate? {
        guard currentFresh, onBattery, let current = currentPercent, (0...100).contains(current),
              let latest = samples.last, let latestPercent = latest.percent,
              now.timeIntervalSince(latest.date) >= -5, now.timeIntervalSince(latest.date) <= 120,
              abs(Double(current) - latestPercent) <= 1.5 else { return nil }
        if current <= 20 { return .init(lowerSeconds: 0, upperSeconds: 0, observedSeconds: 0) }
        var segment: [Sample] = []
        var currentSegment = latest.segment
        for value in samples.reversed() {
            if value.segment != currentSegment {
                guard let newer = segment.last, launches.contains(where: { $0.joins(older: value.date, newer: newer.date) }) else { break }
                currentSegment = value.segment
            }
            guard !value.aggregate, value.externalPower == false, value.charging == false,
                  let percent = value.percent, percent.isFinite, (0...100).contains(percent),
                  latest.date.timeIntervalSince(value.date) <= 7200 else { break }
            if let newer = segment.last {
                let delta = newer.date.timeIntervalSince(value.date)
                guard delta > 0 && delta <= 120, let newerPercent = newer.percent, percent >= newerPercent - 0.2 else { break }
                if let a = value.monotonic, let b = newer.monotonic {
                    guard b > a && abs((b - a) - delta) < 5 else { break }
                } else if value.monotonic != nil || newer.monotonic != nil { break }
            }
            segment.append(value)
        }
        guard segment.count >= 6, let first = segment.last, let firstPercent = first.percent else { return nil }
        let duration = latest.date.timeIntervalSince(first.date), loss = firstPercent - latestPercent
        guard duration >= 600, loss >= 3 else { return nil }
        // Endpoint rounding contributes up to one percentage point of loss
        // uncertainty. Future workload variation is explicitly disclosed in UI.
        let lower = max(0, Double(current - 20) - 0.5) * duration / (loss + 1)
        let upper = (Double(current - 20) + 0.5) * duration / (loss - 1)
        guard lower.isFinite, upper.isFinite, upper <= 172800 else { return nil }
        let center = min(max(Double(current - 20) * duration / loss, lower), upper)
        let points = segment.reversed().compactMap { sample in sample.percent.map { (date: sample.date, percent: $0) } }
        return .init(lowerSeconds: lower, upperSeconds: upper, observedSeconds: duration, seconds: center, points: points)
    }
}
