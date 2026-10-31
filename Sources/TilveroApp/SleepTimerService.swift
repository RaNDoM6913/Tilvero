import Foundation
import Combine
import PowerCore

@MainActor protocol SleepTimerTransport: AnyObject {
    func isCurrentConsoleSession() -> Bool
    func requestSleep() throws
}

/// MainActor serialization plus a generation bound one-shot scheduler. No executable
/// intent is persisted; the native transport is injected by the application model.
@MainActor final class SleepTimerService: ObservableObject {
    @Published private(set) var phase: SleepTimerPhase = .idle
    @Published private(set) var message: String?
    @Published private(set) var diagnostic: String?
    var prepare: @MainActor () async -> Bool
    var onPhaseChange: (@MainActor (SleepTimerPhase) -> Void)?
    private var engine = SleepTimer()
    private let driver: any SleepTimerTransport
    private let allowed: Bool
    private let monotonic: @MainActor () -> Double
    private let suspending: @MainActor () -> Double
    private let wallClock: @MainActor () -> Date
    private let sleeper: @MainActor (Double) async throws -> Void
    private var timer: Task<Void, Never>?
    private static let epoch = ContinuousClock.now
    private static let suspendingEpoch = SuspendingClock.now
    private var startClockPair: (continuous: Double, suspending: Double)?

