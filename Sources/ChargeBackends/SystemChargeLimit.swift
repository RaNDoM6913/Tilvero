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
    public static func read() -> Self {
        let limits = try? SystemChargeLimitParser.parse(BoundedProcess.read(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"]))
        return .init(limits: limits)
    }
}
