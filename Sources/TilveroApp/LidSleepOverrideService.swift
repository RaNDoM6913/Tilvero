import AppKit
import Combine
import Darwin
import IOKit
import IOKit.pwr_mgt
import PowerCore

// Closed-lid keep-awake through the system's `pmset disablesleep` override, the approach used by
// vorssaint-utils (GPL-3.0, https://github.com/vorssaint/vorssaint-utils; see THIRD_PARTY_NOTICES.md). The
// design here is our own: the override exists only while Keep Awake runs, its intent is written down before the
// system is touched, and every end path (switch, Keep Awake ending, quit, sleep request, next launch) restores it.
// Because the setting is system-wide and outlives the app, each session is also guarded by a lid watchdog (see
// `LidWatchdog`): a crash, a force quit or a kill still puts normal sleep back.

/// Every call that touches the system. Production uses `NativeLidSleepSystem`; tests inject a fake, so the default
/// test run never changes a power setting, prompts for a password or writes a sudoers file.
protocol LidSleepSystem: Sendable {
    /// `pmset -g` reading of `SleepDisabled`; nil when it cannot be read.
    func readSleepDisabled() async -> Bool?
    /// Re-applies the current state through `sudo -n`: proves the passwordless path by using it.
    func passwordlessPathWorks() async -> Bool
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool
    /// Administrator prompt: install the one-command sudoers rule.
    func installRule() async -> Bool
    func removeRule() async -> Bool
    /// Administrator prompt: `pmset disablesleep 0` when the passwordless path is gone.
    func restoreWithAuthorization() async -> Bool
    var ruleFilePresent: Bool { get }
    /// True only when the lid is closed AND macOS would sleep because of it (not with an external display attached).
    func lidClosedWouldSleep() -> Bool
    func requestSleep() -> Bool
}

/// The holds the lid option can accompany. Each has its own switch; they share the one permission and one override.
enum LidMode: Equatable { case keepAwake, scheduledSleep }

@MainActor final class LidSleepOverrideService: ObservableObject {
    /// Until 0.7.1 the intent marker was this UserDefaults bool. It is still read for one release (as a marker with an
    /// unknown owner) and removed once normal sleep is confirmed; it is never written any more.
    static let legacyRecoveryKey = "lidSleepOverrideActive"
    static let preferenceKey = "lidClosedPreferred"
    static let scheduledSleepPreferenceKey = "lidClosedPreferredScheduledSleep"
    /// Set once the one-time cleanup of a pre-0.7.2 leftover (`SleepDisabled 1` without any marker) has settled.
    static let leftoverCleanupKey = "lidLeftoverCleanupDone"
    /// The option: "with the lid closed" applies to every Keep Awake session the user starts. It never starts one.
    @Published private(set) var isPreferred = false
    /// The one option for the sleep timer AND Sleep at charge: a running timer / an armed level also continues with the lid
    /// closed and the Mac sleeps only when it ends.
    @Published private(set) var isPreferredForScheduledSleep = false
    /// The override itself is in effect (a Keep Awake session is running and the option is on).
    @Published private(set) var isOn = false
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    /// The override may still be set after a failed restore or a crash: shown with a recovery action.
    @Published private(set) var needsRecovery = false
    /// `SleepDisabled 1` while Tilvero holds no session (a run that ended without restoring, or another tool): the Mac
    /// does not sleep with the lid closed. Read at launch and when a Sleep page appears; shown with "Restore sleep".
    @Published private(set) var systemSleepDisabled = false
    /// The system sleep state was read at least once (a failed `pmset -g` leaves it unknown, never "normal").
    @Published private(set) var systemSleepKnown = false
    @Published private(set) var ruleFilePresent = false

