import Foundation
import IOKit
import PowerCore

public enum SMCValueDecoder {
    public static func number(type: String, bytes: [UInt8]) throws -> Double {
        switch (type, bytes.count) {
        case ("ui8 ", 1): return Double(bytes[0])
        case ("ui16", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("fpe2", 2): return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("flt ", 4):
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bits)
            guard value.isFinite else { throw PolicyError.readbackMismatch }; return Double(value)
        default: throw PolicyError.readbackMismatch
        }
    }
}

// AppleSMC ABI layout adapted from the MIT-licensed Stats SMC implementation.
// Revision and complete notice are in Helper/THIRD_PARTY_NOTICES.md.
private struct SMCMessage {
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

/// Internal transport: discovery exposes no arbitrary key or write operation to IPC or app callers.
private final class SMCConnection {
    private var connection: io_connect_t = 0
    init() throws {
        guard MemoryLayout<SMCMessage>.stride == 80 else { throw PolicyError.invalidContract }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw PolicyError.unavailable }; defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { throw PolicyError.unavailable }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: inout SMCMessage) throws -> SMCMessage {
        var output = SMCMessage(), size = MemoryLayout<SMCMessage>.stride
        guard IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCMessage>.stride, &output, &size) == kIOReturnSuccess,
              size == MemoryLayout<SMCMessage>.stride, output.result == 0 else { throw PolicyError.readbackMismatch }
        return output
    }
    private func metadata(_ key: String) throws -> SMCMessage.KeyInfo {
        guard key.utf8.count == 4 else { throw PolicyError.invalidPolicy }
        var input = SMCMessage(); input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }; input.command = 9
        let info = try call(&input).keyInfo
        guard (1...32).contains(info.dataSize), info.dataType != 0 else { throw PolicyError.readbackMismatch }; return info
    }
    func readFanValue(_ key: String) throws -> Double {
        guard Self.allowedReadKeys.contains(key) else { throw PolicyError.invalidPolicy }
        let info = try metadata(key)
        var input = SMCMessage(); input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }; input.keyInfo = info; input.command = 5
        var output = try call(&input)
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        let type = String(bytes: [UInt8((info.dataType >> 24) & 255), UInt8((info.dataType >> 16) & 255), UInt8((info.dataType >> 8) & 255), UInt8(info.dataType & 255)], encoding: .ascii) ?? ""
        return try SMCValueDecoder.number(type: type, bytes: bytes)
    }
    func setManual(fanID: Int, rpm: Int) throws {
        guard (0..<10).contains(fanID), (1...20_000).contains(rpm) else { throw PolicyError.invalidPolicy }
        try writeFanKey("F\(fanID)Tg", number: rpm)
        try writeFanKey("F\(fanID)Md", number: 1)
    }
    func setAuto(fanID: Int) throws {
        guard (0..<10).contains(fanID) else { throw PolicyError.invalidPolicy }
        try writeFanKey("F\(fanID)Md", number: 0)
    }
    func setTarget(fanID: Int, rpm: Int) throws {
        guard (0..<10).contains(fanID), (0...20_000).contains(rpm) else { throw PolicyError.invalidPolicy }
        try writeFanKey("F\(fanID)Tg", number: rpm)
    }
    func setMode(fanID: Int, automatic: Bool) throws {
        guard (0..<10).contains(fanID) else { throw PolicyError.invalidPolicy }
        try writeFanKey("F\(fanID)Md", number: automatic ? 0 : 1)
    }
    private func writeFanKey(_ key: String, number: Int) throws {
        // The call chain is reachable only after the actor's immutable hardware qualification gate.
        let info = try metadata(key)
        var input = SMCMessage(); input.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }; input.keyInfo = info; input.command = 6
        let data: [UInt8]
        switch (info.dataType, info.dataSize) {
        case (0x75693820, 1): guard (0...1).contains(number) else { throw PolicyError.invalidPolicy }; data = [UInt8(number)]
        case (0x66706532, 2): guard number <= 16_383 else { throw PolicyError.invalidPolicy }; let value = UInt16(number * 4); data = [UInt8(value >> 8), UInt8(value & 255)]
        case (0x666c7420, 4): var value = Float(number); data = withUnsafeBytes(of: &value) { Array($0) }
        default: throw PolicyError.unavailable
        }
        withUnsafeMutableBytes(of: &input.bytes) { buffer in for (index, byte) in data.enumerated() { buffer[index] = byte } }
        _ = try call(&input)
    }
    private static let allowedReadKeys: Set<String> = Set(["FNum"] + (0..<10).flatMap { id in ["F\(id)Ac", "F\(id)Mn", "F\(id)Mx", "F\(id)Tg", "F\(id)Md"] })
}

