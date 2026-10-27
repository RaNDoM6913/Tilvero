import Foundation
import CoreFoundation
import PowerCore

/// The accepted wire encoding is explicit. Never guess discharge from a huge integer.
public enum SignedCurrentEncoding: Sendable { case signedInteger, twosComplement32 }

public enum TelemetryDecoder {
    public static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d.rounded(.towardZero) == d else { return nil }
        return Int64(exactly: d)
    }
    public static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    public static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    public static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(512))
    }
    public static func currentAmps(_ value: Any?, encoding: SignedCurrentEncoding) -> Double? {
        guard let raw = integer(value) else { return nil }
        let signed: Int64
        switch encoding {
        case .signedInteger:
            guard raw >= Int64(Int32.min), raw <= Int64(Int32.max) else { return nil }
            signed = raw
        case .twosComplement32:
            guard raw >= 0, raw <= Int64(UInt32.max) else { return nil }
            signed = Int64(Int32(bitPattern: UInt32(raw)))
        }
        let result = Double(signed) / 1000
        return abs(result) <= 100 ? result : nil
    }
    public static func percentage(current: Any?, maximum: Any?) -> Double? {
        guard let current = number(current), let maximum = number(maximum), maximum > 0, current >= 0, current <= maximum else { return nil }
        return current / maximum * 100
    }
    public static func minutesToSeconds(_ value: Any?) -> Double? {
        guard let v = number(value), v >= 0 else { return nil }
        let result = v * 60
        return result.isFinite ? result : nil
    }
    public static func aggregateSeconds(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
    public static func capacityRetention(full: Double?, design: Double?) -> Double? {
        guard let full, let design, full.isFinite, design.isFinite, full > 0, design > 0 else { return nil }
        return full / design * 100
    }
    public static func energyWh(capacityMAh: Double?, nominalVoltage: Double?) -> Double? {
        guard let capacityMAh, let nominalVoltage, capacityMAh.isFinite, nominalVoltage.isFinite, capacityMAh > 0, nominalVoltage > 0 else { return nil }
        return capacityMAh * nominalVoltage / 1000
    }
    public static func smartBatteryManufactureDate(_ value: Any?) -> Date? {
        guard let v = integer(value), v >= 0, v <= 65535 else { return nil }
        let year = Int(v >> 9) + 1980, month = Int((v >> 5) & 15), day = Int(v & 31)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: date) == parts else { return nil }
        return date
    }
}