    private let system: any LidSleepSystem
    private let defaults: UserDefaults
    private let allowed: Bool
    /// The on-disk intent marker (`lid-override.json` next to the history store) and its lock.
    let markers: LidOverrideMarkerStore
    private let markerLock: LidOverrideLockHolder
    private let watchdog: any LidWatchdogLaunching
    /// The watchdog guarding this run's override. Released only after a confirmed `SleepDisabled 0`; a failed restore
    /// keeps the pipe open, so the watchdog still acts if the app then ends.
    private var session: (token: String, handle: any LidWatchdogHandle)?
    /// Starting an override needs the lock (a watchdog of an ended run may be acting); restores only try for a while
    /// and continue without it, because clearing the setting is always safe.
    private let enableLockTimeout: Duration, restoreLockTimeout: Duration, recoveryLockTimeout: Duration
    /// Reading the system state for the warning: off for a model whose native system must not be touched (tests).
    private let observesSystemSleep: Bool
    private var systemCheckInFlight = false
    private var lastSystemCheck: ContinuousClock.Instant?
    /// Set by the model once the Keep Awake service exists.
    var awakeIsActive: @MainActor () -> Bool
    /// A sleep timer is armed (running, before it prepares to sleep) or Sleep at charge is armed. Set by the model.
    var scheduledSleepIsActive: @MainActor () -> Bool
    /// Which switch's session the override currently serves (nil while it is off).
    @Published private(set) var activeMode: LidMode?
    /// Awaited before the override is released, on every end path (stop, timer sleep, switch off, quit): the lid-close
    /// comfort service puts brightness and volume back first, so the Mac never sleeps with the screen still dimmed.
    var beforeRelease: @MainActor () async -> Void = {}
    private var timerRunning = false, chargeArmed = false
    private var timerSubscription: AnyCancellable?, chargeSubscription: AnyCancellable?
    private let lidSleepRetryDelay: Duration
    private var awakeSubscription: AnyCancellable?
    private var boundAwake: ObjectIdentifier?
    private var boundOwner: UInt32?
    private var generation: UInt64 = 0
    private var pendingEnd = false

