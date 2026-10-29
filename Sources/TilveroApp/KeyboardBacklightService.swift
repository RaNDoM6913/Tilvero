import Foundation
import Combine
import CoreFoundation
import KeyboardBackends

enum KeyboardBacklightAvailability: Equatable {
    case unknown, available, unsupported, unavailable
}
@MainActor protocol KeyboardBacklightPreferenceStorage: AnyObject {
    var lastNonzeroBrightness: Double? { get set }
}
@MainActor final class UserDefaultsKeyboardBacklightStorage: KeyboardBacklightPreferenceStorage {
    static let key = "keyboardBacklightLastNonzeroBrightness"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var lastNonzeroBrightness: Double? {
        get {
            guard let value = defaults.object(forKey: Self.key) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue > 0, value.doubleValue <= 1 else { return nil }
            return value.doubleValue
        }
        set {
            guard let newValue, newValue.isFinite, newValue > 0, newValue <= 1 else { return }
            defaults.set(newValue, forKey: Self.key)
        }
    }
}

/// Explicit user operations only. The service never acquires ongoing keyboard ownership,
/// adjusts automatic brightness/idle policy, or writes from construction/refresh.
@MainActor final class KeyboardBacklightService: ObservableObject {
    @Published private(set) var observation: KeyboardBacklightObservation?
    @Published private(set) var availability: KeyboardBacklightAvailability = .unknown
    @Published private(set) var error: KeyboardBacklightError?
    @Published private(set) var isBusy = false
    @Published private(set) var requestedBrightness: Double?
    @Published private(set) var lastAppliedBrightness: Double?
    /// A requested fallback for a previously unseen off keyboard, never an observed reading.
    let fallbackOnBrightness = 0.25
    var brightness: Double? { observation?.brightness }
    var isEnabled: Bool? { observation?.isEnabled }
    var isAvailable: Bool { availability == .available }
    private let driver: any KeyboardBacklightTransport
    private let storage: any KeyboardBacklightPreferenceStorage
    private let allowed: Bool
    init(driver: any KeyboardBacklightTransport = NativeKeyboardBacklightTransport(),
         storage: any KeyboardBacklightPreferenceStorage = UserDefaultsKeyboardBacklightStorage(),
         allowed: Bool = true) {
        self.driver = driver; self.storage = storage; self.allowed = allowed
    }
    func refresh() async {
        guard !isBusy else { return }
        guard allowed else { invalidate(.disabledInSimulation); return }
        isBusy = true
        defer { isBusy = false }
        do { accept(try await driver.read()); error = nil }
        catch { invalidate(Self.typed(error)) }
    }
    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        guard allowed else { invalidate(.disabledInSimulation); return }
        isBusy = true; error = nil; lastAppliedBrightness = nil; requestedBrightness = nil
        defer { isBusy = false }
        let before: KeyboardBacklightObservation
        do { before = try await driver.read(); accept(before) }
        catch { invalidate(Self.typed(error)); return }
        // An already-observed matching state needs no setter and makes no applied claim.
        if before.isEnabled == enabled { return }
        let remembered = storage.lastNonzeroBrightness
        let target = enabled ? (remembered.flatMap { $0.isFinite && $0 > 0 && $0 <= 1 ? $0 : nil } ?? fallbackOnBrightness) : 0
        requestedBrightness = target
        do { try await driver.setBrightness(target, keyboardID: before.keyboardID) }
        catch {
            let failure = Self.typed(error)
            // A failing setter can still have changed state; always reacquire actual readback.
            do { accept(try await driver.read()); self.error = failure }
            catch { invalidate(.unconfirmedWrite) }
            return
        }
        do {
            let after = try await driver.read(); accept(after)
            guard after.keyboardID == before.keyboardID else { error = .unconfirmedWrite; return }
            guard after.automaticBrightness == before.automaticBrightness else { error = .automaticPolicyChanged; return }
            // Off must be zero. On permits <=0.5 percentage-point readback quantization,
            // but suppressed/dimmed positive settings never count as confirmed illumination.
            let matches = target == 0 ? after.brightness == 0 : abs(after.brightness - target) <= 0.005
            guard matches, after.isEnabled == enabled else { error = .unconfirmedWrite; return }
            lastAppliedBrightness = after.brightness
        } catch { invalidate(.unconfirmedWrite) }
    }
    private func accept(_ observed: KeyboardBacklightObservation) {
        observation = observed; availability = .available
        if observed.brightness > 0 { storage.lastNonzeroBrightness = observed.brightness }
    }
    private func invalidate(_ failure: KeyboardBacklightError) {
        observation = nil; error = failure
        availability = failure == .unsupported ? .unsupported : .unavailable
    }
    private static func typed(_ error: Error) -> KeyboardBacklightError { error as? KeyboardBacklightError ?? .unavailable }
}
