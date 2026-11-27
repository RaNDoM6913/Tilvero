// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine
import PowerCore

/// "Charge by a time": the Mac keeps the user's limit (say 80 %) and the app lifts it just early enough that the
/// battery is at the chosen level 10 minutes before the requested time. The lift happens at the planned moment even
/// when the Mac sleeps: a scheduled wake brings the app back, it lifts the limit, the Mac sleeps again and keeps
/// charging (the limit is a persistent macOS setting). The user's previous limit returns when the adapter is
/// unplugged (or an hour after the requested time once the battery is full). A limit changed elsewhere always wins.
struct ChargeByPlanState: Codable, Equatable {
    enum Phase: String, Codable { case armed, charging }
    var deadline: Date
    var target: Int
    /// The user's own limit before the plan; put back at the end.
    var previousLimit: Int
    var phase: Phase = .armed
    var startAt: Date
    /// The wake that was scheduled and read back, nil when none is.
    var wakeAt: Date?
    /// The exact `pmset` date string that wake was made with; cancelling uses it, not a new formatting of `wakeAt`
    /// (after a time-zone or DST change that would name a different entry). Nil in plans saved before it was kept.
    var wakeStamp: String? = nil
    /// The lift was requested (recorded before the write): a later read of exactly the target is Tilvero's own lift
    /// landing late, not a change made elsewhere. Optional so plans saved earlier still decode.
    var liftRequested: Bool? = nil
    /// The user cancelled while charging or while a lift was unresolved: the previous limit is restored on every tick until
    /// it reads back (or, for a lift that never landed, the plan just ends).
    var cancelRequested: Bool? = nil
}

/// What an apply through the slider's verified path came to.
enum ChargeByApplyResult: Equatable {
    /// Written and read back.
    case confirmed
    /// The limit was not the expected one just before the write (changed in System Settings): nothing written.
    case changedElsewhere
    /// Refused for a moment before any write (another apply or the user's own change holds the service, nothing read since
    /// launch): nothing was dispatched, and the next tick simply tries again. Never a failure to report.
    case deferred
    /// Refused before any write for another reason (an unclear, failing or unrecognised read, a target macOS does not offer,
    /// a record that could not be saved, a call still pending past its deadline): nothing was dispatched, so nothing can land.
    case notWritten
    /// Dispatched but not confirmed: it may still land (the next observation decides).
    case failed
}

enum ChargeByAction: Equatable {
    case none
    /// Raise the limit to this level.
    case lift(Int)
    /// The requested lift has landed (it read back late): continue as after a confirmed lift, writing nothing.
    case lifted
    /// The charge is over: apply the user's limit again.
    case restore(Int)
    /// The user's own limit changed while armed: it is the new "previous".
    case adopt(Int)
    /// Forget the plan, write nothing.
    case drop
}

enum ChargeByRule {
    /// The wake is scheduled this long before the planned start, and the limit is lifted at that wake: a dark wake can end
    /// within seconds, so the app acts when it wakes instead of waiting for the exact start.
    static let wakeLead: TimeInterval = 60
    static let holdAfterDeadline: TimeInterval = 3600
    /// A wake may come a little early; from this long before the wake time on, the limit is lifted (earlier is harmless).
    static let liftTolerance: TimeInterval = 30

