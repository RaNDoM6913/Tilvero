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
///
/// All writes and restores run one at a time (`exclusive`), so a lid that bounces open and closed again never lets an
/// apply and a restore interleave.
@MainActor final class LidComfortService: ObservableObject {
    static let journalKey = "lidClosedComfortJournal.v1"
    /// Per-mode preference keys; the scheduled-sleep ones carry the same suffix as `lidClosedPreferredScheduledSleep`.
    static func key(_ base: String, _ mode: LidComfortMode) -> String { mode == .keepAwake ? base : base + "ScheduledSleep" }
    static let dimKey = "lidClosedDimDisplay", displayLevelKey = "lidClosedDisplayLevel"
    static let limitKey = "lidClosedLimitVolume", volumeLevelKey = "lidClosedVolumeLevel"
    /// A restore that did not land (the panel may refuse a write right after the lid opens) is retried this many times.
    static let maximumRestoreRetries = 8

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
    private let restoreRetryDelay: Duration
    private let now: @Sendable () -> Date

    private var armedMode: LidComfortMode?
    private var lastSample = ClamshellSample(lidClosed: nil, causesSleep: nil)
    /// This lid-close has been (or is being) handled; reset when the lid opens or the override ends.
    private var closeHandled = false
    private var clamshellSubscription: (any ComfortSubscription)?
    private var audioSubscription: (any ComfortSubscription)?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var journal: LidComfortJournal?
    private var lockHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var armedSubscription: AnyCancellable?

