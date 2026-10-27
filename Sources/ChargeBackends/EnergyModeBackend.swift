import Foundation
import Darwin
import PowerCore

public enum EnergyModeParser {
    public static func parse(_ output: String) throws -> [PowerProfileSource: EnergyMode] {
        guard output.utf8.count <= 65_536 else { throw PolicyError.invalidPolicy }
        var source: PowerProfileSource?, result: [PowerProfileSource: EnergyMode] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" { source = .battery; continue }
            if line == "AC Power:" { source = .adapter; continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "lowpowermode" {
                guard fields.count == 2, let source, let value = Int(fields[1]), (0...1).contains(value), result[source] == nil else { throw PolicyError.readbackMismatch }
                result[source] = value == 1 ? .low : .automatic
            }
        }
        guard !result.isEmpty else { throw PolicyError.unavailable }
        return result
    }
}
public actor EnergyModeBackend {
    public init() {}
    public static func arguments(source: PowerProfileSource, mode: EnergyMode) throws -> [String] {
        guard mode != .high else { throw ControlUnavailableError(reason: "High Power Mode has not been discovered and qualified on this Mac.") }
        return [source == .battery ? "-b" : "-c", "lowpowermode", mode == .low ? "1" : "0"]
    }
    public func read() throws -> [PowerProfileSource: EnergyMode] {
        try EnergyModeParser.parse(BoundedProcess.read(executable: "/usr/bin/pmset", arguments: ["-g", "custom"]))
    }
    public func apply(source: PowerProfileSource, mode: EnergyMode) throws {
        try HardwareQualification.current.require(source == .battery ? .batteryEnergyMode : .adapterEnergyMode)
        let arguments = try Self.arguments(source: source, mode: mode)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw PolicyError.readbackMismatch
        }
        guard process.terminationStatus == 0, try read()[source] == mode else { throw PolicyError.readbackMismatch }
    }
}