    static func decide(_ state: ChargeByPlanState, now: Date, observedLimit: Int?, percent: Int?, isCharging: Bool?,
                       externalPower: Bool?, goingToSleep: Bool, wakeConfirmed: Bool) -> ChargeByAction {
        switch state.phase {
        case .armed:
            // Cancelled while a lift's outcome was unknown: once the limit is read, the lift either landed (put the user's
            // limit back) or did not (nothing to undo). Until it is read, wait.
            if state.cancelRequested == true {
                guard let observedLimit else { return .none }
                return observedLimit == state.target ? .restore(state.previousLimit) : .drop
            }
            // Our own lift, landed late: charging (and restored later), even past the hold, never dropped as "nothing to do".
            if state.liftRequested == true, observedLimit == state.target { return .lifted }
            if now >= state.deadline.addingTimeInterval(holdAfterDeadline) { return .drop }
            if let observedLimit {
                if observedLimit >= state.target { return .drop }                 // already allows the target: nothing to do
                if observedLimit != state.previousLimit { return .adopt(observedLimit) }
            }
            // Without power there is nothing to lift for; the plan waits and the interface says so.
            if externalPower == false { return .none }
            if now >= state.startAt.addingTimeInterval(-ChargeByRule.wakeLead - liftTolerance) { return .lift(state.target) }
            // Going to sleep with no confirmed wake: the only moment left to act is now (charging early beats not charging).
            if goingToSleep && !wakeConfirmed { return .lift(state.target) }
            return .none
        case .charging:
            if let observedLimit, observedLimit != state.target { return .drop }   // changed elsewhere: leave it alone
            if state.cancelRequested == true { return .restore(state.previousLimit) }   // a cancel whose restore did not land yet
            if externalPower == false { return .restore(state.previousLimit) }
            if now >= state.deadline.addingTimeInterval(holdAfterDeadline), let percent, percent >= state.target, isCharging == false {
                return .restore(state.previousLimit)
            }
            return .none
        }
    }
}

struct ChargeByObservation: Equatable {
    var observedLimit: Int?
    var percent: Double?
    var isCharging: Bool?
    var externalPower: Bool?
    var adapterWatts: Double?
    var fullEnergyWh: Double?
    /// The Mac's own draw now (W), nil when unknown.
    var systemWatts: Double?
    /// macOS's own time to a full charge (seconds); present only while the Mac is charging and macOS has an estimate.
    var systemTimeToFullSeconds: Double?
}

@MainActor protocol ChargeByEnvironment: AnyObject {
    func observation() -> ChargeByObservation
    /// Applies a limit through the same verified path the slider uses. `expected` is the limit the plan believes is set
    /// now; a different fresh value means it was changed elsewhere and nothing is written.
    func apply(limit: Int, expected: Int?) async -> ChargeByApplyResult
    /// macOS Optimized Charging would hold the battery at 80 % until its own guess of the morning: paused until tomorrow
    /// when the limit is lifted (no-op when it is off).
    /// false only when Optimized Charging was on and the pause did not read back.
    func pauseOptimizedCharging() async -> Bool
}
extension ChargeByEnvironment { func pauseOptimizedCharging() async -> Bool { true } }

/// Keeps the Mac from idle sleep for the few seconds an apply needs (a dark wake can end quickly).
@MainActor protocol ActivityHolding: AnyObject {
    func begin(reason: String) -> AnyObject
    func end(_ token: AnyObject)
}
@MainActor final class ProcessActivityHolder: ActivityHolding {
    func begin(reason: String) -> AnyObject { ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason) }
    func end(_ token: AnyObject) { if let token = token as? NSObjectProtocol { ProcessInfo.processInfo.endActivity(token) } }
}

@MainActor final class ChargeByService: ObservableObject {
    private static let key = "chargeByPlan.v1"
    static let replanThreshold: TimeInterval = 120

    @Published private(set) var state: ChargeByPlanState?
    @Published private(set) var plan: ChargeByPlanner.Plan?
    @Published var message: String?
    /// The planned charge could not pause Optimized Charging; its own line, so the charging status stays visible.
    @Published private(set) var optimizedPauseFailed = false
    @Published private(set) var isWorking = false
    /// Drafted level while no plan is armed (the strip's selection).
    @Published var draftTarget = 100

    private let defaults: UserDefaults
    private let wake: any WakeScheduling
    private let holder: any ActivityHolding
    private let now: @MainActor () -> Date
    weak var environment: (any ChargeByEnvironment)?
    /// Lifts refused before any write for a reason that is not momentary, in a row: the first is quiet (it is retried on
    /// the next tick), a repeat says the planned charge is not happening.
    private var liftRefusals = 0

