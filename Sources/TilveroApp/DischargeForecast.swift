import Foundation

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
    }
    static func estimate(_ samples: [Sample], currentPercent: Int?, currentFresh: Bool, onBattery: Bool, now: Date = Date()) -> Estimate? {
        guard currentFresh, onBattery, let current = currentPercent, (0...100).contains(current),
              let latest = samples.last, let latestPercent = latest.percent,
              now.timeIntervalSince(latest.date) >= -5, now.timeIntervalSince(latest.date) <= 120,
              abs(Double(current) - latestPercent) <= 1.5 else { return nil }
        if current <= 20 { return .init(lowerSeconds: 0, upperSeconds: 0, observedSeconds: 0) }
        var segment: [Sample] = []
        for value in samples.reversed() {
            guard !value.aggregate, value.segment == latest.segment, value.externalPower == false, value.charging == false,
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
        return .init(lowerSeconds: lower, upperSeconds: upper, observedSeconds: duration)
    }
}
