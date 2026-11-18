// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import PowerCore

/// Registered OS requests are observations, not proof of cutoff or Tilvero ownership.
public struct SystemChargeLimits: Codable, Sendable, Equatable {
    public let manualLimit: Int?
    public let otherLimits: [Int]
    public let manualLimitIsConflicting: Bool
}

public enum SystemChargeLimitParser {
    public static func parse(_ output: String) throws -> SystemChargeLimits {
        guard output.utf8.count <= 65_536 else { throw PolicyError.readbackMismatch }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "No battery level limits set" {
            return .init(manualLimit: nil, otherLimits: [], manualLimitIsConflicting: false)
        }
        let prefix = "Battery level limits:"
        guard text.hasPrefix(prefix),
              let data = String(text.dropFirst(prefix.count)).data(using: .utf8),
              let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw PolicyError.readbackMismatch
        }
        var manual = Set<Int>(), other = Set<Int>()
        func integer(_ value: Any?) -> Int? {
            guard let value else { return nil }
            let string = String(describing: value)
            guard !string.isEmpty, string.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(string)
        }
        for row in rows {
            guard let terminated = integer(row["Terminated"]), (0...1).contains(terminated),
                  let limit = integer(row["chargeSocLimitSoc"]), (1...100).contains(limit),
                  let reason = row["chargeSocLimitReason"] as? String, !reason.isEmpty else {
                throw PolicyError.readbackMismatch
            }
            guard terminated == 0 else { continue }
            if reason == "manualChargeLimit" {
                guard (80...100).contains(limit) else { throw PolicyError.readbackMismatch }
                manual.insert(limit)
            } else { other.insert(limit) }
        }
        return .init(manualLimit: manual.count == 1 ? manual.first : nil,
                     otherLimits: other.sorted(), manualLimitIsConflicting: manual.count > 1)
    }
}

public struct SystemChargeLimitObservation: Codable, Sendable, Equatable {
    public let collectedAt: Date
    public let limits: SystemChargeLimits?
    public static let source = "pmset -g battlimit (read-only)"
    public init(collectedAt: Date = Date(), limits: SystemChargeLimits?) {
        self.collectedAt = collectedAt; self.limits = limits
    }
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(collectedAt)
        return limits != nil && age >= -5 && age <= 65
    }
    /// Reuses an answer the native charge read got within the last few seconds (the same command, read in the same poll
    /// cycle); otherwise runs `pmset -g battlimit` itself and records it. The observation keeps the original read time.
    public static func read(readings: BatteryLimitReadings = .shared, maximumAge: TimeInterval = BatteryLimitReadings.reuseWindow,
                            query: () throws -> String = BatteryLimitReadings.query) -> Self {
        if let recent = readings.recent(maximumAge: maximumAge) {
            return .init(collectedAt: recent.collectedAt, limits: try? SystemChargeLimitParser.parse(recent.output))
        }
        let collectedAt = Date()
        guard let output = try? query() else { return .init(collectedAt: collectedAt, limits: nil) }
        readings.record(output, collectedAt: collectedAt)
        return .init(collectedAt: collectedAt, limits: try? SystemChargeLimitParser.parse(output))
    }
}

/// The latest `pmset -g battlimit` answer, so one poll cycle launches the command once: the native charge read runs it
/// and records the answer, and the read-only system observation that follows reuses it. Only that observation reuses
/// it; the native read, and with it every readback before and after a native write, always runs the command itself.
public final class BatteryLimitReadings: @unchecked Sendable {
    public static let shared = BatteryLimitReadings()
    /// Long enough to span one poll cycle, short enough that a change made elsewhere shows up on the next one.
    public static let reuseWindow: TimeInterval = 5
    public static func query() throws -> String { try BoundedProcess.read(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"]) }

    private let lock = NSLock()
    private var latest: (output: String, collectedAt: Date, instant: ContinuousClock.Instant)?
    /// A clock that keeps counting while the Mac sleeps, so an answer from before a sleep is never taken as recent.
    private let now: @Sendable () -> ContinuousClock.Instant
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    public func record(_ output: String, collectedAt: Date = Date()) {
        let instant = now()
        lock.withLock { latest = (output, collectedAt, instant) }
    }
    public func recent(maximumAge: TimeInterval) -> (output: String, collectedAt: Date)? {
        let instant = now()
        return lock.withLock {
            guard let latest, maximumAge > 0, instant >= latest.instant, instant - latest.instant <= .seconds(maximumAge) else { return nil }
            return (latest.output, latest.collectedAt)
        }
    }
}
