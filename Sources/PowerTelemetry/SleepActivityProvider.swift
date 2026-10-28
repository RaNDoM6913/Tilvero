import Foundation
import IOKit.pwr_mgt
import AppKit

public enum SleepAssertionAvailability: String, Sendable, Equatable { case available, unavailable }
public enum SleepAssertionType: String, Sendable, Equatable, Hashable {
    case displayIdle, systemIdle, systemSleep, unknown
}
public struct SleepAssertionRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let processID: Int32?
    public let processName: String?
    public let type: SleepAssertionType
    public init(id: String, processID: Int32?, processName: String?, type: SleepAssertionType) {
        self.id = id; self.processID = processID; self.processName = processName; self.type = type
    }
}
/// Ephemeral diagnostics: intentionally no history codec or raw assertion descriptions.
public struct SleepAssertionSnapshot: Sendable, Equatable {
    public let collectedAt: Date
    public let aggregateAvailability: SleepAssertionAvailability
    public let processAvailability: SleepAssertionAvailability
    public let activeTypes: [SleepAssertionType]
    public let rows: [SleepAssertionRow]
    public init(collectedAt: Date, aggregateAvailability: SleepAssertionAvailability,
                processAvailability: SleepAssertionAvailability, activeTypes: [SleepAssertionType], rows: [SleepAssertionRow]) {
        self.collectedAt = collectedAt; self.aggregateAvailability = aggregateAvailability
        self.processAvailability = processAvailability; self.activeTypes = activeTypes; self.rows = rows
    }
}

enum SleepAssertionRawResult { case success([AnyHashable: Any]), failure }
struct SleepProcessIdentity: Equatable { let launchDate: Date; let displayName: String }

/// Public, read-only IOPM APIs. This does not identify the cause of any historical charge change.
@MainActor public final class SleepActivityProvider {
    private let statusReader: () -> SleepAssertionRawResult
    private let processReader: () -> SleepAssertionRawResult
    private let processIdentities: () -> [Int32: SleepProcessIdentity]
    private let processIdentity: (Int32) -> SleepProcessIdentity?
    public convenience init() {
        self.init(statusReader: {
            var value: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsStatus(&value) == kIOReturnSuccess,
                  let dictionary = value?.takeRetainedValue() as? [AnyHashable: Any] else { return .failure }
            return .success(dictionary)
        }, processReader: {
            var value: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess,
                  let dictionary = value?.takeRetainedValue() as? [AnyHashable: Any] else { return .failure }
            return .success(dictionary)
        }, processIdentity: Self.applicationIdentity, processIdentities: {
            var identities: [Int32: SleepProcessIdentity] = [:]
            for app in NSWorkspace.shared.runningApplications {
                if let identity = Self.applicationIdentity(app.processIdentifier) { identities[app.processIdentifier] = identity }
            }
            return identities
        })
    }
    init(statusReader: @escaping () -> SleepAssertionRawResult, processReader: @escaping () -> SleepAssertionRawResult,
         processIdentity: @escaping (Int32) -> SleepProcessIdentity? = { _ in nil },
         processIdentities: @escaping () -> [Int32: SleepProcessIdentity] = { [:] }) {
        self.processIdentities = processIdentities
        self.statusReader = statusReader; self.processReader = processReader; self.processIdentity = processIdentity
    }
    private static func applicationIdentity(_ pid: Int32) -> SleepProcessIdentity? {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated,
              let launched = application.launchDate, let name = application.localizedName else { return nil }
        return .init(launchDate: launched, displayName: name)
    }
    public func readSnapshot() -> SleepAssertionSnapshot {
        let status = Self.decodeStatus(statusReader())
        // Bind names across the assertion API snapshot, not two lookups after it.
        let before = processIdentities()
        let raw = processReader()
        let processes = Self.decodeProcesses(raw, priorIdentities: before, processIdentity: processIdentity)
        return .init(collectedAt: Date(), aggregateAvailability: status.0, processAvailability: processes.0,
                     activeTypes: status.1, rows: processes.1)
    }
    private static func type(_ raw: String) -> SleepAssertionType {
        switch raw {
        case kIOPMAssertionTypePreventUserIdleDisplaySleep as String: return .displayIdle
        case kIOPMAssertionTypePreventUserIdleSystemSleep as String: return .systemIdle
        case kIOPMAssertionTypePreventSystemSleep as String: return .systemSleep
        default: return .unknown
        }
    }
    private static func active(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let level = number.doubleValue
        // The API reports enabled aggregate levels as 1 on some OS versions, while
        // the SDK's assertion-creation level constant is 255. Both mean enabled.
        if level == Double(kIOPMAssertionLevelOff) { return false }
        if level == 1 || level == Double(kIOPMAssertionLevelOn) { return true }
        return nil
    }
    private static func decodeStatus(_ result: SleepAssertionRawResult) -> (SleepAssertionAvailability, [SleepAssertionType]) {
        guard case .success(let dictionary) = result else { return (.unavailable, []) }
        var types: Set<SleepAssertionType> = []
        for (key, value) in dictionary {
            guard let name = key as? String, let enabled = active(value) else { return (.unavailable, []) }
            if enabled { types.insert(type(name)) }
        }
        return (.available, types.sorted { $0.rawValue < $1.rawValue })
    }
    private static func decodeProcesses(_ result: SleepAssertionRawResult,
        priorIdentities: [Int32: SleepProcessIdentity], processIdentity: (Int32) -> SleepProcessIdentity?) -> (SleepAssertionAvailability, [SleepAssertionRow]) {
        guard case .success(let dictionary) = result else { return (.unavailable, []) }
        var rows: [SleepAssertionRow] = []
        for (key, value) in dictionary {
            guard let pid = key as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
                  pid.doubleValue == Double(pid.int32Value), pid.int32Value >= 0,
                  let assertions = value as? [[String: Any]] else { return (.unavailable, []) }
            // Only public GUI-app metadata with a stable start identity can supply a name.
            let before = priorIdentities[pid.int32Value]
            let after = processIdentity(pid.int32Value)
            let name = before.flatMap { identity -> String? in
                guard identity == after, identity.launchDate.timeIntervalSince1970.isFinite,
                      !identity.displayName.isEmpty, identity.displayName.utf8.count <= 256,
                      !identity.displayName.contains("/"), !identity.displayName.contains("\\"),
                      identity.displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
                return identity.displayName
            }
            for (index, assertion) in assertions.enumerated() {
                guard let rawType = assertion[kIOPMAssertionTypeKey as String] as? String,
                      let enabled = active(assertion[kIOPMAssertionLevelKey as String]) else { return (.unavailable, []) }
                guard enabled else { continue }
                let kind = type(rawType)
                // A PID is what the API observed. Unverifiable process names stay unavailable.
                rows.append(.init(id: "\(pid.int32Value):\(kind.rawValue):\(index)", processID: pid.int32Value,
                                  processName: name, type: kind))
            }
        }
        return (.available, rows.sorted { $0.id < $1.id })
    }
}