    init(display: any DisplayBrightnessTransport = NativeDisplayBrightnessTransport(),
         audio: any OutputVolumeTransport = NativeOutputVolumeTransport(),
         clamshell: any LidComfortClamshell = NativeLidComfortClamshell(),
         defaults: UserDefaults = .standard, allowed: Bool = true,
         consoleUserIsUs: @escaping @Sendable () -> Bool = LidComfortService.currentConsoleUserIsUs,
         debounce: Duration = .milliseconds(1500), retryDelay: Duration = .milliseconds(400),
         restoreRetryDelay: Duration = .seconds(2),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.display = display; self.audio = audio; self.clamshell = clamshell; self.defaults = defaults
        isAvailable = allowed
        self.consoleUserIsUs = consoleUserIsUs; self.debounce = debounce; self.retryDelay = retryDelay
        self.restoreRetryDelay = restoreRetryDelay; self.now = now
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

    // MARK: Serial execution

    private func acquire() async {
        if !lockHeld { lockHeld = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { lockHeld = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Binding to the lid override

    /// Armed only while the override is confirmed on for a mode; releases (restores) before the override is ever lifted.
    func bind(_ lidSleep: LidSleepOverrideService) {
        guard isAvailable else { return }
        lidSleep.beforeRelease = { [weak self] in await self?.disarmAndRestore() }
        armedSubscription = lidSleep.$activeMode.combineLatest(lidSleep.$isOn)
            .map { mode, on -> LidComfortMode? in on ? mode?.comfortMode : nil }.removeDuplicates()
            .sink { [weak self] mode in Task { @MainActor [weak self] in self?.armedChanged(mode) } }
    }

    /// The override is about to be released: nothing may be applied from here on (a pending debounce or a late lid
    /// sample would otherwise re-apply in the middle of the release), and everything goes back first.
    func disarmAndRestore() async {
        armedMode = nil
        debounceTask?.cancel(); debounceTask = nil
        retryTask?.cancel(); retryTask = nil
        await restoreAll()
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
            closeHandled = false
            if journal != nil { Task { await restoreAll() } } else { tearDownObservers() }
        }
    }

    func sampleChanged(_ sample: ClamshellSample) {
        guard isAvailable else { return }
        lastSample = sample
        if sample.isOpen {
            debounceTask?.cancel(); debounceTask = nil
            closeHandled = false
            if journal != nil { Task { await restoreAll() } }
            else { stopAudioObservation() }
            return
        }
        guard sample.closedAndWouldSleep, armedMode != nil, !closeHandled, debounceTask == nil else { return }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed()
        }
    }

    private func debounceElapsed() async {
        debounceTask = nil
        guard armedMode != nil else { return }
        await acquire(); defer { release() }
        // Conditions are checked again once it is this apply's turn: a restore queued before it may have changed them.
        guard let mode = armedMode, !closeHandled else { return }
        let fresh = clamshell.sample()
        lastSample = fresh
        guard fresh.closedAndWouldSleep, consoleUserIsUs() else { return }
        closeHandled = true
        await apply(mode)
    }

    func systemDidWake() {
        guard isAvailable else { return }
        sampleChanged(clamshell.sample())
    }

    // MARK: Apply (runs under `exclusive`)

    private func apply(_ mode: LidComfortMode) async {
        let settings = self.settings(for: mode).sanitized
        guard settings.isActive else { return }
        if journal == nil { journal = LidComfortJournal(mode: mode, entries: [], createdAt: now()) }
        if settings.dimDisplay { await capDisplay(level: settings.displayLevel) }
        if settings.limitVolume {
            await capDefaultOutput(level: settings.volumeLevel)
            startAudioObservation()
        }
        finishJournalChange()
        // The lid may have opened, or the override ended, while the writes were in flight.
        if armedMode == nil || !lastSample.closedAndWouldSleep { await restoreLocked() }
    }

    private func capDisplay(level: Double) async {
        guard let reading = try? await display.read(),
              journalEntry(.display(id: reading.displayID)) == nil,
              let target = LidComfortPolicy.capTarget(current: reading.value, level: level) else { return }
        let id = reading.displayID
        record(LidComfortEntry(target: .display(id: id), original: reading.value, written: target, phase: .intent, createdAt: now()))
        _ = try? await display.set(target, displayID: id)
        confirm(.display(id: id), original: reading.value, observed: (try? await display.read())?.value)
    }

    private func capDefaultOutput(level: Double) async {
        guard let output = try? await audio.defaultOutput(), output.isSettable, output.muted != true, let volume = output.volume,
              journalEntry(.volume(deviceUID: output.deviceUID)) == nil,
              let target = LidComfortPolicy.capTarget(current: volume, level: level) else { return }
        record(LidComfortEntry(target: .volume(deviceUID: output.deviceUID), original: volume, written: target, phase: .intent, createdAt: now()))
        _ = try? await audio.setVolume(target, deviceUID: output.deviceUID)
        confirm(.volume(deviceUID: output.deviceUID), original: volume, observed: (try? await audio.volume(deviceUID: output.deviceUID)) ?? nil)
    }

    /// The default output moved (AirPods connected or gone) while the lid is closed and comfort is active: cap the new
    /// device too. Never acts with the lid open or the override off.
    private func defaultOutputChanged() async {
        if armedMode == nil || !lastSample.closedAndWouldSleep {
            // A kept entry for a device that just reappeared gets its restore retried.
            if journal != nil { await restoreAll() }
            return
        }
        await acquire(); defer { release() }
        guard let mode = armedMode, lastSample.closedAndWouldSleep, closeHandled, settings(for: mode).limitVolume else { return }
        if journal == nil { journal = LidComfortJournal(mode: mode, entries: [], createdAt: now()) }
        await capDefaultOutput(level: settings(for: mode).volumeLevel)
        finishJournalChange()
    }

    private func startAudioObservation() {
        guard audioSubscription == nil else { return }
        audioSubscription = audio.observeDefaultOutputChanges { [weak self] in
            Task { @MainActor [weak self] in await self?.defaultOutputChanged() }
        }
    }
    private func stopAudioObservation() { audioSubscription?.cancel(); audioSubscription = nil }
    private func tearDownObservers() {
        stopAudioObservation()
        clamshellSubscription?.cancel(); clamshellSubscription = nil
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
    }

    // MARK: Restore

    /// Safe to call from any end path, any number of times.
    func restoreAll() async {
        retryCount = 0
        await acquire(); defer { release() }
        await restoreLocked()
    }
    private func restore(onlyIf include: (LidComfortEntry) -> Bool) async {
        await acquire(); defer { release() }
        await restoreLocked(onlyIf: include)
    }

    private func restoreLocked(onlyIf include: (LidComfortEntry) -> Bool = { _ in true }) async {
        if let entries = journal?.entries {
            for entry in entries where include(entry) {
                if await restoreOne(entry) != .keep { journal?.entries.removeAll { $0.target == entry.target } }
            }
        }
        finishJournalChange()
        if !(armedMode != nil && lastSample.closedAndWouldSleep) { stopAudioObservation() }
        if armedMode == nil, journal == nil { tearDownObservers() }
        if journal != nil, !lastSample.closedAndWouldSleep { scheduleRestoreRetry() }
        // A close that arrived while this restore was running is handled now, not lost.
        if armedMode != nil, lastSample.closedAndWouldSleep, !closeHandled, debounceTask == nil { sampleChanged(lastSample) }
    }

    /// Entries that could not be restored (panel refusing writes right after the lid opens, device not back yet) are
    /// tried again a bounded number of times: the screen must not stay dark waiting for the next event.
    private func scheduleRestoreRetry() {
        guard retryTask == nil, retryCount < Self.maximumRestoreRetries else { return }
        retryCount += 1
        retryTask = Task { [weak self, restoreRetryDelay] in
            try? await Task.sleep(for: restoreRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard self.journal != nil, !self.lastSample.closedAndWouldSleep else { return }
            await self.acquire(); defer { self.release() }
            await self.restoreLocked()
        }
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
        case .display:
            // The built-in display is resolved again: an id from before a reboot is not trusted.
            guard let current = try? await display.read() else { return }
            _ = try? await display.set(value, displayID: current.displayID)
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
        await disarmAndRestore()
        return journal == nil
    }
}
