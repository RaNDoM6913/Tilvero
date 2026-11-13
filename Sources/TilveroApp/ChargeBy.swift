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
}

enum ChargeByAction: Equatable {
    case none
    /// Raise the limit to this level.
    case lift(Int)
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
    /// Applies a limit through the same verified path the slider uses; true when it was confirmed.
    func apply(limit: Int) async -> Bool
}

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
    @Published private(set) var isWorking = false
    /// Drafted level while no plan is armed (the strip's selection).
    @Published var draftTarget = 100

    private let defaults: UserDefaults
    private let wake: any WakeScheduling
    private let holder: any ActivityHolding
    private let now: @MainActor () -> Date
    weak var environment: (any ChargeByEnvironment)?

    init(defaults: UserDefaults, wake: any WakeScheduling, holder: any ActivityHolding = ProcessActivityHolder(), now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults; self.wake = wake; self.holder = holder; self.now = now
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(ChargeByPlanState.self, from: data),
           NativeChargeAdmission.persistentTargets.contains(saved.target), NativeChargeAdmission.persistentTargets.contains(saved.previousLimit) {
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
        guard let limit = observation.observedLimit, limit < target, deadline > now().addingTimeInterval(ChargeByPlanner.reserveSeconds + 60) else {
            message = "Choose a later time."; return false
        }
        let draft = ChargeByPlanState(deadline: deadline, target: target, previousLimit: limit, startAt: now())
        guard let computed = computePlan(for: draft, observation: observation) else { message = "Not enough battery data yet."; return false }
        var armed = draft; armed.startAt = computed.startAt
        state = armed; plan = computed; message = nil; save()
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

    /// Cancels the plan. While charging, the user's limit is put back first.
    func cancel() async {
        guard let current = state else { return }
        if current.phase == .charging { _ = await perform(.restore(current.previousLimit), current) }
        else { await finish(removeWake: true) }
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
            let old = current.wakeAt
            current.startAt = computed.startAt; current.wakeAt = nil; state = current; save()
            if let old { _ = await wake.cancel(old) }
            await ensureWake()
        }
    }

    /// A wake exists for the planned start, or it is scheduled now. Nothing is claimed unless it was read back.
    private func ensureWake() async {
        guard var current = state, current.phase == .armed, wake.isPermitted else { return }
        let wanted = current.startAt.addingTimeInterval(-ChargeByRule.wakeLead)
        guard wanted > now().addingTimeInterval(30) else { return }   // too close: the ticks and the sleep fallback cover it
        if let existing = current.wakeAt, abs(existing.timeIntervalSince(wanted)) < 60 { return }
        if let existing = current.wakeAt { _ = await wake.cancel(existing) }
        let ok = await wake.schedule(wanted)
        current.wakeAt = ok ? wanted : nil
        state = current; save(); objectWillChange.send()
    }

    @discardableResult private func perform(_ action: ChargeByAction, _ current: ChargeByPlanState) async -> Bool {
        guard let environment else { return false }
        switch action {
        case .none: return true
        case .drop: await finish(removeWake: true); return true
        case .adopt(let limit):
            var updated = current; updated.previousLimit = limit; state = updated; save(); await replan(force: true); return true
        case .lift(let level):
            isWorking = true
            let token = holder.begin(reason: "Tilvero is lifting the charge limit for a planned charge")
            defer { holder.end(token); isWorking = false }
            guard await environment.apply(limit: level) else { message = "The charge limit could not be raised. Tilvero will try again."; return false }
            var updated = current; updated.phase = .charging; state = updated; message = nil; save()
            if let wakeAt = current.wakeAt { _ = await wake.cancel(wakeAt) }
            var charging = updated; charging.wakeAt = nil; state = charging; save()
            return true
        case .restore(let limit):
            isWorking = true
            let token = holder.begin(reason: "Tilvero is putting the charge limit back")
            defer { holder.end(token); isWorking = false }
            guard await environment.apply(limit: limit) else { message = "The charge limit could not be restored. Tilvero will try again."; return false }
            await finish(removeWake: true); return true
        }
    }

    private func finish(removeWake: Bool) async {
        if removeWake, let wakeAt = state?.wakeAt { _ = await wake.cancel(wakeAt) }
        state = nil; plan = nil; defaults.removeObject(forKey: Self.key)
    }
    private func save() {
        if let state, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}
