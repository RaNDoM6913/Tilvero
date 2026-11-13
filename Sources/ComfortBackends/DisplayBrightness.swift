// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreGraphics

public struct DisplayBrightnessReading: Equatable, Sendable {
    public let displayID: UInt32
    /// The normalized macOS brightness setting (0...1); not a photometric sensor.
    public let value: Double
    public init(displayID: UInt32, value: Double) { self.displayID = displayID; self.value = value }
}

/// Reads and sets the brightness of the BUILT-IN display only. No other display, no auto-brightness, no linear mode.
public protocol DisplayBrightnessTransport: Sendable {
    func read() async throws -> DisplayBrightnessReading
    func set(_ value: Double, displayID: UInt32) async throws
}

/// Pure decisions, tested without a display.
public enum DisplayBrightnessRules {
    /// Exactly one built-in display, or the one remembered from the last time the lid was open (a closed panel may
    /// leave the online list). Zero or several candidates fail closed.
    public static func resolveBuiltIn(online: [UInt32], isBuiltIn: (UInt32) -> Bool, remembered: UInt32?) throws -> UInt32 {
        let builtIn = online.filter(isBuiltIn)
        if builtIn.count == 1 { return builtIn[0] }
        if builtIn.isEmpty, let remembered { return remembered }
        throw ComfortBackendError.noBuiltInDisplay
    }
    public static func validate(reading: Float, status: Int32) throws -> Double {
        guard status == 0 else { throw ComfortBackendError.unavailable }
        guard reading.isFinite, reading >= 0, reading <= 1.0001 else { throw ComfortBackendError.invalidReading }
        return min(1, Double(reading))
    }
    public static func validate(target: Double) throws -> Float {
        guard target.isFinite, target >= 0, target <= 1 else { throw ComfortBackendError.invalidValue }
        return Float(target)
    }
}

/// DisplayServices is a private framework: loaded at run time, symbols resolved by name, any drift fails closed.
/// No native call is made at construction.
public final class NativeDisplayBrightnessTransport: DisplayBrightnessTransport, @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private struct API: @unchecked Sendable { let get: GetBrightness; let set: SetBrightness }
    private static let api: API? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return API(get: unsafeBitCast(get, to: GetBrightness.self), set: unsafeBitCast(set, to: SetBrightness.self))
    }()

    private let lock = NSLock()
    private var remembered: UInt32?
    public init() {}

    private func builtInID() throws -> UInt32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        let known = lock.withLock { remembered }
        let online: [UInt32] = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success ? Array(ids.prefix(Int(count))) : []
        let id = try DisplayBrightnessRules.resolveBuiltIn(online: online, isBuiltIn: { CGDisplayIsBuiltin($0) != 0 }, remembered: known)
        if online.contains(id) { lock.withLock { remembered = id } }
        return id
    }
    public func read() async throws -> DisplayBrightnessReading {
        try await Task.detached(priority: .utility) { [self] in
            guard let api = Self.api else { throw ComfortBackendError.unavailable }
            let id = try builtInID()
            var value: Float = -1
            let status = api.get(id, &value)
            return DisplayBrightnessReading(displayID: id, value: try DisplayBrightnessRules.validate(reading: value, status: status))
        }.value
    }
    public func set(_ value: Double, displayID: UInt32) async throws {
        let target = try DisplayBrightnessRules.validate(target: value)
        try await Task.detached(priority: .utility) { [self] in
            guard let api = Self.api else { throw ComfortBackendError.unavailable }
            // Only the built-in display, resolved again at write time; any other id is refused.
            guard try builtInID() == displayID else { throw ComfortBackendError.noBuiltInDisplay }
            guard api.set(displayID, target) == 0 else { throw ComfortBackendError.writeRejected }
        }.value
    }
}
