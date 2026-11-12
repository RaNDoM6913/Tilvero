// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine
import SystemConfiguration
import PowerCore
import PowerTelemetry
import ComfortBackends

/// Everything the service reads about the lid. Production uses `NativeLidComfortClamshell`; tests inject a fake, so
/// the default test run never needs a lid.
protocol LidComfortClamshell: AnyObject, Sendable {
    func sample() -> ClamshellSample
    func observe(_ handler: @escaping @Sendable (ClamshellSample) -> Void) -> any ComfortSubscription
}

final class NativeLidComfortClamshell: LidComfortClamshell, @unchecked Sendable {
    private final class Subscription: ComfortSubscription, @unchecked Sendable {
        private let observer: ClamshellStateObserver?
        init(_ observer: ClamshellStateObserver?) { self.observer = observer }
        func cancel() { observer?.stop() }
    }
    func sample() -> ClamshellSample { ClamshellStateObserver.currentSample() }
    func observe(_ handler: @escaping @Sendable (ClamshellSample) -> Void) -> any ComfortSubscription {
        Subscription(ClamshellStateObserver(handler: handler))
    }
}

extension LidMode {
    var comfortMode: LidComfortMode { self == .keepAwake ? .keepAwake : .scheduledSleep }
}

/// While the Mac is kept awake with the lid closed (Keep Awake, or the sleep timer / Sleep at charge, each with
/// "With lid closed" on), the built-in display is turned down and the output volume is capped; both come back when the
/// lid opens or the override ends. Values are only ever lowered ("no brighter / no louder than"), the snapshot is taken
/// at lid close and journaled before the first write, and only what this app wrote is restored. No root, no helper.
@MainActor final class LidComfortService: ObservableObject {
    static let journalKey = "lidClosedComfortJournal.v1"
    /// Per-mode preference keys; the scheduled-sleep ones carry the same suffix as `lidClosedPreferredScheduledSleep`.
    static func key(_ base: String, _ mode: LidComfortMode) -> String { mode == .keepAwake ? base : base + "ScheduledSleep" }
    static let dimKey = "lidClosedDimDisplay", displayLevelKey = "lidClosedDisplayLevel"
    static let limitKey = "lidClosedLimitVolume", volumeLevelKey = "lidClosedVolumeLevel"

    @Published private(set) var keepAwakeSettings = LidComfortSettings.default
    @Published private(set) var scheduledSleepSettings = LidComfortSettings.default
    /// Brightness and/or volume are currently lowered by this app (a journal exists).
    @Published private(set) var isApplied = false

    let isAvailable: Bool
    private let display: any DisplayBrightnessTransport
    private let audio: any OutputVolumeTransport
    private let clamshell: any LidComfortClamshell
    private let defaults: UserDefaults
    private let consoleUserIsUs: @Sendable () -> Bool
    private let debounce: Duration
    private let retryDelay: Duration
    private let now: @Sendable () -> Date

    private var armedMode: LidComfortMode?
    private var lastSample = ClamshellSample(lidClosed: nil, causesSleep: nil)
    private var clamshellSubscription: (any ComfortSubscription)?
    private var audioSubscription: (any ComfortSubscription)?
    private var debounceTask: Task<Void, Never>?
    private var journal: LidComfortJournal?
    private var working = false
    private var armedSubscription: AnyCancellable?

    init(display: any DisplayBrightnessTransport = NativeDisplayBrightnessTransport(),
         audio: any OutputVolumeTransport = NativeOutputVolumeTransport(),
         clamshell: any LidComfortClamshell = NativeLidComfortClamshell(),
         defaults: UserDefaults = .standard, allowed: Bool = true,
         consoleUserIsUs: @escaping @Sendable () -> Bool = LidComfortService.currentConsoleUserIsUs,
         debounce: Duration = .milliseconds(1500), retryDelay: Duration = .milliseconds(400),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.display = display; self.audio = audio; self.clamshell = clamshell; self.defaults = defaults
        isAvailable = allowed
        self.consoleUserIsUs = consoleUserIsUs; self.debounce = debounce; self.retryDelay = retryDelay; self.now = now
        keepAwakeSettings = Self.load(.keepAwake, defaults)
        scheduledSleepSettings = Self.load(.scheduledSleep, defaults)
        if allowed, let data = defaults.data(forKey: Self.journalKey) {
            journal = LidComfortJournal.decode(data)
            if journal == nil { defaults.removeObject(forKey: Self.journalKey) }   // unusable: never replayed
            isApplied = journal != nil
        }
    }

