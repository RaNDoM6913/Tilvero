// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreFoundation
import CoreGraphics
import IOKit

/// What the registry says about the lid right now. Both fields are nil when unreadable (a desktop Mac has no lid):
/// consumers must treat nil as "do nothing".
public struct ClamshellSample: Equatable, Sendable {
    public var lidClosed: Bool?
    public var causesSleep: Bool?
    public init(lidClosed: Bool?, causesSleep: Bool?) { self.lidClosed = lidClosed; self.causesSleep = causesSleep }
    /// True only when the lid is closed AND macOS would sleep because of it (not with an external display attached).
    public var closedAndWouldSleep: Bool { lidClosed == true && causesSleep == true }
    public var isOpen: Bool { lidClosed == false }
    /// Registry booleans only: a number or string posing as a boolean is unreadable.
    public static func decode(lidClosed: CFTypeRef?, causesSleep: CFTypeRef?) -> ClamshellSample {
        func boolean(_ value: CFTypeRef?) -> Bool? {
            guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFEqual(value, kCFBooleanTrue)
        }
        return ClamshellSample(lidClosed: boolean(lidClosed), causesSleep: boolean(causesSleep))
    }
}

/// Read-only observation of the lid. A general-interest notification on `IOPMrootDomain` is a hint to resample,
/// never evidence by itself; no polling, no writes.
public final class ClamshellStateObserver: @unchecked Sendable {
    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)`: IOPM.h's function-like macros are not imported by Swift.
    public static let stateChangeMessage: UInt32 = (0x38 << 26) | (13 << 14) | 0x100
    /// Only the lid message and display reconfiguration (an external display changes `AppleClamshellCausesSleep`)
    /// trigger a resample.
    public static func shouldResample(message: UInt32) -> Bool { message == stateChangeMessage }

    public static func currentSample() -> ClamshellSample {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return ClamshellSample(lidClosed: nil, causesSleep: nil) }
        defer { IOObjectRelease(root) }
        return .decode(
            lidClosed: IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, nil, 0)?.takeRetainedValue(),
            causesSleep: IORegistryEntryCreateCFProperty(root, "AppleClamshellCausesSleep" as CFString, nil, 0)?.takeRetainedValue())
    }

    private final class Box { let handler: @Sendable (ClamshellSample) -> Void; init(_ handler: @escaping @Sendable (ClamshellSample) -> Void) { self.handler = handler } }
    /// One function pointer for register and remove (CoreGraphics matches the pair by pointer and context).
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, info in
        guard let info, !flags.contains(.beginConfigurationFlag) else { return }
        Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler(ClamshellStateObserver.currentSample())
    }
    private let box: Box
    private let queue = DispatchQueue(label: "local.tilvero.clamshell-state", qos: .utility)
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var displayRegistered = false

    /// Returns nil when the registry cannot be subscribed to. The handler runs on a private queue.
    public init?(handler: @escaping @Sendable (ClamshellSample) -> Void) {
        box = Box(handler)
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { IONotificationPortDestroy(port); self.port = nil; return nil }
        defer { IOObjectRelease(root) }
        let callback: IOServiceInterestCallback = { refcon, _, message, _ in
            guard let refcon, ClamshellStateObserver.shouldResample(message: message) else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().handler(ClamshellStateObserver.currentSample())
        }
        guard IOServiceAddInterestNotification(port, root, kIOGeneralInterest, callback, context, &notifier) == KERN_SUCCESS else {
            IONotificationPortDestroy(port); self.port = nil; return nil
        }
        IONotificationPortSetDispatchQueue(port, queue)
        displayRegistered = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, context) == .success
    }

    public func stop() {
        if displayRegistered {
            displayRegistered = false
            CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(box).toOpaque())
        }
        if let port { IONotificationPortSetDispatchQueue(port, nil) }
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        queue.sync {}
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }
    deinit { stop() }
}