    /// `markers` defaults to a private temporary directory and `watchdog` to one that refuses: whatever does not choose
    /// both explicitly can never start an override (the model passes the real ones).
    init(system: any LidSleepSystem = NativeLidSleepSystem(), defaults: UserDefaults = .standard, allowed: Bool = true,
         markers: LidOverrideMarkerStore? = nil, watchdog: any LidWatchdogLaunching = UnavailableLidWatchdogLauncher(),
         observesSystemSleep: Bool = true,
         awakeIsActive: @escaping @MainActor () -> Bool = { false },
         scheduledSleepIsActive: @escaping @MainActor () -> Bool = { false },
         lidSleepRetryDelay: Duration = .milliseconds(500),
         enableLockTimeout: Duration = .seconds(3), restoreLockTimeout: Duration = .seconds(3), recoveryLockTimeout: Duration = .seconds(10)) {
        self.system = system; self.defaults = defaults; self.allowed = allowed
        let store = markers ?? LidOverrideMarkerStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("TilveroLidMarker-\(UUID().uuidString)", isDirectory: true))
        self.markers = store; markerLock = LidOverrideLockHolder(store: store); self.watchdog = watchdog
        self.observesSystemSleep = observesSystemSleep
        self.enableLockTimeout = enableLockTimeout; self.restoreLockTimeout = restoreLockTimeout; self.recoveryLockTimeout = recoveryLockTimeout
        self.awakeIsActive = awakeIsActive; self.scheduledSleepIsActive = scheduledSleepIsActive; self.lidSleepRetryDelay = lidSleepRetryDelay
        needsRecovery = store.read().isPresent || defaults.bool(forKey: Self.legacyRecoveryKey)
        ruleFilePresent = system.ruleFilePresent
        isPreferred = allowed && defaults.bool(forKey: Self.preferenceKey)
        isPreferredForScheduledSleep = allowed && defaults.bool(forKey: Self.scheduledSleepPreferenceKey)
    }

    private func isActive(_ mode: LidMode) -> Bool { mode == .keepAwake ? awakeIsActive() : scheduledSleepIsActive() }
    /// A marker on disk (any owner) or the legacy flag: the override may be set.
    var markerPresent: Bool { markers.read().isPresent || defaults.bool(forKey: Self.legacyRecoveryKey) }
    private func anyActive() -> Bool { awakeIsActive() || scheduledSleepIsActive() }
    private func preferred(_ mode: LidMode) -> Bool { mode == .keepAwake ? isPreferred : isPreferredForScheduledSleep }
    private func storePreference(_ on: Bool, for mode: LidMode) {
        if mode == .keepAwake { isPreferred = on; defaults.set(on, forKey: Self.preferenceKey) }
        else { isPreferredForScheduledSleep = on; defaults.set(on, forKey: Self.scheduledSleepPreferenceKey) }
    }

    var isAvailable: Bool { allowed }
    var canEnable: Bool { allowed && !busy && !needsRecovery && !isOn && awakeIsActive() }

    /// The override belongs to one Keep Awake session: it is applied when a session starts while the option is on,
    /// and ended when that session ends or is replaced. The option itself stays.
    func bind(_ awake: KeepAwakeService) {
        guard boundAwake != ObjectIdentifier(awake) else { return }
        boundAwake = ObjectIdentifier(awake)
        boundOwner = awake.ownedAssertionID
        awakeSubscription = awake.$ownedAssertionID.dropFirst().sink { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self, id != self.boundOwner else { return }
                self.boundOwner = id
                if self.isOn || self.markerPresent {
                    await self.restore(userInitiated: false, sleepIfLidClosed: true)
                }
                if id != nil, self.isPreferred, !self.isOn, !self.needsRecovery { await self.enable(.keepAwake, allowPrompt: false) }
            }
        }
    }

    /// The override also belongs to one scheduled sleep: a sleep timer or Sleep at charge (one switch for both, they never
    /// run together). It starts when either is armed while that option is on and ends when it stops being armed. The
    /// timer's phases and the charge service's armed flag arrive as publishers (tests feed subjects).
    func bindTimer(phases: AnyPublisher<SleepTimerPhase, Never>) {
        timerSubscription = phases.sink { [weak self] phase in
            Task { @MainActor [weak self] in await self?.timerPhaseChanged(phase) }
        }
    }

    func bindSleepAtCharge(armed: AnyPublisher<Bool, Never>) {
        chargeSubscription = armed.sink { [weak self] isArmed in
            Task { @MainActor [weak self] in await self?.sleepAtChargeChanged(isArmed) }
        }
    }

    private func timerPhaseChanged(_ phase: SleepTimerPhase) async {
        let running = phase.isEditable            // armed and warning are one session
        guard running != timerRunning else { return }
        timerRunning = running
        // Into the timer's own sleep request (preparing, requesting, accepted) the override is only lifted: the timer
        // sleeps the Mac itself after its preparation. Any other end (cancel, failure) behaves like ending Keep Awake:
        // a lid that is already closed gets the sleep it would have caused.
        let intoSleep: Set<SleepTimerPhase> = [.preparing, .requesting, .accepted, .completed]
        await scheduledSleepChanged(running: running, sleepsItself: intoSleep.contains(phase))
    }

    private func sleepAtChargeChanged(_ isArmed: Bool) async {
        guard isArmed != chargeArmed else { return }
        chargeArmed = isArmed
        // When the level is reached the service's own preparation has already lifted the override before it clears the
        // target, so there is nothing left to restore (and nothing to sleep for: it requests the sleep itself). A cancel,
        // a stop or a system sleep reaches here with the override still set and restores it like ending Keep Awake.
        await scheduledSleepChanged(running: isArmed, sleepsItself: false)
    }

    private func scheduledSleepChanged(running: Bool, sleepsItself: Bool) async {
        if running {
            if isPreferredForScheduledSleep, !isOn, !needsRecovery { await enable(.scheduledSleep, allowPrompt: false) }
        } else if activeMode == .scheduledSleep || (activeMode == nil && markerPresent) {
            await restore(userInitiated: false, sleepIfLidClosed: !sleepsItself)
        }
    }

    // MARK: Option

    /// The switch. Turning it on only records the choice (and obtains the permission, the one administrator prompt, at
    /// the user's action); the override starts with the next Keep Awake session, or at once if one is running.
    func setPreferred(_ on: Bool, for mode: LidMode = .keepAwake) async {
        guard allowed else { return }
        if !on {
            storePreference(false, for: mode)
            failure = nil
            if activeMode == mode || (activeMode == nil && markerPresent) {
                await restore(userInitiated: true, sleepIfLidClosed: true)
            }
            return
        }
        guard !busy, !preferred(mode) else { return }
        guard !needsRecovery else { failure = L10n.text("Normal sleep could not be restored. Use Restore sleep."); return }
        busy = true; failure = nil
        // While this app's own override is on (the other switch's session), the permission demonstrably works and the
        // baseline check would only see our own setting as "another tool".
        let granted = isOn ? true : await prepareRule()
        busy = false
        guard granted else { return }
        storePreference(true, for: mode)
        if isActive(mode) { await enable(mode, allowPrompt: false) }
    }

    /// Checks the baseline and makes sure the passwordless path exists (prompting once if it does not).
    private func prepareRule() async -> Bool {
        let baseline = await system.readSleepDisabled()
        guard baseline == false else { refuseSetBaseline(baseline); return false }
        if !(await system.passwordlessPathWorks()) {
            guard await system.installRule(), await system.passwordlessPathWorks() else {
                failure = L10n.text("The permission was not granted. The lid mode stays off.")
                ruleFilePresent = system.ruleFilePresent
                return false
            }
        }
        ruleFilePresent = system.ruleFilePresent
        return true
    }

    /// An override that is already set is never adopted. A known `SleepDisabled 1` shows as the regular warning with
    /// "Restore sleep" (not a failure saying Tilvero will not change it, which contradicted that button and stuck until
    /// relaunch); only an unreadable state is a failure.
    private func refuseSetBaseline(_ reading: Bool?) {
        if reading == true { systemSleepDisabled = true; systemSleepKnown = true; failure = nil }
        else { failure = L10n.text("Sleep is already disabled by another tool or setting. Tilvero will not change it.") }
    }

    private func enable(_ mode: LidMode, allowPrompt: Bool) async {
        // While the permission is being removed an override could not be ended again: it never starts then.
        guard allowed, !busy, !needsRecovery, !isOn, isActive(mode), !PrivilegedRuleInstaller.removalInProgress else { return }
        busy = true; failure = nil; pendingEnd = false
        defer { busy = false }
        generation &+= 1
        let id = generation
        // Restore only what Tilvero owns: an override that is already set (another tool, the user's own pmset) or
        // unreadable is never adopted, because ending the session would clear a state this app did not create.
        let baseline = await system.readSleepDisabled()
        guard baseline == false else { refuseSetBaseline(baseline); return }
        guard generation == id, isActive(mode) else { return }
        if !(await system.passwordlessPathWorks()) {
            // A session starting by itself never raises a password prompt: the user is told how to repair it.
            guard allowPrompt, await system.installRule(), await system.passwordlessPathWorks() else {
                failure = L10n.text("The permission is missing. Switch With lid closed off and on again.")
                ruleFilePresent = system.ruleFilePresent
                return
            }
        }
        ruleFilePresent = system.ruleFilePresent
        guard generation == id, isActive(mode) else { return }
        guard await startGuardedOverride() else { return }
        if generation == id, isActive(mode) { isOn = true; activeMode = mode } else { await restoreInline(userInitiated: false, sleepIfLidClosed: true) }
        if pendingEnd { pendingEnd = false; await restoreInline(userInitiated: false, sleepIfLidClosed: true) }
    }

    /// Under the marker lock, so no watchdog of an ended run can act in between: the watchdog is started first, then
    /// the intent is written to disk, and only then is the system touched. A watchdog or marker that cannot be set up
    /// refuses the override. True when the override is confirmed set.
    private func startGuardedOverride() async -> Bool {
        guard await markerLock.acquire(timeout: enableLockTimeout) else {
            failure = L10n.text("The lid mode could not start safely.")
            return false
        }
        defer { markerLock.release() }
        // The lifeline: from here on, however this app ends, the watchdog puts normal sleep back.
        let token = UUID().uuidString
        guard let handle = await watchdog.launch(token: token, markerDirectory: markers.directory) else {
            failure = L10n.text("The lid mode could not start safely.")
            return false
        }
        // Written down before the system is touched: a crash after the write must still be recoverable.
        do {
            try markers.write(LidOverrideMarker(token: token, pid: getpid(), createdAt: Date(), boot: LidOverrideMarkerStore.bootSessionUUID()))
        } catch {
            handle.release()
            failure = L10n.text("The lid mode could not start safely.")
            return false
        }
        installSession(token: token, handle: handle)
        needsRecovery = false; systemSleepDisabled = false
        guard await system.setSleepDisabledPasswordless(true), await system.readSleepDisabled() == true else {
            // A refused write may still have applied: only a confirmed "off" removes the marker and lets the watchdog go.
            if await system.readSleepDisabled() == false { confirmNormalSleep() }
            else { needsRecovery = true }
            failure = L10n.text("macOS did not enable the lid mode.")
            return false
        }
        return true
    }

    /// A new session (or a replacement watchdog), a new token: a previous watchdog is released, and would only find a
    /// foreign marker anyway. The new one reports if it ends by itself while it still guards.
    private func installSession(token: String, handle: any LidWatchdogHandle) {
        let superseded = session?.handle
        session = (token, handle)
        handle.onUnexpectedExit { [weak self] in
            Task { @MainActor [weak self] in await self?.watchdogEnded(token: token) }
        }
        superseded?.release()
    }

    /// The watchdog of this run ended while it still guarded the override (killed, crashed). A new one takes over under
    /// a new token, with the marker rewritten under the lock; if that is not possible, the override ends (normal sleep
    /// is restored) and the user is told, so sleep is never left disabled without a lifeline.
    func watchdogEnded(token: String) async {
        guard session?.token == token else { return }
        for _ in 0..<200 where busy { try? await Task.sleep(for: .milliseconds(50)) }
        guard session?.token == token else { return }
        busy = true; defer { busy = false }
        let locked = await markerLock.acquire(timeout: enableLockTimeout)
        var holding = locked
        defer { if holding { markerLock.release() } }
        guard session?.token == token else { return }
        if locked {
            let fresh = UUID().uuidString
            if let handle = await watchdog.launch(token: fresh, markerDirectory: markers.directory) {
                do {
                    try markers.write(LidOverrideMarker(token: fresh, pid: getpid(), createdAt: Date(), boot: LidOverrideMarkerStore.bootSessionUUID()))
                    installSession(token: fresh, handle: handle)
                    return
                } catch { handle.release() }
            }
        }
        if holding { markerLock.release(); holding = false }
        await restoreInline(userInitiated: false, sleepIfLidClosed: true)
        if !needsRecovery { failure = L10n.text("The lid mode was stopped for safety.") }
    }

    /// Only after a confirmed `SleepDisabled 0`: the marker (any owner: no other live run uses this data directory) and
    /// the legacy flag go, and the watchdog is released.
    private func confirmNormalSleep() {
        try? markers.delete()
        defaults.removeObject(forKey: Self.legacyRecoveryKey)
        session?.handle.release(); session = nil
        systemSleepDisabled = false; systemSleepKnown = true
    }

    // MARK: Restore

    /// Ends the override. Passwordless first; an administrator prompt only for an explicit user action.
    func restore(userInitiated: Bool, sleepIfLidClosed: Bool) async {
        guard !busy else { pendingEnd = true; return }
        busy = true
        defer { busy = false }
        await restoreInline(userInitiated: userInitiated, sleepIfLidClosed: sleepIfLidClosed)
        pendingEnd = false
    }

    private func restoreInline(userInitiated: Bool, sleepIfLidClosed: Bool = false) async {
        generation &+= 1
        let locked = await markerLock.acquire(timeout: restoreLockTimeout)
        var holding = locked
        defer { if holding { markerLock.release() } }
        await beforeRelease()
        _ = await system.setSleepDisabledPasswordless(false)
        var reading = await system.readSleepDisabled()
        var restored = reading == false   // only a confirmed "off" clears the marker
        if !restored, userInitiated {
            _ = await system.restoreWithAuthorization()
            reading = await system.readSleepDisabled()
            restored = reading == false
        }
        guard restored else {
            // The watchdog keeps its pipe: if the app ends now, it tries again.
            needsRecovery = true
            failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.")
            return
        }
        confirmNormalSleep()
        needsRecovery = false; isOn = false; activeMode = nil; failure = nil
        if holding { markerLock.release(); holding = false }
        if sleepIfLidClosed && !anyActive() { await sleepIfLidAlreadyClosed() }
    }

    /// Clearing the flag only changes a kernel setting: a lid that shut during the session is not evaluated again,
    /// so the sleep that closing it would have caused is requested (macOS refuses briefly while the cleared flag
    /// propagates, hence the bounded retries).
    private func sleepIfLidAlreadyClosed(attempts: Int = 10) async {
        for _ in 0..<attempts {
            guard system.lidClosedWouldSleep(), !anyActive(), !isOn else { return }
            if system.requestSleep() { return }
            try? await Task.sleep(for: lidSleepRetryDelay)
        }
    }

    /// Quit, update installation or a sleep request: no prompt, true only when the override is confirmed off.
    @discardableResult func prepareForTermination() async -> Bool {
        guard isOn || markerPresent || busy else { return true }
        // Never clear the marker while a write may still be on its way: wait for the operation in flight.
        generation &+= 1
        pendingEnd = true
        for _ in 0..<100 where busy { try? await Task.sleep(for: .milliseconds(50)) }
        guard !busy else { return false }
        guard isOn || markerPresent else { pendingEnd = false; return true }
        let locked = await markerLock.acquire(timeout: restoreLockTimeout)
        defer { if locked { markerLock.release() } }
        await beforeRelease()
        _ = await system.setSleepDisabledPasswordless(false)
        guard await system.readSleepDisabled() == false else {
            // The pipe stays open: when the app ends, the watchdog tries again.
            needsRecovery = true
            failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.")
            return false
        }
        confirmNormalSleep()
        needsRecovery = false; isOn = false; activeMode = nil; pendingEnd = false
        return true
    }

    /// Launch: a marker left by a crashed or killed run means the override may still be set (its watchdog may be
    /// acting right now, hence the lock). Without a marker, the system state is read once for the warning.
    func recoverIfNeeded() async {
        guard markerPresent else { await cleanUpLegacyLeftover(); await markerGone(); return }
        let locked = await markerLock.acquire(timeout: recoveryLockTimeout)
        var holding = locked
        defer { if holding { markerLock.release() } }
        guard markerPresent else {
            if holding { markerLock.release(); holding = false }
            await markerGone()
            return
        }
        if (await system.readSleepDisabled()) == false {
            confirmNormalSleep(); needsRecovery = false; return
        }
        if holding { markerLock.release(); holding = false }
        busy = true; defer { busy = false }
        await restoreInline(userInitiated: false)
        if needsRecovery { failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.") }
    }

    /// One time, at the first launch of 0.7.2 or later: up to 0.7.1 a run that ended without restoring could leave
    /// `SleepDisabled 1` behind with no marker that launch recovery follows. It is cleared only when the evidence says
    /// Tilvero set it: one of the "With lid closed" switches is on AND Tilvero's own passwordless rule is installed
    /// (nothing else installs it; the override never starts without it). Then the same passwordless write as a restore,
    /// confirmed by a read; never a password prompt at launch. Without that evidence the setting is not touched (a
    /// user's own `pmset` or another tool) and the regular warning with "Restore sleep" shows instead. The cleanup is
    /// marked done once sleep reads normal or the evidence is missing; an unreadable state or a refused write is retried
    /// at the next launch.
    private func cleanUpLegacyLeftover() async {
        guard allowed, observesSystemSleep, !defaults.bool(forKey: Self.leftoverCleanupKey),
              !busy, !isOn, session == nil else { return }
        let usedLidMode = defaults.bool(forKey: Self.preferenceKey) || defaults.bool(forKey: Self.scheduledSleepPreferenceKey)
        guard usedLidMode, system.ruleFilePresent else { defaults.set(true, forKey: Self.leftoverCleanupKey); return }
        busy = true; defer { busy = false }
        guard let disabled = await system.readSleepDisabled() else { return }
        guard disabled else { defaults.set(true, forKey: Self.leftoverCleanupKey); return }
        let locked = await markerLock.acquire(timeout: recoveryLockTimeout)
        defer { if locked { markerLock.release() } }
        // A marker that appeared meanwhile belongs to a run that is acting: its own recovery path handles it.
        guard !markerPresent, !isOn, session == nil else { return }
        _ = await system.setSleepDisabledPasswordless(false)
        guard await system.readSleepDisabled() == false else { return }
        defaults.set(true, forKey: Self.leftoverCleanupKey)
        systemSleepDisabled = false; systemSleepKnown = true
    }

    /// The marker read at init is gone (the watchdog of the ended run restored and removed it first): nothing of ours
    /// can be set any more, so the recovery state is dropped and derived again from the real reading (the warning shows
    /// if sleep is still disabled, for example by another tool).
    private func markerGone() async {
        if session == nil, !isOn, needsRecovery {
            needsRecovery = false
            failure = nil
        }
        await checkSystemSleep()
    }

    /// One `pmset -g` read, at launch and when a Sleep page appears (no polling): `SleepDisabled 1` while this app holds
    /// no session gets the warning and the "Restore sleep" action (which may ask for the administrator password, only
    /// because the user pressed it).
    func checkSystemSleep() async {
        guard allowed, observesSystemSleep, !busy, !isOn, !needsRecovery, !systemCheckInFlight else { return }
        if let lastSystemCheck, ContinuousClock.now - lastSystemCheck < .seconds(2) { return }
        systemCheckInFlight = true; defer { systemCheckInFlight = false }
        lastSystemCheck = .now
        let reading = await system.readSleepDisabled()
        guard !busy, !isOn, !needsRecovery else { return }
        systemSleepDisabled = reading == true
        systemSleepKnown = reading != nil
    }

    /// Explicit user action after a failed restore: may show the administrator prompt.
    func restoreSleep() async { await restore(userInitiated: true, sleepIfLidClosed: true) }

    func removePermission() async {
        // A possibly set override needs the passwordless path (its watchdog too): it is restored first.
        guard !busy, !isOn, !needsRecovery else { return }
        busy = true; defer { busy = false }
        _ = await system.removeRule()
        ruleFilePresent = system.ruleFilePresent
    }

    /// After wake the marker and the real state can disagree (the machine slept despite the override).
    func reconcileAfterWake() async {
        guard !busy, isOn else { return }
        guard (await system.readSleepDisabled()) == false, !busy, isOn else { return }
        let locked = await markerLock.acquire(timeout: restoreLockTimeout)
        defer { if locked { markerLock.release() } }
        confirmNormalSleep(); isOn = false; activeMode = nil
    }
}