    static func continuousSeconds() -> Double {
        let elapsed = epoch.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    static func suspendingSeconds() -> Double {
        let elapsed = suspendingEpoch.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    init(driver: any SleepTimerTransport, allowed: Bool = true,
         monotonic: @escaping @MainActor () -> Double = { SleepTimerService.continuousSeconds() },
         suspending: @escaping @MainActor () -> Double = { SleepTimerService.suspendingSeconds() },
         wallClock: @escaping @MainActor () -> Date = { Date() },
         sleeper: @escaping @MainActor (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         prepare: @escaping @MainActor () async -> Bool = { true }) {
        self.driver = driver; self.allowed = allowed; self.monotonic = monotonic
        self.suspending = suspending
        self.wallClock = wallClock; self.sleeper = sleeper; self.prepare = prepare
    }

    var sessionID: UUID? { engine.sessionID }
    var isActive: Bool { phase.isActive }
    var isEditable: Bool { phase.isEditable }
    var isWarning: Bool { phase == .warning }
    var canExtend: Bool { engine.canExtend(at: monotonic()) }
    var isAvailable: Bool { allowed }
    var canStart: Bool { allowed && !isActive && driver.isCurrentConsoleSession() }
    var remainingSeconds: Int { engine.remainingSeconds(at: monotonic()) }
    var endDate: Date? {
        guard isActive, let deadline = engine.deadline else { return nil }
        return wallClock().addingTimeInterval(max(0, deadline - monotonic()))
    }

    func start(minutes: Int) throws {
        guard allowed else { throw SleepTimerError.unavailable }
        guard !isActive else { return }
        guard driver.isCurrentConsoleSession() else { throw SleepTimerError.unavailable }
        try engine.start(minutes: minutes, now: monotonic())
        startClockPair = (monotonic(), suspending())
        message = nil
        diagnostic = nil
        publish()
        schedule()
    }

    func extend() throws {
        guard allowed else { throw SleepTimerError.unavailable }
        guard !suspensionDetected else { systemDidWake(); throw SleepTimerError.notEditable }
        try engine.extend(now: monotonic())
        message = nil
        diagnostic = nil
        publish()
        schedule()
    }

    func cancel() {
        let before = engine.generation
        engine.cancel()
        guard engine.generation != before else { return }
        invalidateSchedule()
        message = "Timer cancelled."
        diagnostic = nil
        publish()
    }

    func systemWillSleep() {
        guard isActive else { return }
        engine.systemWillSleep()
        invalidateSchedule()
        message = engine.phase == .completed ? "System sleep was observed." : "Timer cancelled because the Mac went to sleep."
        publish()
    }

    func systemDidWake() { invalidate(reason: "Timer cancelled because the Mac woke from sleep.") }
    func sessionResigned() { invalidate(reason: "Timer cancelled because this user session is no longer active.") }
    func stop() { invalidate(reason: "Timer cancelled.") }

    private func invalidate(reason: String) {
        guard isActive else { return }
        engine.invalidate()
        invalidateSchedule()
        message = engine.phase == .unconfirmed ? "Sleep was requested; sleep could not be confirmed." : reason
        publish()
    }

    /// Called by significant deadlines and lifecycle reconciliation, never a 1 Hz UI ticker.
    func reconcile() async {
        guard allowed, isActive else { return }
        guard !suspensionDetected else { systemDidWake(); return }
        let id = engine.sessionID, generation = engine.generation
        engine.advance(now: monotonic())
        if !engine.phase.isActive {
            finishTimeTransition()
            return
        }
        guard engine.phase.isEditable else {
            schedule()
            return
        }
        guard let deadline = engine.deadline, monotonic() >= deadline else {
            publish()
            schedule()
            return
        }
        guard driver.isCurrentConsoleSession() else { sessionResigned(); return }
        guard engine.beginPreparation(now: monotonic()) else { finishTimeTransition(); return }
        invalidateSchedule()
        publish()
        guard engine.sessionID == id, engine.generation == generation, engine.phase == .preparing else { return }
        let ready = await prepare()
        guard engine.sessionID == id, engine.generation == generation, engine.phase == .preparing else { return }
        guard !suspensionDetected else { systemDidWake(); return }
        guard ready else {
            engine.cancel()
            message = "Sleep timer cancelled because safe preparation could not be confirmed."
            publish()
            return
        }
        guard driver.isCurrentConsoleSession() else { sessionResigned(); return }
        guard engine.beginRequest(now: monotonic()) else { finishTimeTransition(); return }
        publish()
        // Publication may synchronously deliver lifecycle callbacks. Recheck after
        // it, then commit without a suspension before this single native call.
        guard engine.sessionID == id, engine.generation == generation, engine.phase == .requesting else { return }
        guard !suspensionDetected else { systemDidWake(); return }
        guard driver.isCurrentConsoleSession() else { sessionResigned(); return }
        guard engine.markSubmitted() else { return }
        do {
            try driver.requestSleep()
            // A synchronous willSleep observation must retain its completed outcome.
            guard engine.sessionID == id, engine.generation == generation, engine.phase == .requesting else { return }
            engine.acceptRequest(now: monotonic())
            message = "Sleep requested. Waiting for system sleep."
        } catch {
            guard engine.sessionID == id, engine.generation == generation, engine.phase == .requesting else { return }
            engine.failRequest()
            message = "macOS declined the sleep request. Timer ended."
            diagnostic = error.localizedDescription
        }
        publish()
        schedule()
    }

    private func finishTimeTransition() {
        invalidateSchedule()
        if engine.phase == .expired { message = "Sleep timer expired without running. Start it again." }
        else if engine.phase == .unconfirmed { message = "Sleep was requested; sleep could not be confirmed." }
        publish()
    }
    /// Continuous time advances in sleep; SuspendingClock measures awake time.
    /// This catches resume-before-notification ordering without inferring it from
    /// scheduler lateness. The 250 ms margin covers sequential clock sampling.
    private var suspensionDetected: Bool {
        guard let pair = startClockPair else { return false }
        let continuousElapsed = monotonic() - pair.continuous
        let awakeElapsed = suspending() - pair.suspending
        return !continuousElapsed.isFinite || !awakeElapsed.isFinite
            || continuousElapsed < 0 || awakeElapsed < 0 || continuousElapsed - awakeElapsed > 0.25
    }

    private func publish() {
        guard phase != engine.phase else { return }
        phase = engine.phase
        onPhaseChange?(phase)
    }

    private func invalidateSchedule() { timer?.cancel(); timer = nil }

    private func schedule() {
        invalidateSchedule()
        guard let delay = engine.nextTransition(at: monotonic()), delay.isFinite else { return }
        let id = engine.sessionID, generation = engine.generation, sleep = sleeper
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.engine.sessionID == id, self.engine.generation == generation else { return }
            // Drop the completed task before reconciliation; do not cancel our own
            // task before an asynchronous safety preparation has completed.
            self.timer = nil
            await self.reconcile()
        }
    }
    isolated deinit { timer?.cancel() }
}
