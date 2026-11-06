// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreFoundation
import CryptoKit
import CoreGraphics
import Darwin
import notify
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import SystemConfiguration
import PowerPrivileged

// IOPM.h uses function-like macros not imported by Swift: sys_iokit | err_sub(13) | 0x100.
enum ClamshellNativeABI {
    static let stateMessage: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
}
enum ClamshellRegistryBoolean {
    static func decode(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFEqual(value, kCFBooleanTrue)
    }
}
struct ClamshellContextSample: Equatable, Sendable {
    var activeUserID: UInt32?
    var lidClosed: Bool? = nil
    var externalDisplayPresent: Bool? = nil
    var aggregateSleepAllowed: Bool? = nil
    var powerSourceType: String? = nil
    var externalDisplayIDs: [UInt32]? = nil
}

/// Online external displays form the cross-process context. A closed built-in
/// panel disappearing from the online list must not look like an external change.
enum ClamshellOnlineDisplays {
    static func externalIDs(querySucceeded: Bool, onlineIDs: [UInt32], truncated: Bool,
                            activeUserID: UInt32?, isBuiltIn: (UInt32) -> Bool) -> [UInt32]? {
        guard querySucceeded, !truncated, let activeUserID, activeUserID >= 500 else { return nil }
        return onlineIDs.filter { !isBuiltIn($0) }.sorted()
    }
}

/// One reducer shared by the real notification callback and deterministic tests.
/// Registry sampling can never promote a cached value into a baseline witness.
final class ClamshellObservationTracker: ClamshellObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let sample: @Sendable () -> ClamshellContextSample
    private let clock: @Sendable () -> Double
    private let bootID: @Sendable () -> String
    private var contextID: UUID?
    private let observerID = UUID()
    private var sequence: UInt64 = 0
    private var witness: ClamshellBaselineWitness?
    init(sample: @escaping @Sendable () -> ClamshellContextSample,
         clock: @escaping @Sendable () -> Double, bootID: @escaping @Sendable () -> String) {
        self.sample = sample; self.clock = clock; self.bootID = bootID
    }
    /// A deterministic semantic fingerprint is comparable between controller and
    /// guardian processes. Per-process callback epochs would strand restoration.
    @discardableResult private func refresh(_ value: ClamshellContextSample, boot: String) -> UUID {
        let fields = ["tilvero-lid-context-v1", boot,
                      value.activeUserID.map(String.init) ?? "unknown",
                      value.externalDisplayPresent.map { $0 ? "present" : "absent" } ?? "unknown",
                      value.externalDisplayIDs.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "unknown",
                      value.powerSourceType ?? "unknown"]
        // Length-prefix fields to avoid ambiguous separators. SHA256 is stable
        // across processes; Swift's randomized Hasher must never be used here.
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(canonical.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUIDv8 application-defined hash.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let next = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        if contextID != next { witness = nil }
        contextID = next
        return next
    }
    /// Notifications are hints to resample, not evidence that semantics changed.
    func contextChanged() { lock.withLock { _ = refresh(sample(), boot: bootID()) } }
    func receiveNativeNotification(message: UInt32, bits: UInt64) {
        guard message == ClamshellNativeABI.stateMessage else { return }
        lock.withLock {
            let boot = bootID(), now = clock(), value = sample()
            let context = refresh(value, boot: boot)
            witness = nil
            guard bits <= 3, now.isFinite, now >= 0, validBoot(boot), sequence < .max else { return }
            sequence += 1
            // A recomputed sleep predicate is insufficient for acquisition when
            // the actual power-source context could not be observed.
            guard bits & 2 != 0, let powerSource = value.powerSourceType, !powerSource.isEmpty else { return }
            witness = .init(bootID: boot, receivedAt: now, sequence: sequence,
                            contextID: context, notificationBits: UInt32(bits), sleepAllowed: true, observerID: observerID)
        }
    }
    func observation() throws -> ClamshellObservation {
        try lock.withLock {
            let boot = bootID(), now = clock(), value = sample()
            guard validBoot(boot), now.isFinite, now >= 0 else { witness = nil; throw ClosedLidFailure.unavailable }
            let context = refresh(value, boot: boot)
            if let witness, witness.receivedAt > now || now - witness.receivedAt > ClosedLidLimits.witnessMaximumAge { self.witness = nil }
            return .init(bootID: boot, sampledAt: now, contextID: context, activeUserID: value.activeUserID,
                         lidClosed: value.lidClosed, externalDisplayPresent: value.externalDisplayPresent,
                         aggregateSleepAllowed: value.aggregateSleepAllowed, witness: witness)
        }
    }
    private func validBoot(_ boot: String) -> Bool { !boot.isEmpty && boot != "unavailable" && boot.utf8.count <= 128 }
}

