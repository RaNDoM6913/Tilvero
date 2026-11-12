// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

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
    /// While a slider or switch operation is in flight (pre-read, write, readback) the UI keeps showing what the user
    /// asked for instead of the old observation: no jump back and forth.
    @Published private(set) var pendingBrightness: Double?
    @Published private(set) var pendingEnabled: Bool?
    /// A requested fallback for a previously unseen off keyboard, never an observed reading.
    let fallbackOnBrightness = 0.25
    var brightness: Double? { observation?.brightness }
    var isEnabled: Bool? { observation?.isEnabled }
    var isAvailable: Bool { availability == .available }
    private let driver: any KeyboardBacklightTransport
    private let storage: any KeyboardBacklightPreferenceStorage
    private let allowed: Bool
    /// The keyboard backlight fades to a new level; a readback right after the write may still show a step on the way.
    private let settleDelay: Duration
    init(driver: any KeyboardBacklightTransport = NativeKeyboardBacklightTransport(),
         storage: any KeyboardBacklightPreferenceStorage = UserDefaultsKeyboardBacklightStorage(),
         allowed: Bool = true, settleDelay: Duration = .milliseconds(100)) {
        self.driver = driver; self.storage = storage; self.allowed = allowed; self.settleDelay = settleDelay
    }
    /// Reads back after a write; a level still on its way (a fade) is read again a few times before it counts as unconfirmed.
    private func readbackSettling(matching matches: (KeyboardBacklightObservation) -> Bool) async throws -> KeyboardBacklightObservation {
        var observed = try await driver.read()
        var attempts = 0
        while !matches(observed), attempts < 5 {
            attempts += 1
            try? await Task.sleep(for: settleDelay)
            observed = try await driver.read()
        }
        return observed
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
        pendingEnabled = enabled
        defer { isBusy = false; pendingEnabled = nil }
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
            let after = try await readbackSettling { observed in
                (target == 0 ? observed.brightness == 0 : abs(observed.brightness - target) <= 0.005) && observed.isEnabled == enabled
            }
            accept(after)
            guard after.keyboardID == before.keyboardID else { error = .unconfirmedWrite; return }
            guard after.automaticBrightness == before.automaticBrightness else { error = .automaticPolicyChanged; return }
            // Off must be zero. On permits <=0.5 percentage-point readback quantization,
            // but suppressed/dimmed positive settings never count as confirmed illumination.
            let matches = target == 0 ? after.brightness == 0 : abs(after.brightness - target) <= 0.005
            guard matches, after.isEnabled == enabled else { error = .unconfirmedWrite; return }
            lastAppliedBrightness = after.brightness
        } catch { invalidate(.unconfirmedWrite) }
    }
    /// Explicit slider commit: writes the requested brightness (0...1), then confirms it by readback.
    func setBrightness(_ requested: Double) async {
        guard !isBusy else { return }
        guard allowed else { invalidate(.disabledInSimulation); return }
        guard requested.isFinite else { error = .invalidBrightness; return }
        let target = min(1, max(0, requested))
        isBusy = true; error = nil; lastAppliedBrightness = nil; requestedBrightness = nil
        pendingBrightness = target
        defer { isBusy = false; pendingBrightness = nil }
        let before: KeyboardBacklightObservation
        do { before = try await driver.read(); accept(before) }
        catch { invalidate(Self.typed(error)); return }
        if target == 0 ? before.brightness == 0 : abs(before.brightness - target) <= 0.005 { return }
        requestedBrightness = target
        do { try await driver.setBrightness(target, keyboardID: before.keyboardID) }
        catch {
            let failure = Self.typed(error)
            do { accept(try await driver.read()); self.error = failure }
            catch { invalidate(.unconfirmedWrite) }
            return
        }
        do {
            let after = try await readbackSettling { target == 0 ? $0.brightness == 0 : abs($0.brightness - target) <= 0.005 }
            accept(after)
            guard after.keyboardID == before.keyboardID else { error = .unconfirmedWrite; return }
            guard after.automaticBrightness == before.automaticBrightness else { error = .automaticPolicyChanged; return }
            guard target == 0 ? after.brightness == 0 : abs(after.brightness - target) <= 0.005 else { error = .unconfirmedWrite; return }
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