    init(defaults: UserDefaults, wake: any WakeScheduling, holder: any ActivityHolding = ProcessActivityHolder(), now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults; self.wake = wake; self.holder = holder; self.now = now
        if let data = defaults.data(forKey: Self.key), var saved = try? JSONDecoder().decode(ChargeByPlanState.self, from: data),
           NativeChargeAdmission.persistentTargets.contains(saved.target), NativeChargeAdmission.persistentTargets.contains(saved.previousLimit) {
            // A stamp goes to `sudo -n pmset schedule cancel wake` verbatim: anything but the exact shape is dropped, and the
            // cancel then falls back to formatting `wakeAt` (as for plans saved before stamps were kept).
            if let stamp = saved.wakeStamp, !NativeWakeScheduler.isValidStamp(stamp) { saved.wakeStamp = nil }
            state = saved
        }
    }

    var isArmed: Bool { state != nil }
    var isCharging: Bool { state?.phase == .charging }
    var wakePermitted: Bool { wake.isPermitted }
    var wakeConfirmed: Bool { state?.wakeAt != nil }
    func installWakePermission() async -> Bool { let ok = await wake.installPermission(); objectWillChange.send(); if ok, state != nil { await ensureWake() }; return ok }

    // MARK: Commands

    /// Arms a plan for `deadline`. False when the request cannot be planned (no data, deadline too close, level not above the limit).
    @discardableResult func arm(deadline: Date, target: Int) async -> Bool {
        guard state == nil, let environment else { return false }
        let observation = environment.observation()
        guard let limit = observation.observedLimit else { message = "The charge limit has not been read yet."; return false }
        guard limit < target else { message = "Choose a level above your charge limit."; return false }
        guard deadline > now().addingTimeInterval(ChargeByPlanner.reserveSeconds + 60) else { message = "Choose a later time."; return false }
        let draft = ChargeByPlanState(deadline: deadline, target: target, previousLimit: limit, startAt: now())
        guard let computed = computePlan(for: draft, observation: observation) else { message = "Not enough battery data yet."; return false }
        var armed = draft; armed.startAt = computed.startAt
        state = armed; plan = computed; message = nil; liftRefusals = 0; save()
        await ensureWake()
        await tick()   // already due (late request): lift immediately
        return true
    }

    /// A new time for an armed plan.
    func setDeadline(_ deadline: Date) async {
        guard var current = state, deadline > now().addingTimeInterval(ChargeByPlanner.reserveSeconds + 60) else { message = "Choose a later time."; return }
        current.deadline = deadline; state = current; message = nil; save()
        if current.phase == .armed { await replan(force: true) }
        await tick()   // while charging the tick refreshes the plan against the new time
    }

    /// When the plan cannot make it, the earliest time that works (rounded up to 5 minutes), nil when the plan is fine.
    var suggestedDeadline: Date? {
        guard let state, let plan, !plan.reachesTarget else { return nil }
        let raw = now().addingTimeInterval(plan.chargeSeconds + ChargeByPlanner.reserveSeconds).timeIntervalSinceReferenceDate
        let rounded = Date(timeIntervalSinceReferenceDate: (raw / 300).rounded(.up) * 300)
        return rounded > state.deadline ? rounded : nil
    }

    func setTarget(_ target: Int) async {
        guard var current = state, current.phase == .armed, target > current.previousLimit, NativeChargeAdmission.persistentTargets.contains(target) else { return }
        current.target = target; state = current; save()
        await replan(force: true)
    }

    /// Cancels the plan. While charging, or while a lift's outcome is unknown (it may still land), the user's limit is put
    /// back first; a plan that never lifted just ends.
    func cancel() async {
        guard let current = state else { return }
        guard current.phase == .charging || current.liftRequested == true else { await finish(removeWake: true); return }
        // Recorded first: a restore that fails now is retried on every tick (and after a relaunch).
        var cancelling = current; cancelling.cancelRequested = true; state = cancelling; save()
        // A lift or restore in flight sees the cancel when it returns (a late confirmed lift must not undo the ✕).
        guard !isWorking else { return }
        // Expected = the target: a lift that never landed reads the previous limit, so nothing is written and the plan ends.
        _ = await perform(.restore(cancelling.previousLimit), cancelling)
    }

