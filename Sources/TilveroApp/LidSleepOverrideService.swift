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
enum LidMode: Equatable { case keepAwake, sleepTimer }

@MainActor final class LidSleepOverrideService: ObservableObject {
    static let recoveryKey = "lidSleepOverrideActive"
    static let preferenceKey = "lidClosedPreferred"
    static let timerPreferenceKey = "lidClosedPreferredTimer"
    /// The option: "with the lid closed" applies to every Keep Awake session the user starts. It never starts one.
    @Published private(set) var isPreferred = false
    /// The same option for the sleep timer: a running timer also continues with the lid closed and ends in sleep.
    @Published private(set) var isPreferredForTimer = false
    /// The override itself is in effect (a Keep Awake session is running and the option is on).
    @Published private(set) var isOn = false
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    /// The override may still be set after a failed restore or a crash: shown with a recovery action.
    @Published private(set) var needsRecovery = false
    @Published private(set) var ruleFilePresent = false

    private let system: any LidSleepSystem
    private let defaults: UserDefaults
    private let allowed: Bool
    /// Set by the model once the Keep Awake service exists.
    var awakeIsActive: @MainActor () -> Bool
    /// A sleep timer is armed (running, before it prepares to sleep). Set by the model.
    var timerIsActive: @MainActor () -> Bool
    private var activeMode: LidMode?
    private var timerRunning = false
    private var timerSubscription: AnyCancellable?
    private let lidSleepRetryDelay: Duration
    private var awakeSubscription: AnyCancellable?
    private var boundAwake: ObjectIdentifier?
    private var boundOwner: UInt32?
    private var generation: UInt64 = 0
    private var pendingEnd = false

    init(system: any LidSleepSystem = NativeLidSleepSystem(), defaults: UserDefaults = .standard, allowed: Bool = true,
         awakeIsActive: @escaping @MainActor () -> Bool = { false },
         timerIsActive: @escaping @MainActor () -> Bool = { false },
         lidSleepRetryDelay: Duration = .milliseconds(500)) {
        self.system = system; self.defaults = defaults; self.allowed = allowed
        self.awakeIsActive = awakeIsActive; self.timerIsActive = timerIsActive; self.lidSleepRetryDelay = lidSleepRetryDelay
        needsRecovery = defaults.bool(forKey: Self.recoveryKey)
        ruleFilePresent = system.ruleFilePresent
        isPreferred = allowed && defaults.bool(forKey: Self.preferenceKey)
        isPreferredForTimer = allowed && defaults.bool(forKey: Self.timerPreferenceKey)
    }

