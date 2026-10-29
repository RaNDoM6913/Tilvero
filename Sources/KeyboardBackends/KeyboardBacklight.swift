import Foundation
import CoreFoundation
import PowerUIBridge

public enum KeyboardBacklightError: Error, LocalizedError, Sendable, Equatable {
    case unavailable, interfaceChanged, unsupported, invalidReadback, invalidBrightness
    case writeRejected, unconfirmedWrite, missingRememberedBrightness, automaticPolicyChanged, disabledInSimulation
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Keyboard backlight is unavailable. Refresh to try again."
        case .interfaceChanged: "The macOS keyboard interface changed. No setting was written."
        case .unsupported: "A supported built-in backlit keyboard was not found."
        case .invalidReadback: "macOS returned an invalid keyboard brightness reading."
        case .invalidBrightness: "Keyboard brightness must be between 0 and 1."
        case .writeRejected: "macOS did not accept the keyboard brightness change."
        case .unconfirmedWrite: "The keyboard brightness change is not confirmed. Refresh to check its actual state."
        case .missingRememberedBrightness: "Set a nonzero keyboard brightness in System Settings once, then refresh."
        case .automaticPolicyChanged: "Automatic keyboard brightness changed during the operation. Check System Settings."
        case .disabledInSimulation: "Keyboard control is unavailable in simulation."
        }
    }
    static func bridge(_ error: NSError?) -> Self {
        guard error?.domain == "Tilvero.KeyboardBacklight" else { return .unavailable }
        switch error?.code {
        case 2: return .interfaceChanged
        case 3: return .unsupported
        case 4: return .invalidReadback
        case 5: return .invalidBrightness
        case 6: return .writeRejected
        case 7: return .unconfirmedWrite
        default: return .unavailable
        }
    }
}
public struct KeyboardBacklightObservation: Sendable, Equatable {
    public let keyboardID: UInt64
    /// The normalized macOS brightness setting; not a photometric sensor.
    public let brightness: Double
    public let automaticBrightness: Bool
    public let suppressed: Bool
    public let dimmed: Bool
    public let observedAt: Date
    public init(keyboardID: UInt64, brightness: Double, automaticBrightness: Bool,
                suppressed: Bool, dimmed: Bool, observedAt: Date) throws {
        guard brightness.isFinite, (0...1).contains(brightness) else { throw KeyboardBacklightError.invalidReadback }
        self.keyboardID = keyboardID; self.brightness = brightness
        self.automaticBrightness = automaticBrightness; self.suppressed = suppressed
        self.dimmed = dimmed; self.observedAt = observedAt
    }
    /// Positive but suppressed/dimmed brightness cannot establish illuminated keys.
    public var isEnabled: Bool? { brightness == 0 ? false : (suppressed || dimmed ? nil : true) }
}
@MainActor public protocol KeyboardBacklightTransport: AnyObject {
    func read() async throws -> KeyboardBacklightObservation
    func setBrightness(_ value: Double, keyboardID: UInt64) async throws
}
/// No native call is made at construction. Reads and explicit writes use fixed bridge operations off the UI actor.
@MainActor public final class NativeKeyboardBacklightTransport: KeyboardBacklightTransport {
    public init() {}
    public func read() async throws -> KeyboardBacklightObservation {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                var error: NSError?
                guard let raw = TVKeyboardBacklightRead(&error), error == nil else {
                    throw KeyboardBacklightError.bridge(error)
                }
                return try Self.decode(raw)
            }
        }.value
    }
    public func setBrightness(_ value: Double, keyboardID: UInt64) async throws {
        guard value.isFinite, (0...1).contains(value) else { throw KeyboardBacklightError.invalidBrightness }
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                var error: NSError?
                guard TVKeyboardBacklightSet(value, keyboardID, &error), error == nil else { throw KeyboardBacklightError.bridge(error) }
            }
        }.value
    }
    nonisolated static func decode(_ raw: [String: Any]) throws -> KeyboardBacklightObservation {
        guard let identifier = raw["keyboardID"] as? NSNumber,
              CFGetTypeID(identifier) != CFBooleanGetTypeID(),
              let type = String(cString: identifier.objCType).first, "CISLQcislq".contains(type), identifier.doubleValue >= 0,
              let brightness = raw["brightness"] as? NSNumber, CFGetTypeID(brightness) != CFBooleanGetTypeID(),
              let automatic = raw["automaticBrightness"] as? NSNumber, CFGetTypeID(automatic) == CFBooleanGetTypeID(),
              let suppressed = raw["suppressed"] as? NSNumber, CFGetTypeID(suppressed) == CFBooleanGetTypeID(),
              let dimmed = raw["dimmed"] as? NSNumber, CFGetTypeID(dimmed) == CFBooleanGetTypeID() else { throw KeyboardBacklightError.invalidReadback }
        return try .init(keyboardID: identifier.uint64Value, brightness: brightness.doubleValue,
                         automaticBrightness: automatic.boolValue, suppressed: suppressed.boolValue,
                         dimmed: dimmed.boolValue, observedAt: Date())
    }
}