    /// The user set the limit with the slider (`limit`; nil when that write's outcome is unknown). A plan that could put an
    /// older limit back over that choice ends, writing nothing: one charging, or with a lift (or a cancel's restore) whose
    /// outcome is unknown. A plain armed plan follows the new value as it follows a change made in System Settings: the
    /// new previous limit, or dropped once the limit already allows the target; its wake stays. With an unknown outcome
    /// it waits for the next read, as a tick does. Synchronous: the plan is settled at once, and a wake that goes is
    /// removed on its own, so the caller's apply never waits for pmset.
    func userChoseLimit(_ limit: Int?) {
        guard let current = state else { return }
        let mayRestore = current.phase == .charging || current.liftRequested == true || current.cancelRequested == true
        if mayRestore || limit.map({ $0 >= current.target }) == true {
            message = nil
            end()
            return
        }
        guard let limit, limit != current.previousLimit else { return }
        var updated = current; updated.previousLimit = limit; updated.liftRequested = nil
        state = updated; message = nil; liftRefusals = 0; save()
    }

    // MARK: Ticks

    func systemWillSleep() async { await tick(goingToSleep: true) }
    func systemDidWake() async { await tick() }

    /// Evaluate the plan: replan while armed, then act on the rule. Safe to call often and from any wake.
    func tick(goingToSleep: Bool = false) async {
        guard !isWorking, let environment, let current = state else { return }
        let observation = environment.observation()
        if current.phase == .armed { await replan(force: false, observation: observation) }
        else if let computed = computePlan(for: current, observation: observation) { plan = computed }   // the charge in progress: macOS's own estimate keeps the status honest
        guard let latest = state else { return }
        let action = ChargeByRule.decide(latest, now: now(), observedLimit: observation.observedLimit, percent: observation.percent.map { Int($0.rounded()) },
                                         isCharging: observation.isCharging, externalPower: observation.externalPower,
                                         goingToSleep: goingToSleep, wakeConfirmed: latest.wakeAt != nil)
        guard action != .none else { return }
        await perform(action, latest)
    }

    // MARK: Internals

    private func computePlan(for state: ChargeByPlanState, observation: ChargeByObservation) -> ChargeByPlanner.Plan? {
        guard let percent = observation.percent, let wh = observation.fullEnergyWh else { return nil }
        let draw = min(15, max(ChargeByPlanner.defaultSleepDrawWatts, observation.systemWatts ?? ChargeByPlanner.defaultSleepDrawWatts))
        return ChargeByPlanner.plan(.init(now: now(), deadline: state.deadline, currentPercent: percent, targetPercent: state.target,
                                          adapterWatts: observation.adapterWatts, systemDrawWatts: draw, fullEnergyWh: wh,
                                          systemTimeToFullSeconds: observation.isCharging == true ? observation.systemTimeToFullSeconds : nil))
    }

    private func replan(force: Bool, observation: ChargeByObservation? = nil) async {
        guard let environment, var current = state, current.phase == .armed else { return }
        let observation = observation ?? environment.observation()
        guard let computed = computePlan(for: current, observation: observation) else { return }
        plan = computed
        if force || abs(computed.startAt.timeIntervalSince(current.startAt)) > Self.replanThreshold {
            let old = current.wakeAt, oldStamp = current.wakeStamp
            current.startAt = computed.startAt; current.wakeAt = nil; current.wakeStamp = nil; state = current; save()
            if let old { _ = await wake.cancel(old, stamp: oldStamp) }
            await ensureWake()
        }
    }

