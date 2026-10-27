import Foundation

/// An encoding profile for a specific provider family, never a universal scale rule.
/// Sources consulted (original implementation; no third-party code copied):
/// Apple PowerManagement d415e45501842834a280930c3eed9186544a67f0,
/// AppleSmartBatteryManager/AppleSmartBattery.cpp (poll timestamps and signed fields).
/// Ampere 843498d7beb711c0e1b18e48c8520debe67f6e3f, BatteryInfo.swift
/// and Stats 5cf09a8cb0561ff24c28be4e5374d579d0601818, Battery/readers.swift
/// document the ARM centi-C and raw-capacity layouts. This is source qualification,
/// not validation of sensor accuracy on a physical battery or every future OS.
public enum RegistryQualification: Sendable, Equatable {
    case unqualified, appleSilicon, intelSmartBattery
    public static var platformDefault: Self {
        #if arch(arm64)
        .appleSilicon
        #elseif arch(x86_64)
        .intelSmartBattery
        #else
        .unqualified
        #endif
    }
    public func temperatureCelsius(_ value: Any?) -> Double? {
        guard let raw = TelemetryDecoder.number(value) else { return nil }
        let result: Double
        switch self {
        case .unqualified: return nil
        case .appleSilicon: result = raw / 100
        case .intelSmartBattery: result = raw / 10 - 273.15
        }
        return (-40...100).contains(result) ? result : nil
    }
}

/// Converts a verified driver wall timestamp into an age, then advances unchanged
/// samples using uptime. Re-reading the same cached dictionary cannot reset its age.
final class SourceSampleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (timestamp: TimeInterval, uptime: TimeInterval, initialAge: TimeInterval)?
    func age(sample: Date, collected: Date, uptime: TimeInterval?) -> TimeInterval? {
        guard let uptime, uptime.isFinite, uptime >= 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let previous, previous.timestamp == sample.timeIntervalSince1970, uptime >= previous.uptime {
            return previous.initialAge + uptime - previous.uptime
        }
        let age = collected.timeIntervalSince(sample)
        guard age >= 0, age.isFinite else { return nil }
        previous = (sample.timeIntervalSince1970, uptime, age)
        return age
    }
}
