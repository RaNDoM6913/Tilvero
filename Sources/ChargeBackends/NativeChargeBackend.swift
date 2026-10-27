import Foundation
import ObjectiveC
import Darwin
import IOKit.ps
import PowerCore

public enum NativeLimitParser {
    public static func registeredTargets(_ output: String) throws -> [Int] {
        guard output.utf8.count <= 65_536 else { throw PolicyError.invalidPolicy }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "No battery level limits set" { return [] }
        let pattern = #"^\s*chargeSocLimitSoc\s*=\s*([0-9]{1,3})\s*;?\s*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let text = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { throw PolicyError.readbackMismatch }
        let values = try matches.map { match -> Int in
            guard let value = Int(text.substring(with: match.range(at: 1))), (1...100).contains(value) else { throw PolicyError.readbackMismatch }
            return value
        }
        return Array(Set(values)).sorted()
    }
}

public enum BoundedProcess {
    /// Only fixed executable paths/typed arguments are supplied by adapters, never IPC strings.
    public static func read(executable: String, arguments: [String], timeout: TimeInterval = 3) throws -> String {
        let allowed: [String: Set<[String]>] = ["/usr/bin/pmset": [["-g", "battlimit"], ["-g", "custom"], ["-g", "cap"]]]
        guard allowed[executable]?.contains(arguments) == true else { throw PolicyError.invalidPolicy }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ControlUnavailableError(reason: "Read-only system query timed out.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { throw PolicyError.readbackMismatch }
        return text
    }
}

public struct NativeChargeDiscovery: Sendable {
    public let clientPresent: Bool
    public let registeredTargets: [Int]?
    public let capability: ControlCapability
}

/// Isolated private adapter. Private client presence is read-only evidence, never a write qualification.
public actor NativeChargeBackend {
    private static var domain: CFString { "com.apple.smartcharging.topoffprotection" as CFString }
    private static var featureKey: CFString { "MCLFeatureState" as CFString }
    private static var limitKey: CFString { "mclLimitValue" as CFString }
    private let qualification = HardwareQualification.current
    public init() {}
    public func currentObservation() -> ChargeObservation {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .init(percent: nil, externalPower: nil, fresh: false) }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int, let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  current >= 0, current <= maximum else { continue }
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return .init(percent: percent, externalPower: (values[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue }, fresh: true, isCharging: values[kIOPSIsChargingKey] as? Bool, fullyCharged: values[kIOPSIsChargedKey] as? Bool)
        }
        return .init(percent: nil, externalPower: nil, fresh: false)
    }
    public func discover() -> NativeChargeDiscovery {
        let framework = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
        let handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL)
        // Keep the Objective-C image loaded while its class objects remain registered.
        let present = handle != nil && NSClassFromString("PowerUISmartChargeClient").map { cls in
            ["isMCLCurrentlyEnabled:", "enableMCL:", "disableMCL:"].allSatisfy { class_getInstanceMethod(cls, NSSelectorFromString($0)) != nil }
        } == true
        let targets = try? NativeLimitParser.registeredTargets(BoundedProcess.read(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"]))
        return NativeChargeDiscovery(clientPresent: present, registeredTargets: targets, capability: ControlCapability(
            backend: "native-powerui", readiness: present ? .unverified : .unavailable,
            reason: present ? "Native client discovered read-only. Private write, target step, signed trust, cutoff and restoration remain unverified on this Mac." : "The required native charge client was not discovered.",
            acceptedTargets: []))
    }

    public func readOriginal() throws -> HardwareSetting {
        guard geteuid() == 0 else { throw ControlUnavailableError(reason: "Root-owned native preferences require the authenticated helper.") }
        func integer(_ key: CFString) throws -> Int? {
            guard let value = CFPreferencesCopyValue(key, Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return nil }
            guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else { throw PolicyError.readbackMismatch }
            return number.intValue
        }
        let feature = try integer(Self.featureKey), limit = try integer(Self.limitKey)
        guard feature == nil || feature == 0 || feature == 1, limit.map({ (1...100).contains($0) }) ?? true else { throw PolicyError.readbackMismatch }
        return .nativeCharge(featureState: feature, limit: limit)
    }

    public func apply(target: Int) throws {
        try qualification.require(.charging)
        guard (80...100).contains(target), geteuid() == 0 else { throw PolicyError.unsupportedTarget }
        try write(feature: 1, limit: target)
    }
    public func restore(_ setting: HardwareSetting) throws {
        try qualification.require(.charging)
        guard case let .nativeCharge(feature, limit) = setting else { throw PolicyError.invalidPolicy }
        // A disabled/absent original must use the client's deregistration path, not just remove preferences.
        if feature != 1 { try disableNativeLimit() }
        try write(feature: feature, limit: limit)
    }
    private func write(feature: Int?, limit: Int?) throws {
        guard geteuid() == 0 else { throw PolicyError.unavailable }
        CFPreferencesSetValue(Self.featureKey, feature.map(NSNumber.init(value:)), Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(Self.limitKey, limit.map(NSNumber.init(value:)), Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw PolicyError.readbackMismatch }
        typealias NotifyPost = @convention(c) (UnsafePointer<CChar>) -> UInt32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "notify_post") else { throw PolicyError.unavailable }
        let post = unsafeBitCast(symbol, to: NotifyPost.self)
        guard "com.apple.smartcharging.defaultschanged".withCString({ post($0) }) == 0 else { throw PolicyError.readbackMismatch }
    }
    private func disableNativeLimit() throws {
        guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { throw PolicyError.unavailable }
        let client = cls.init()
        let selector = NSSelectorFromString("disableMCL:")
        guard client.responds(to: selector), let implementation = client.method(for: selector) else { throw PolicyError.unavailable }
        typealias Disable = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        var error: NSError?
        guard unsafeBitCast(implementation, to: Disable.self)(client, selector, &error), error == nil else { throw PolicyError.readbackMismatch }
    }
}

public struct AdvancedChargeBackend: Sendable {
    public init() {}
    public let capability = ControlCapability(backend: "legacy-smc", readiness: .unavailable,
        reason: "Legacy SMC, sub-80%, exact bands and forced discharge have no locally qualified write contract. Each requires independent source, hardware and restoration evidence.")
}