    /// A wake exists for the planned start, or it is scheduled now. Nothing is claimed unless it was read back.
    private func ensureWake() async {
        // While the permission is being removed a new wake could never be cancelled again.
        guard var current = state, current.phase == .armed, wake.isPermitted, !PrivilegedRuleInstaller.removalInProgress else { return }
        let wanted = current.startAt.addingTimeInterval(-ChargeByRule.wakeLead)
        guard wanted > now().addingTimeInterval(30) else { return }   // too close: the ticks and the sleep fallback cover it
        if let existing = current.wakeAt, abs(existing.timeIntervalSince(wanted)) < 60 { return }
        if let existing = current.wakeAt { _ = await wake.cancel(existing, stamp: current.wakeStamp) }
        let stamp = await wake.schedule(wanted)
        // pmset can take seconds: the plan may have changed meanwhile (the user's slider adopted a new previous limit, a
        // lift started charging) or ended. Only the wake is recorded, on the plan as it is now; with no armed plan left the
        // new wake goes again.
        guard var latest = state, latest.phase == .armed else {
            if let stamp { _ = await wake.cancel(wanted, stamp: stamp) }
            return
        }
        latest.wakeAt = stamp != nil ? wanted : nil; latest.wakeStamp = stamp
        state = latest; save(); objectWillChange.send()
    }

    @discardableResult private func perform(_ action: ChargeByAction, _ current: ChargeByPlanState) async -> Bool {
        guard let environment else { return false }
        switch action {
        case .none: return true
        case .drop: await finish(removeWake: true); return true
        case .adopt(let limit):
            var updated = current; updated.previousLimit = limit; updated.liftRequested = nil; state = updated; message = nil
            liftRefusals = 0; save()
            await replan(force: true); return true
        case .lifted:
            await completeLift(current); return true
        case .lift(let level):
            isWorking = true
            let token = holder.begin(reason: "Tilvero is lifting the charge limit for a planned charge")
            defer { holder.end(token); isWorking = false }
            // The intent is recorded before the write: a lift that lands late is recognised as this lift, not a user change.
            var requested = current; requested.liftRequested = true; state = requested; save()
            let result = await environment.apply(limit: level, expected: current.previousLimit)
            // The ✕ tapped while this lift was in flight (recorded on the state): honoured now.
            if state?.cancelRequested == true {
                switch result {
                case .confirmed:
                    // Lifted: recorded as such, then the user's limit goes back (retried by the ticks if this fails).
                    var raised = requested; raised.phase = .charging; raised.liftRequested = nil; raised.cancelRequested = true
                    state = raised; save()
                    return await perform(.restore(raised.previousLimit), raised)
                case .changedElsewhere:
                    await finish(removeWake: true); return true   // nothing was written: nothing to undo
                case .notWritten, .deferred:
                    // Nothing was written by this call: only an earlier unresolved lift can still land, and the ticks
                    // restore or end the plan once the limit is read. Without one there is nothing to undo.
                    if current.liftRequested == true { return false }
                    await finish(removeWake: true); return true
                case .failed:
                    // It may still land: the ticks restore once the limit reads the target, or end the plan otherwise.
                    message = "The charge limit could not be restored. Tilvero will try again."; return false
                }
            }
            switch result {
            case .confirmed:
                await completeLift(requested); return true
            case .changedElsewhere, .notWritten, .deferred:
                // Nothing was written by this call. A first lift's intent goes: the next tick adopts or drops a user's
                // change, and a later read of the target (set in System Settings) is never taken for this lift. A retry of
                // an earlier unresolved lift keeps it: that lift may still land, or be what changed the limit (`.lifted`).
                if current.liftRequested != true, var cleared = state { cleared.liftRequested = nil; state = cleared; save() }
                switch result {
                case .changedElsewhere:
                    // A change made elsewhere wins quietly.
                    message = nil; liftRefusals = 0
                case .notWritten:
                    // Refused for a reason that may persist: the first refusal is retried quietly by the next tick, a repeat
                    // says the planned charge is not happening (the status would otherwise keep promising it).
                    liftRefusals += 1
                    if liftRefusals > 1 { message = "The charge limit could not be raised. Tilvero will try again." }
                default:
                    break   // momentary (busy, the user's own change first, nothing read yet): retried, nothing to report
                }
                return false
            case .failed:
                message = "The charge limit could not be raised. Tilvero will try again."; return false
            }
        case .restore(let limit):
            isWorking = true
            let token = holder.begin(reason: "Tilvero is putting the charge limit back")
            defer { holder.end(token); isWorking = false }
            switch await environment.apply(limit: limit, expected: current.target) {
            case .confirmed, .changedElsewhere:
                // Restored, or the user already chose another limit: theirs stays, the plan is over.
                await finish(removeWake: true); return true
            case .deferred:
                return false   // busy for a moment (the user's own change goes first): the next tick tries again quietly
            case .notWritten, .failed:
                message = "The charge limit could not be restored. Tilvero will try again."; return false
            }
        }
    }