    nonisolated static func currentConsoleUserIsUs() -> Bool {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return false }
        return uid == getuid()
    }

    // MARK: Settings

    func settings(for mode: LidComfortMode) -> LidComfortSettings { mode == .keepAwake ? keepAwakeSettings : scheduledSleepSettings }

    func update(_ settings: LidComfortSettings, for mode: LidComfortMode) {
        guard isAvailable else { return }
        let clean = settings.sanitized
        defaults.set(clean.dimDisplay, forKey: Self.key(Self.dimKey, mode))
        defaults.set(clean.displayLevel, forKey: Self.key(Self.displayLevelKey, mode))
        defaults.set(clean.limitVolume, forKey: Self.key(Self.limitKey, mode))
        defaults.set(clean.volumeLevel, forKey: Self.key(Self.volumeLevelKey, mode))
        if mode == .keepAwake { keepAwakeSettings = clean } else { scheduledSleepSettings = clean }
        // A switch turned off while applied puts that target back at once; a level change waits for the next close.
        guard let journal, journal.mode == mode else { return }
        Task { await restore(onlyIf: { entry in
            switch entry.target {
            case .display: !clean.dimDisplay
            case .volume: !clean.limitVolume
            }
        }) }
    }

    private static func load(_ mode: LidComfortMode, _ defaults: UserDefaults) -> LidComfortSettings {
        func bool(_ base: String, _ fallback: Bool) -> Bool {
            guard let number = defaults.object(forKey: key(base, mode)) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
            return number.boolValue
        }
        func level(_ base: String, _ fallback: Double) -> Double {
            guard let number = defaults.object(forKey: key(base, mode)) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
            return number.doubleValue
        }
        let d = LidComfortSettings.default
        return LidComfortSettings(dimDisplay: bool(dimKey, d.dimDisplay), displayLevel: level(displayLevelKey, d.displayLevel),
                                  limitVolume: bool(limitKey, d.limitVolume), volumeLevel: level(volumeLevelKey, d.volumeLevel)).sanitized
    }

    // MARK: Binding to the lid override

    /// Armed only while the override is confirmed on for a mode; restores before the override is ever released.
    func bind(_ lidSleep: LidSleepOverrideService) {
        guard isAvailable else { return }
        lidSleep.beforeRelease = { [weak self] in await self?.restoreAll() }
        armedSubscription = lidSleep.$activeMode.combineLatest(lidSleep.$isOn)
            .map { mode, on -> LidComfortMode? in on ? mode?.comfortMode : nil }.removeDuplicates()
            .sink { [weak self] mode in Task { @MainActor [weak self] in self?.armedChanged(mode) } }
    }

    func armedChanged(_ mode: LidComfortMode?) {
        guard isAvailable else { return }
        armedMode = mode
        if mode != nil {
            if clamshellSubscription == nil {
                clamshellSubscription = clamshell.observe { [weak self] sample in
                    Task { @MainActor [weak self] in self?.sampleChanged(sample) }
                }
            }
            sampleChanged(clamshell.sample())
        } else {
            debounceTask?.cancel(); debounceTask = nil
            if journal != nil { Task { await restoreAll() } }
            if journal == nil { clamshellSubscription?.cancel(); clamshellSubscription = nil }
        }
    }

    func sampleChanged(_ sample: ClamshellSample) {
        guard isAvailable else { return }
        lastSample = sample
        if sample.isOpen {
            debounceTask?.cancel(); debounceTask = nil
            if journal != nil { Task { await restoreAll() } }
            return
        }
        guard sample.closedAndWouldSleep, armedMode != nil, journal == nil, debounceTask == nil else { return }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed()
        }
    }

    private func debounceElapsed() async {
        debounceTask = nil
        guard let mode = armedMode else { return }
        let fresh = clamshell.sample()
        lastSample = fresh
        guard fresh.closedAndWouldSleep, consoleUserIsUs(), journal == nil else { return }
        await apply(mode)
    }

    func systemDidWake() {
        guard isAvailable else { return }
        sampleChanged(clamshell.sample())
    }

    // MARK: Apply

    private func apply(_ mode: LidComfortMode) async {
        guard !working else { return }
        working = true; defer { working = false }
        let settings = self.settings(for: mode).sanitized
        guard settings.isActive else { return }
        journal = LidComfortJournal(mode: mode, entries: [], createdAt: now())
        if settings.dimDisplay { await capDisplay(level: settings.displayLevel) }
        if settings.limitVolume { await capDefaultOutput(level: settings.volumeLevel) }
        finishJournalChange()
        if journal != nil, settings.limitVolume, audioSubscription == nil {
            audioSubscription = audio.observeDefaultOutputChanges { [weak self] in
                Task { @MainActor [weak self] in await self?.defaultOutputChanged() }
            }
        }
        // The lid may have opened, or the override ended, while the writes were in flight.
        if armedMode == nil || !lastSample.closedAndWouldSleep { await restoreLocked() }
    }

    private func capDisplay(level: Double) async {
        guard let reading = try? await display.read(),
              let target = LidComfortPolicy.capTarget(current: reading.value, level: level) else { return }
        let id = reading.displayID
        record(LidComfortEntry(target: .display(id: id), original: reading.value, written: target, phase: .intent, createdAt: now()))
        _ = try? await display.set(target, displayID: id)
        confirm(.display(id: id), original: reading.value, observed: (try? await display.read())?.value)
    }

    private func capDefaultOutput(level: Double) async {
        guard let output = try? await audio.defaultOutput(), output.isSettable, output.muted != true, let volume = output.volume,
              let target = LidComfortPolicy.capTarget(current: volume, level: level) else { return }
        guard journalEntry(.volume(deviceUID: output.deviceUID)) == nil else { return }
        record(LidComfortEntry(target: .volume(deviceUID: output.deviceUID), original: volume, written: target, phase: .intent, createdAt: now()))
        _ = try? await audio.setVolume(target, deviceUID: output.deviceUID)
        confirm(.volume(deviceUID: output.deviceUID), original: volume, observed: (try? await audio.volume(deviceUID: output.deviceUID)) ?? nil)
    }

    private func defaultOutputChanged() async {
        guard let mode = journal?.mode, !working, settings(for: mode).limitVolume else { return }
        working = true; defer { working = false }
        await capDefaultOutput(level: settings(for: mode).volumeLevel)
        finishJournalChange()
    }

    /// Written down before the setter runs: a crash after the write must still be recoverable.
    private func record(_ entry: LidComfortEntry) {
        journal?.entries.append(entry)
        persist()
    }
    private func journalEntry(_ target: LidComfortEntry.Target) -> LidComfortEntry? { journal?.entries.first { $0.target == target } }

    /// After the setter: the readback decides. Equal to the original → it never landed, drop the entry; otherwise the
    /// observed value is what must be recognised at restore time. An unreadable device keeps the intent.
    private func confirm(_ target: LidComfortEntry.Target, original: Double, observed: Double?) {
        guard let index = journal?.entries.firstIndex(where: { $0.target == target }), let observed else { return }
        if abs(observed - original) <= LidComfortPolicy.tolerance {
            journal?.entries.remove(at: index)
        } else {
            journal?.entries[index].written = observed
            journal?.entries[index].phase = .applied
        }
        persist()
    }

    private func persist() {
        if let journal, !journal.entries.isEmpty, let data = try? journal.encoded() { defaults.set(data, forKey: Self.journalKey) }
        else { defaults.removeObject(forKey: Self.journalKey) }
    }
    private func finishJournalChange() {
        if journal?.entries.isEmpty == true { journal = nil }
        persist()
        isApplied = journal != nil
        if journal == nil { audioSubscription?.cancel(); audioSubscription = nil }
    }

    // MARK: Restore

    /// Safe to call from any end path, any number of times.
    func restoreAll() async {
        for _ in 0..<100 where working { try? await Task.sleep(for: .milliseconds(20)) }
        working = true; defer { working = false }
        await restoreLocked()
    }
    private func restore(onlyIf include: (LidComfortEntry) -> Bool) async {
        for _ in 0..<100 where working { try? await Task.sleep(for: .milliseconds(20)) }
        working = true; defer { working = false }
        await restoreLocked(onlyIf: include)
    }

    private func restoreLocked(onlyIf include: (LidComfortEntry) -> Bool = { _ in true }) async {
        guard let entries = journal?.entries else { return }
        for entry in entries where include(entry) {
            let outcome = await restoreOne(entry)
            if outcome != .keep { journal?.entries.removeAll { $0.target == entry.target } }
        }
        finishJournalChange()
        if journal == nil, armedMode == nil { clamshellSubscription?.cancel(); clamshellSubscription = nil }
    }

    private enum Outcome { case done, keep }
    private func currentValue(_ target: LidComfortEntry.Target) async -> Double? {
        switch target {
        case .display: return (try? await display.read())?.value
        case .volume(let uid): return (try? await audio.volume(deviceUID: uid)) ?? nil
        }
    }
    private func write(_ value: Double, to target: LidComfortEntry.Target) async {
        switch target {
        case .display(let id): _ = try? await display.set(value, displayID: id)
        case .volume(let uid): _ = try? await audio.setVolume(value, deviceUID: uid)
        }
    }

    private func restoreOne(_ entry: LidComfortEntry) async -> Outcome {
        switch LidComfortPolicy.restoreDecision(for: entry, current: await currentValue(entry.target), now: now()) {
        case .clear: return .done
        case .keep: return .keep
        case .write(let original):
            // A panel may refuse a write right after the lid opens: a few bounded retries until the readback matches.
            for attempt in 0..<3 {
                await write(original, to: entry.target)
                if let read = await currentValue(entry.target), abs(read - original) <= LidComfortPolicy.tolerance { return .done }
                if attempt < 2 { try? await Task.sleep(for: retryDelay) }
            }
            return .keep
        }
    }

    /// Launch recovery: a journal left by a crashed or killed run is replayed under the same rules (lid open or not
    /// armed: restore; values the user changed meanwhile are left alone).
    func recoverIfNeeded() async {
        guard isAvailable, journal != nil else { return }
        lastSample = clamshell.sample()
        await restoreAll()
    }

    @discardableResult func prepareForTermination() async -> Bool {
        guard isAvailable else { return true }
        debounceTask?.cancel(); debounceTask = nil
        await restoreAll()
        return journal == nil
    }
}