/// The native pieces the app and the lid watchdog share: reading and clearing the setting, the lid, the sleep request.
/// There is deliberately no way to disable sleep here: only `NativeLidSleepSystem`, inside a running session of the
/// app, writes `disablesleep 1`. The command runner is injectable, so tests can check the exact command lines.
struct LidSleepCommands: Sendable {
    typealias Runner = @Sendable (_ path: String, _ arguments: [String]) async -> (status: Int32, output: String)
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"
    static let clearArguments = ["-n", pmset, "disablesleep", "0"]
    static let live = LidSleepCommands(run: { await ProcessRunner.run($0, $1) })

    let run: Runner

    static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }
    func readSleepDisabled() async -> Bool? {
        let result = await run(Self.pmset, ["-g"])
        guard result.status == 0 else { return nil }
        return Self.sleepDisabled(inPmsetOutput: result.output)
    }
    /// `sudo -n /usr/bin/pmset disablesleep 0` through the one-command sudoers rule.
    func clearSleepDisabled() async -> Bool {
        await run(Self.sudo, Self.clearArguments).status == 0
    }
    static func lidClosedWouldSleep() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        }
        // With an external display (or another assertion) macOS keeps a closed MacBook awake by itself: never force it.
        return flag("AppleClamshellState") == true && flag("AppleClamshellCausesSleep") == true
    }
    static func requestSleep() -> Bool {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }
}

