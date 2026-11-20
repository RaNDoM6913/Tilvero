// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import IOKit

/// One live reading of the power-management sensors, about once a second (the AppleSmartBattery registry only refreshes
/// once a minute). In memory only: it is never persisted and never enters the history.
public struct LivePowerSample: Equatable, Sendable {
    public var collectedAt: Date
    /// SMC `PSTR`: total system power, W.
    public var systemWatts: Double?
    /// SMC `PDTR`: DC-in (adapter) power, W.
    public var adapterWatts: Double?
    /// Mean of the battery temperature sensors `TB0T`, `TB1T`, `TB2T`, °C.
    public var temperatureCelsius: Double?
    /// SMC `B0AP`: signed battery power, W (negative while discharging, the sign of the registry's Voltage×Amperage).
    /// The registry's once-a-minute `Amperage`/`Voltage` are snapshots of `B0AC`/`B0AV`, so this continues the recorded
    /// line (measured 2026-11-20, Mac17,3, on battery; the charging sign is still to be confirmed on AC).
    public var batteryWatts: Double?
    public init(collectedAt: Date, systemWatts: Double?, adapterWatts: Double?, temperatureCelsius: Double?, batteryWatts: Double? = nil) {
        self.collectedAt = collectedAt; self.systemWatts = systemWatts; self.adapterWatts = adapterWatts
        self.temperatureCelsius = temperatureCelsius; self.batteryWatts = batteryWatts
    }
    /// The catalog metric id each live value feeds: 038 battery power, 039 temperature, 043 system, 054 adapter input.
    /// Battery power is read directly (`B0AP`), never derived from `PDTR - PSTR`: `PSTR` trails `PDTR` by one update, so
    /// their difference is noise (measured 2026-11-12).
    public func value(metricID: String) -> Double? {
        switch metricID {
        case "038": batteryWatts
        case "039": temperatureCelsius
        case "043": systemWatts
        case "054": adapterWatts
        default: nil
        }
    }
    public static let metricIDs = ["038", "039", "043", "054"]
}

/// Value decoding and plausibility, tested without hardware.
public enum SMCSensorDecoding {
    public static func number(type: String, bytes: [UInt8]) -> Double? {
        switch (type, bytes.count) {
        case ("flt ", 4): return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("ui8 ", 1): return Double(bytes[0])
        // The SMC returns integer keys little-endian on Apple silicon (B0AV 11642 mV, B0AT 3007 = 27.5 °C; measured).
        case ("ui16", 2): return Double(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        case ("si16", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
        case ("si32", 4): return Double(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        default: return nil
        }
    }
    /// Watts: finite and inside a range no Mac laptop leaves; anything else is unavailable, never clamped.
    public static func watts(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= -5, value <= 400 else { return nil }
        return value
    }
    /// Battery power in W from `B0AP` (mW), checked against `B0AC` (mA) × `B0AV` (mV): voltage 5-20 V, current within
    /// ±20 A, power within ±300 W and the two agreeing within 0.25 W (the keys are read one after another, so an update
    /// between the reads can split them). Anything else is unavailable for that second, never clamped.
    public static func batteryWatts(powerMilliwatts: Double?, currentMilliamps: Double?, voltageMillivolts: Double?) -> Double? {
        guard let power = powerMilliwatts, let current = currentMilliamps, let voltage = voltageMillivolts,
              power.isFinite, current.isFinite, voltage.isFinite,
              (5000...20000).contains(voltage), abs(current) <= 20000, abs(power) <= 300_000 else { return nil }
        let watts = power / 1000
        guard abs(watts - current * voltage / 1_000_000) < 0.25 else { return nil }
        return watts
    }
    public static func celsius(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > -30, value < 150 else { return nil }
        return value
    }
}

/// Read-only access to a fixed allow-list of power and temperature sensors of the AppleSMC. No write command exists
/// here (only key-info and read), and no key outside `allowedKeys` can be requested. The message layout is adapted
/// from the MIT-licensed Stats project (see THIRD_PARTY_NOTICES.md).
public final class SMCSensorReader: @unchecked Sendable {
    public static let allowedKeys: Set<String> = ["PSTR", "PDTR", "TB0T", "TB1T", "TB2T", "B0AP", "B0AC", "B0AV"]

    private struct Message {
        struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0; var status: UInt8 = 0; var command: UInt8 = 0; var data: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    private static let readKeyInfo: UInt8 = 9, readBytes: UInt8 = 5

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    /// nil when the SMC cannot be opened or its message layout is not the expected 80 bytes (fail closed).
    public init?() {
        guard MemoryLayout<Message>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: inout Message) -> Message? {
        var output = Message(), size = MemoryLayout<Message>.stride
        guard IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Message>.stride, &output, &size) == kIOReturnSuccess,
              size == MemoryLayout<Message>.stride, output.result == 0 else { return nil }
        return output
    }
    private func value(_ key: String) -> Double? {
        guard Self.allowedKeys.contains(key), key.utf8.count == 4 else { return nil }
        let code = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        var info = Message(); info.key = code; info.command = Self.readKeyInfo
        guard let described = call(&info), (1...32).contains(described.keyInfo.dataSize) else { return nil }
        var request = Message(); request.key = code; request.keyInfo = described.keyInfo; request.command = Self.readBytes
        guard var output = call(&request) else { return nil }
        let type = String(bytes: (0..<4).map { UInt8((described.keyInfo.dataType >> UInt32(24 - 8 * $0)) & 255) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(described.keyInfo.dataSize))) }
        return SMCSensorDecoding.number(type: type, bytes: bytes)
    }

    /// One sample (about 8 key reads, ~1 ms). Missing or implausible sensors are nil; nil when nothing could be read.
    public func read(at date: Date = Date()) -> LivePowerSample? {
        lock.lock(); defer { lock.unlock() }
        let temperatures = ["TB0T", "TB1T", "TB2T"].compactMap { SMCSensorDecoding.celsius(value($0)) }
        let sample = LivePowerSample(collectedAt: date,
                                     systemWatts: SMCSensorDecoding.watts(value("PSTR")),
                                     adapterWatts: SMCSensorDecoding.watts(value("PDTR")),
                                     temperatureCelsius: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count),
                                     batteryWatts: SMCSensorDecoding.batteryWatts(powerMilliwatts: value("B0AP"), currentMilliamps: value("B0AC"),
                                                                                  voltageMillivolts: value("B0AV")))
        return sample.systemWatts == nil && sample.adapterWatts == nil && sample.temperatureCelsius == nil && sample.batteryWatts == nil ? nil : sample
    }
}