/// Subscriptions run on a dedicated dispatch queue; no GUI/main run loop is required.
/// The native clamshell general-interest message is the only witness producer.
final class NativeClamshellObserver: ClamshellObserving, @unchecked Sendable {
    private let tracker: ClamshellObservationTracker
    private let queue = DispatchQueue(label: "local.tilvero.lid.native-observation", qos: .utility)
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var consoleStore: SCDynamicStore?
    private var powerToken: Int32 = -1
    private var displayRegistered = false
    init() throws {
        tracker = ClamshellObservationTracker(sample: { Self.readSample() },
            clock: { HelperClock.continuousSeconds() }, bootID: { HelperClock.bootID() })
        let context = Unmanaged.passUnretained(tracker).toOpaque()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { throw ClosedLidFailure.unavailable }
        notificationPort = port
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw ClosedLidFailure.unavailable }
        defer { IOObjectRelease(root) }
        let callback: IOServiceInterestCallback = { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<ClamshellObservationTracker>.fromOpaque(refcon).takeUnretainedValue()
                .receiveNativeNotification(message: message, bits: UInt64(UInt(bitPattern: argument)))
        }
        guard IOServiceAddInterestNotification(port, root, kIOGeneralInterest, callback, context, &notifier) == KERN_SUCCESS else { throw ClosedLidFailure.unavailable }
        IONotificationPortSetDispatchQueue(port, queue)
        guard notify_register_dispatch("com.apple.system.powersources.source", &powerToken, queue, { [tracker] _ in tracker.contextChanged() }) == NOTIFY_STATUS_OK else { throw ClosedLidFailure.unavailable }
        guard CGDisplayRegisterReconfigurationCallback(Self.displayCallback, context) == .success else { throw ClosedLidFailure.unavailable }
        displayRegistered = true
        var storeContext = SCDynamicStoreContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "TilveroLidConsoleObserver" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<ClamshellObservationTracker>.fromOpaque(info).takeUnretainedValue().contextChanged()
        }, &storeContext) else { throw ClosedLidFailure.unavailable }
        consoleStore = store
        guard SCDynamicStoreSetNotificationKeys(store, ["State:/Users/ConsoleUser"] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, queue) else { throw ClosedLidFailure.unavailable }
    }
    deinit {
        if let consoleStore { SCDynamicStoreSetDispatchQueue(consoleStore, nil) }
        if displayRegistered { CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(tracker).toOpaque()) }
        if powerToken != -1 { notify_cancel(powerToken) }
        if let notificationPort { IONotificationPortSetDispatchQueue(notificationPort, nil) }
        if notifier != 0 { IOObjectRelease(notifier) }
        queue.sync {}
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
    func observation() throws -> ClamshellObservation { try tracker.observation() }
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, _, info in
        guard let info else { return }
        Unmanaged<ClamshellObservationTracker>.fromOpaque(info).takeUnretainedValue().contextChanged()
    }
    private static func readSample() -> ClamshellContextSample {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var lid: Bool?, aggregate: Bool?
        if root != 0 {
            defer { IOObjectRelease(root) }
            lid = ClamshellRegistryBoolean.decode(IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, nil, 0)?.takeRetainedValue())
            aggregate = ClamshellRegistryBoolean.decode(IORegistryEntryCreateCFProperty(root, "AppleClamshellCausesSleep" as CFString, nil, 0)?.takeRetainedValue())
        }
        let activeUserID = HelperClock.activeConsoleUserID()
        var displays = [CGDirectDisplayID](repeating: 0, count: 64), count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
        let externalIDs = ClamshellOnlineDisplays.externalIDs(querySucceeded: result == .success,
            onlineIDs: Array(displays.prefix(min(Int(count), displays.count))), truncated: count >= displays.count,
            activeUserID: activeUserID, isBuiltIn: { CGDisplayIsBuiltin($0) != 0 })
        var sourceType: String?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(),
           CFGetTypeID(source) == CFStringGetTypeID() {
            sourceType = source as String
        }
        return .init(activeUserID: activeUserID, lidClosed: lid,
                     externalDisplayPresent: externalIDs.map { !$0.isEmpty }, aggregateSleepAllowed: aggregate,
                     powerSourceType: sourceType, externalDisplayIDs: externalIDs)
    }
}