/// The only place in the app that runs `pmset`, `sudo`, `osascript` or reads the lid. Never exercised by default tests.
struct NativeLidSleepSystem: LidSleepSystem {
    /// The older one-feature file (still read; new permissions go into the merged file, see `PrivilegedRuleInstaller`).
    static let rulePath = "/etc/sudoers.d/tilvero-lid"

    /// Granted by uid, not by user name: a uid interpolates as bare digits that neither sudoers nor the shell can
    /// read as anything else (short names on SSO-enrolled Macs can be e-mail addresses).
    static func rule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }
    static func sleepDisabled(inPmsetOutput output: String) -> Bool { LidSleepCommands.sleepDisabled(inPmsetOutput: output) }

    /// `pmset`/`sudo` command lines go through this (tests inject a recording runner).
    var commands = LidSleepCommands.live

    /// The own `tilvero-lid` file or the merged `tilvero` file written with this feature (see `PrivilegedRuleInstaller`).
    var ruleFilePresent: Bool { PrivilegedRulePresence.isPresent(.lidClosed) }

    func readSleepDisabled() async -> Bool? { await commands.readSleepDisabled() }
    func passwordlessPathWorks() async -> Bool {
        guard let current = await readSleepDisabled() else { return false }
        return await setSleepDisabledPasswordless(current)
    }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool {
        guard disabled else { return await commands.clearSleepDisabled() }
        return await commands.run(LidSleepCommands.sudo, ["-n", LidSleepCommands.pmset, "disablesleep", "1"]).status == 0
    }
    /// The shared installer: the lid line goes into the merged rule file (one validated root script, one dialog).
    func installRule() async -> Bool { await PrivilegedRuleInstaller.runNative(.install([.lidClosed])) }
    /// The exact inverse: the lid line leaves the merged and the old file; every other line stays.
    func removeRule() async -> Bool { await PrivilegedRuleInstaller.runNative(.remove([.lidClosed])) }
    func restoreWithAuthorization() async -> Bool {
        await OsascriptAdministratorExecutor().run(script: "/usr/bin/pmset disablesleep 0", prompt: L10n.text("Tilvero asks to restore normal sleep.")) == .succeeded
    }
    func lidClosedWouldSleep() -> Bool { LidSleepCommands.lidClosedWouldSleep() }
    func requestSleep() -> Bool { LidSleepCommands.requestSleep() }
}