    /// The bookkeeping after the lift (confirmed now, or read back late): charging, the wake goes, OBC is paused.
    private func completeLift(_ current: ChargeByPlanState) async {
        // The lift is recorded first (a relaunch during the pause must know the limit is raised), then the wake goes.
        var updated = current; updated.phase = .charging; updated.liftRequested = nil; state = updated; message = nil
        liftRefusals = 0; save()
        if let wakeAt = current.wakeAt { _ = await wake.cancel(wakeAt, stamp: current.wakeStamp) }
        // While pmset ran the plan may have ended (the user's slider) or been cancelled: that state stands, only the wake
        // is cleared.
        guard var charging = state else { return }
        charging.wakeAt = nil; charging.wakeStamp = nil; state = charging; save()
        optimizedPauseFailed = !(await (environment?.pauseOptimizedCharging() ?? true))
    }

    private func finish(removeWake: Bool) async {
        if removeWake, let wakeAt = state?.wakeAt { _ = await wake.cancel(wakeAt, stamp: state?.wakeStamp) }
        state = nil; plan = nil; optimizedPauseFailed = false; liftRefusals = 0; defaults.removeObject(forKey: Self.key)
    }
    /// Ends the plan at once, writing nothing; its wake is removed on its own afterwards, so no caller waits for pmset.
    private func end() {
        let wakeAt = state?.wakeAt, stamp = state?.wakeStamp
        state = nil; plan = nil; optimizedPauseFailed = false; liftRefusals = 0; defaults.removeObject(forKey: Self.key)
        guard let wakeAt else { return }
        let wake = wake
        Task { @MainActor in _ = await wake.cancel(wakeAt, stamp: stamp) }
    }
    private func save() {
        if let state, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}

/// The plan's periodic tick: once when started (a plan resumes after a relaunch), then every 20 s only while a plan
/// exists, started and stopped as plans are armed, cancelled or finished. Sleep and wake tick through the service's
/// own `systemWillSleep`/`systemDidWake`.
@MainActor final class ChargeByTicker {
    private let service: ChargeByService
    private let interval: TimeInterval
    private var timer: Timer?
    private var subscription: AnyCancellable?
    var isTimerRunning: Bool { timer != nil }

    init(service: ChargeByService, interval: TimeInterval = 20) { self.service = service; self.interval = interval }

    func start() {
        guard subscription == nil else { return }
        let service = service
        Task { @MainActor in await service.tick() }
        // `$state` delivers the current value at once, so a plan restored at launch starts the timer here.
        subscription = service.$state.map { $0 != nil }.removeDuplicates().sink { [weak self] armed in self?.setTimer(running: armed) }
    }
    func stop() {
        subscription = nil
        setTimer(running: false)
    }
    private func setTimer(running: Bool) {
        if running, timer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak service] _ in Task { @MainActor in await service?.tick() } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        } else if !running {
            timer?.invalidate(); timer = nil
        }
    }
}
