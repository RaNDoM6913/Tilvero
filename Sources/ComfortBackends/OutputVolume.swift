// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreAudio

public struct OutputVolumeReading: Equatable, Sendable {
    public let deviceUID: String
    /// Virtual main volume of the output scope (0...1); nil when the device has no volume control.
    public let volume: Double?
    public let muted: Bool?
    public let isSettable: Bool
    public init(deviceUID: String, volume: Double?, muted: Bool?, isSettable: Bool) {
        self.deviceUID = deviceUID; self.volume = volume; self.muted = muted; self.isSettable = isSettable
    }
}

/// The system output volume only ('vmvc', output scope). Never mute, never input, never any other property.
public protocol OutputVolumeTransport: Sendable {
    func defaultOutput() async throws -> OutputVolumeReading
    /// nil when the device exists but exposes no volume; throws `deviceMissing` when it is gone.
    func volume(deviceUID: String) async throws -> Double?
    func setVolume(_ value: Double, deviceUID: String) async throws
    /// The default output device changed (AirPods connected or gone). Called on a private queue.
    func observeDefaultOutputChanges(_ handler: @escaping @Sendable () -> Void) -> any ComfortSubscription
}

public enum OutputVolumeRules {
    public static func validate(reading: Float) throws -> Double {
        guard reading.isFinite, reading >= 0, reading <= 1.0001 else { throw ComfortBackendError.invalidReading }
        return min(1, Double(reading))
    }
    public static func validate(target: Double) throws -> Float {
        guard target.isFinite, target >= 0, target <= 1 else { throw ComfortBackendError.invalidValue }
        return Float(target)
    }
}

public final class NativeOutputVolumeTransport: OutputVolumeTransport, @unchecked Sendable {
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc'): what the volume keys and the menu bar move.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)
    public init() {}

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { throw ComfortBackendError.unavailable }
        return device
    }
    private static func uid(of device: AudioDeviceID) throws -> String {
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { throw ComfortBackendError.unavailable }
        return value.takeRetainedValue() as String
    }
    private static func device(forUID uid: String) throws -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { throw ComfortBackendError.deviceMissing }
        return device
    }
    private static func readVolume(_ device: AudioDeviceID) throws -> (value: Double, settable: Bool)? {
        var address = address(virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        _ = AudioObjectIsPropertySettable(device, &address, &settable)
        var value: Float32 = -1, size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { throw ComfortBackendError.unavailable }
        return (try OutputVolumeRules.validate(reading: value), settable.boolValue)
    }
    private static func readMute(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    public func defaultOutput() async throws -> OutputVolumeReading {
        try await Task.detached(priority: .utility) {
            let device = try Self.defaultOutputDevice()
            let volume = try Self.readVolume(device)
            return OutputVolumeReading(deviceUID: try Self.uid(of: device), volume: volume?.value,
                                       muted: Self.readMute(device), isSettable: volume?.settable ?? false)
        }.value
    }
    public func volume(deviceUID: String) async throws -> Double? {
        try await Task.detached(priority: .utility) { try Self.readVolume(try Self.device(forUID: deviceUID))?.value }.value
    }
    public func setVolume(_ value: Double, deviceUID: String) async throws {
        let target = try OutputVolumeRules.validate(target: value)
        try await Task.detached(priority: .utility) {
            let device = try Self.device(forUID: deviceUID)   // a vanished device is refused, never "the new default"
            guard let current = try Self.readVolume(device), current.settable else { throw ComfortBackendError.notSettable }
            var address = Self.address(Self.virtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
            var newValue = target
            guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue) == noErr else {
                throw ComfortBackendError.writeRejected
            }
        }.value
    }

    private final class Subscription: ComfortSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var block: AudioObjectPropertyListenerBlock?
        private let queue: DispatchQueue
        init(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) { self.queue = queue; self.block = block }
        func cancel() {
            guard let block = lock.withLock({ defer { self.block = nil }; return self.block }) else { return }
            var address = NativeOutputVolumeTransport.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        deinit { cancel() }
    }
    public func observeDefaultOutputChanges(_ handler: @escaping @Sendable () -> Void) -> any ComfortSubscription {
        let queue = DispatchQueue(label: "local.tilvero.default-output", qos: .utility)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        return Subscription(queue: queue, block: block)
    }
}