public struct FanDiscovery: Sendable {
    public let fans: [FanDescriptor]
    public let observedRPM: [String: Int]
    public let targetRPM: [String: Int]
    public let autoMode: [String: Bool]
    public let capability: ControlCapability
}
public actor SMCFanBackend {
    public init() {}
    public func discover() -> FanDiscovery {
        do {
            let connection = try SMCConnection()
            let rawCount = try connection.readFanValue("FNum")
            guard rawCount.rounded() == rawCount, (0...10).contains(rawCount) else { throw PolicyError.readbackMismatch }
            let count = Int(rawCount)
            var fans: [FanDescriptor] = [], rpms: [String: Int] = [:], targets: [String: Int] = [:], auto: [String: Bool] = [:]
            for id in 0..<count {
                let minimum = try connection.readFanValue("F\(id)Mn"), maximum = try connection.readFanValue("F\(id)Mx")
                guard minimum.isFinite, maximum.isFinite, minimum > 0, minimum < maximum, maximum <= 20_000 else { throw PolicyError.readbackMismatch }
                fans.append(FanDescriptor(id: String(id), minimumRPM: Int(minimum), maximumRPM: Int(maximum)))
                if let actual = try? connection.readFanValue("F\(id)Ac"), (0...20_000).contains(actual) { rpms[String(id)] = Int(actual) }
                if let target = try? connection.readFanValue("F\(id)Tg"), (0...20_000).contains(target) { targets[String(id)] = Int(target) }
                if let mode = try? connection.readFanValue("F\(id)Md"), mode == 0 || mode == 1 || mode == 3 { auto[String(id)] = mode == 0 || mode == 3 }
            }
            return FanDiscovery(fans: fans, observedRPM: rpms, targetRPM: targets, autoMode: auto, capability: ControlCapability(backend: "smc-standard-fan", readiness: count == 0 ? .unavailable : .unverified,
                reason: count == 0 ? "The SMC reports zero fans; this Mac uses passive cooling." : "Fan reads were discovered. Manual target response, trusted helper and independent Auto recovery require real Pro validation."))
        } catch {
            return FanDiscovery(fans: [], observedRPM: [:], targetRPM: [:], autoMode: [:], capability: ControlCapability(backend: "smc-standard-fan", readiness: .unknown, reason: "Read-only fan discovery did not produce a complete validated result: \(error)"))
        }
    }
    public func setRPM(_ values: [String: Int]) throws {
        try HardwareQualification.current.require(.fans)
        let discovered = discover()
        guard discovered.fans.count == values.count, discovered.fans.allSatisfy({ values[$0.id].map($0.accepts) == true }) else { throw PolicyError.invalidPolicy }
        let connection = try SMCConnection()
        for fan in discovered.fans { guard let id = Int(fan.id), let rpm = values[fan.id] else { throw PolicyError.invalidPolicy }; try connection.setManual(fanID: id, rpm: rpm) }
    }
    public func restoreAuto() throws {
        try HardwareQualification.current.require(.fans)
        let discovered = discover(), connection = try SMCConnection()
        guard !discovered.fans.isEmpty else { throw PolicyError.unavailable }
        for fan in discovered.fans { guard let id = Int(fan.id) else { throw PolicyError.invalidPolicy }; try connection.setAuto(fanID: id) }
    }
    public func writeRegister(_ register: FanRegister, value: FanRegisterValue) throws {
        try HardwareQualification.current.require(.fans)
        let discovered = discover()
        guard let descriptor = discovered.fans.first(where: { $0.id == register.fanID }), let id = Int(register.fanID) else { throw PolicyError.unavailable }
        let connection = try SMCConnection()
        switch (register, value) {
        case let (.target, .rpm(rpm)):
            let validAutomaticTarget = discovered.autoMode[register.fanID] == true && (0...descriptor.maximumRPM).contains(rpm)
            guard descriptor.accepts(rpm) || validAutomaticTarget else { throw PolicyError.invalidPolicy }
            try connection.setTarget(fanID: id, rpm: rpm)
        case let (.automatic, .automatic(automatic)):
            guard automatic || discovered.targetRPM[register.fanID].map(descriptor.accepts) == true else { throw PolicyError.invalidPolicy }
            try connection.setMode(fanID: id, automatic: automatic)
        default: throw PolicyError.invalidPolicy
        }
    }
}