    private func isActive(_ mode: LidMode) -> Bool { mode == .keepAwake ? awakeIsActive() : timerIsActive() }
    private func anyActive() -> Bool { awakeIsActive() || timerIsActive() }
    private func preferred(_ mode: LidMode) -> Bool { mode == .keepAwake ? isPreferred : isPreferredForTimer }
    private func storePreference(_ on: Bool, for mode: LidMode) {
        if mode == .keepAwake { isPreferred = on; defaults.set(on, forKey: Self.preferenceKey) }
        else { isPreferredForTimer = on; defaults.set(on, forKey: Self.timerPreferenceKey) }
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
                if self.isOn || self.defaults.bool(forKey: Self.recoveryKey) {
                    await self.restore(userInitiated: false, sleepIfLidClosed: true)
                }
                if id != nil, self.isPreferred, !self.isOn, !self.needsRecovery { await self.enable(.keepAwake, allowPrompt: false) }
            }
        }
    }

    /// The override also belongs to one sleep timer: it starts when the timer is armed while that option is on and ends
    /// when the timer stops running. The phases arrive from the timer service (tests feed a subject).
    func bindTimer(phases: AnyPublisher<SleepTimerPhase, Never>) {
        timerSubscription = phases.sink { [weak self] phase in
            Task { @MainActor [weak self] in await self?.timerPhaseChanged(phase) }
        }
    }

    private func timerPhaseChanged(_ phase: SleepTimerPhase) async {
        let running = phase.isEditable            // armed and warning are one session
        guard running != timerRunning else { return }
        timerRunning = running
        if running {
            if isPreferredForTimer, !isOn, !needsRecovery { await enable(.sleepTimer, allowPrompt: false) }
        } else if activeMode == .sleepTimer || (activeMode == nil && defaults.bool(forKey: Self.recoveryKey)) {
            // Into the timer's own sleep request (preparing, requesting, accepted) the override is only lifted: the timer
            // sleeps the Mac itself after its preparation. Any other end (cancel, failure) behaves like ending Keep Awake:
            // a lid that is already closed gets the sleep it would have caused.
            let intoSleep: Set<SleepTimerPhase> = [.preparing, .requesting, .accepted, .completed]
            await restore(userInitiated: false, sleepIfLidClosed: !intoSleep.contains(phase))
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
            if activeMode == mode || (activeMode == nil && defaults.bool(forKey: Self.recoveryKey)) {
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
        guard await system.readSleepDisabled() == false else {
            failure = L10n.text("Sleep is already disabled by another tool or setting. Tilvero will not change it.")
            return false
        }
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

    private func enable(_ mode: LidMode, allowPrompt: Bool) async {
        guard allowed, !busy, !needsRecovery, !isOn, isActive(mode) else { return }
        busy = true; failure = nil; pendingEnd = false
        defer { busy = false }
        generation &+= 1
        let id = generation
        // Restore only what Tilvero owns: an override that is already set (another tool, the user's own pmset) or
        // unreadable is never adopted, because ending the session would clear a state this app did not create.
        guard await system.readSleepDisabled() == false else {
            failure = L10n.text("Sleep is already disabled by another tool or setting. Tilvero will not change it.")
            return
        }
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
        // Written down before the system is touched: a crash after the write must still be recoverable.
        defaults.set(true, forKey: Self.recoveryKey)
        needsRecovery = false
        guard await system.setSleepDisabledPasswordless(true), await system.readSleepDisabled() == true else {
            // A refused write may still have applied: only a confirmed "off" clears the marker.
            if await system.readSleepDisabled() == false { defaults.set(false, forKey: Self.recoveryKey) }
            else { needsRecovery = true }
            failure = L10n.text("macOS did not enable the lid mode.")
            return
        }
        if generation == id, isActive(mode) { isOn = true; activeMode = mode } else { await restoreInline(userInitiated: false, sleepIfLidClosed: true) }
        if pendingEnd { pendingEnd = false; await restoreInline(userInitiated: false, sleepIfLidClosed: true) }
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
        var restored = false
        let wrote = await system.setSleepDisabledPasswordless(false)
        var reading = await system.readSleepDisabled()
        _ = wrote
        restored = reading == false   // only a confirmed "off" clears the marker
        if !restored, userInitiated {
            _ = await system.restoreWithAuthorization()
            reading = await system.readSleepDisabled()
            restored = reading == false
        }
        guard restored else {
            needsRecovery = true
            failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.")
            return
        }
        defaults.set(false, forKey: Self.recoveryKey)
        needsRecovery = false; isOn = false; activeMode = nil; failure = nil
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
        guard isOn || defaults.bool(forKey: Self.recoveryKey) || busy else { return true }
        // Never clear the marker while a write may still be on its way: wait for the operation in flight.
        generation &+= 1
        pendingEnd = true
        for _ in 0..<100 where busy { try? await Task.sleep(for: .milliseconds(50)) }
        guard !busy else { return false }
        guard isOn || defaults.bool(forKey: Self.recoveryKey) else { pendingEnd = false; return true }
        _ = await system.setSleepDisabledPasswordless(false)
        guard await system.readSleepDisabled() == false else {
            needsRecovery = true
            failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.")
            return false
        }
        defaults.set(false, forKey: Self.recoveryKey)
        needsRecovery = false; isOn = false; activeMode = nil; pendingEnd = false
        return true
    }

    /// Launch: a marker left by a crashed or killed run means the override may still be set.
    func recoverIfNeeded() async {
        guard defaults.bool(forKey: Self.recoveryKey) else { return }
        if (await system.readSleepDisabled()) == false {
            defaults.set(false, forKey: Self.recoveryKey); needsRecovery = false; return
        }
        busy = true; defer { busy = false }
        await restoreInline(userInitiated: false)
        if needsRecovery { failure = L10n.text("Normal sleep could not be restored. Use Restore sleep.") }
    }

    /// Explicit user action after a failed restore: may show the administrator prompt.
    func restoreSleep() async { await restore(userInitiated: true, sleepIfLidClosed: true) }

    func removePermission() async {
        guard !busy, !isOn else { return }
        busy = true; defer { busy = false }
        _ = await system.removeRule()
        ruleFilePresent = system.ruleFilePresent
    }

    /// After wake the marker and the real state can disagree (the machine slept despite the override).
    func reconcileAfterWake() async {
        guard !busy, isOn else { return }
        if (await system.readSleepDisabled()) == false {
            defaults.set(false, forKey: Self.recoveryKey); isOn = false; activeMode = nil
        }
    }
}

/// The only place that runs `pmset`, `sudo`, `osascript` or reads the lid. Never exercised by default tests.
struct NativeLidSleepSystem: LidSleepSystem {
    static let rulePath = "/etc/sudoers.d/tilvero-lid"
    static let tempRulePath = "/etc/sudoers.d/tilvero-lid.tmp"

    /// Granted by uid, not by user name: a uid interpolates as bare digits that neither sudoers nor the shell can
    /// read as anything else (short names on SSO-enrolled Macs can be e-mail addresses).
    static func rule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    }
    static func sleepDisabled(inPmsetOutput output: String) -> Bool {
        output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }
    static func installCommand(uid: uid_t) -> String {
        // Written to a temporary name (sudo ignores names containing a dot), validated, then moved into place.
        "mkdir -p /etc/sudoers.d && echo '\(rule(uid: uid))' > \(tempRulePath) && chmod 0440 \(tempRulePath) && /usr/sbin/visudo -c -f \(tempRulePath) && mv \(tempRulePath) \(rulePath) || { rm -f \(tempRulePath); exit 1; }"
    }
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    var ruleFilePresent: Bool { FileManager.default.fileExists(atPath: Self.rulePath) }

    func readSleepDisabled() async -> Bool? {
        let result = await Self.run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        return Self.sleepDisabled(inPmsetOutput: result.output)
    }
    func passwordlessPathWorks() async -> Bool {
        guard let current = await readSleepDisabled() else { return false }
        return await setSleepDisabledPasswordless(current)
    }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool {
        await Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", disabled ? "1" : "0"]).status == 0
    }
    func installRule() async -> Bool {
        await Self.administrator(Self.installCommand(uid: getuid()), prompt: L10n.text("Tilvero asks to allow one command, pmset disablesleep, without a password, so Keep Awake can work with the lid closed."))
    }
    func removeRule() async -> Bool {
        await Self.administrator("rm -f \(Self.rulePath)", prompt: L10n.text("Tilvero asks to remove its closed-lid permission."))
    }
    func restoreWithAuthorization() async -> Bool {
        await Self.administrator("/usr/bin/pmset disablesleep 0", prompt: L10n.text("Tilvero asks to restore normal sleep."))
    }
    func lidClosedWouldSleep() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        }
        // With an external display (or another assertion) macOS keeps a closed MacBook awake by itself: never force it.
        return flag("AppleClamshellState") == true && flag("AppleClamshellCausesSleep") == true
    }
    func requestSleep() -> Bool {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }

    private static func administrator(_ command: String, prompt: String) async -> Bool {
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
        // The dialog attaches to the requesting process; an inactive menu-bar app would open it behind other windows.
        await MainActor.run { NSApplication.shared.activate() }
        return await run("/usr/bin/osascript", ["-e", source], timeout: 600).status == 0
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    /// Independent processes, no shared queue: a long administrator prompt never delays a `pmset -g` or a restore.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            let once = Once()
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if once.take() { continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self))) }
            }
            do { try process.run() } catch {
                if once.take() { continuation.resume(returning: (-1, "")) }
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                if once.take() { continuation.resume(returning: (-2, "")) }
            }
        }
    }
}
