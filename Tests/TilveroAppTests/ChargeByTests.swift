import XCTest
@testable import TilveroApp
import PowerCore

@MainActor final class ChargeByTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(_ phase: ChargeByPlanState.Phase = .armed, startIn: TimeInterval = 3600, deadlineIn: TimeInterval = 8 * 3600, target: Int = 100, previous: Int = 80) -> ChargeByPlanState {
        .init(deadline: now.addingTimeInterval(deadlineIn), target: target, previousLimit: previous, phase: phase, startAt: now.addingTimeInterval(startIn), wakeAt: nil)
    }
    private func decide(_ s: ChargeByPlanState, at offset: TimeInterval = 0, limit: Int? = 80, percent: Int? = 80, charging: Bool? = false, power: Bool? = true, sleep: Bool = false, wake: Bool = true) -> ChargeByAction {
        ChargeByRule.decide(s, now: now.addingTimeInterval(offset), observedLimit: limit, percent: percent, isCharging: charging, externalPower: power, goingToSleep: sleep, wakeConfirmed: wake)
    }

    func testArmedWaitsUntilTheStart() {
        XCTAssertEqual(decide(state(), at: 0), .none)
        XCTAssertEqual(decide(state(), at: 3500), .none)
        XCTAssertEqual(decide(state(), at: 3510), .lift(100), "The wake comes 60 s early and may itself be a few seconds early: lift from 90 s before the start.")
        XCTAssertEqual(decide(state(), at: 5000), .lift(100), "A late wake still lifts at once.")
    }
    func testWithoutPowerTheLiftWaits() {
        XCTAssertEqual(decide(state(), at: 4000, power: false), .none)
        XCTAssertEqual(decide(state(), at: 4000, power: nil), .lift(100), "Unknown power must not block a planned charge.")
    }
    func testSleepWithoutConfirmedWakeLiftsEarly() {
        XCTAssertEqual(decide(state(), at: 0, sleep: true, wake: false), .lift(100))
        XCTAssertEqual(decide(state(), at: 0, sleep: true, wake: true), .none, "A confirmed wake covers the night.")
    }
    func testUserLimitChangedWhileArmed() {
        XCTAssertEqual(decide(state(), at: 0, limit: 90), .adopt(90), "The user's new limit becomes the one to return to.")
        XCTAssertEqual(decide(state(), at: 0, limit: 100), .drop, "Already unlimited: nothing to plan.")
        XCTAssertEqual(decide(state(target: 90), at: 0, limit: 95), .drop)
    }
    func testArmedExpiresAnHourAfterTheDeadline() {
        XCTAssertEqual(decide(state(), at: 8 * 3600 + 3600), .drop)
        XCTAssertEqual(decide(state(), at: 8 * 3600 + 3599, power: false), .none)
    }
    func testChargingRestoresOnUnplugAndNeverOverwritesAnotherLimit() {
        let charging = state(.charging)
        XCTAssertEqual(decide(charging, limit: 100, power: true), .none)
        XCTAssertEqual(decide(charging, limit: 100, power: false), .restore(80))
        XCTAssertEqual(decide(charging, limit: 90, power: false), .drop, "Changed elsewhere: write nothing.")
    }
    func testChargingReleasesAnHourAfterTheDeadlineOnceFull() {
        let charging = state(.charging)
        XCTAssertEqual(decide(charging, at: 8 * 3600 + 3600, limit: 100, percent: 100, charging: false), .restore(80))
        XCTAssertEqual(decide(charging, at: 8 * 3600 + 3600, limit: 100, percent: 97, charging: false), .none)
        XCTAssertEqual(decide(charging, at: 7 * 3600, limit: 100, percent: 100, charging: false), .none, "Before the hour is up the battery stays full for the user.")
    }

    func testPlanEnergyComesFromCapacityAndVoltageBecauseNoProviderPublishesWh() {
        let readings: [String: Double] = ["030": 4622, "035": 12.629]
        let wh = ModelChargeByEnvironment.fullEnergyWh(catalog: { readings[$0] })
        XCTAssertEqual(wh ?? 0, 58.4, accuracy: 0.1)
        XCTAssertEqual(ModelChargeByEnvironment.fullEnergyWh(catalog: { ["034": 70.0][$0] }), 70, "A published estimate wins.")
        XCTAssertNil(ModelChargeByEnvironment.fullEnergyWh(catalog: { _ in nil }))
    }

    // MARK: service with fakes
    @MainActor final class Env: ChargeByEnvironment {
        var obs = ChargeByObservation(observedLimit: 80, percent: 80, isCharging: false, externalPower: true, adapterWatts: 67, fullEnergyWh: 70, systemWatts: 3)
        var applied: [Int] = []; var succeed = true; var pauses = 0; var pauseOK = true
        var phaseAtPause: ChargeByPlanState.Phase?; weak var service: ChargeByService?
        func observation() -> ChargeByObservation { obs }
        func pauseOptimizedCharging() async -> Bool { pauses += 1; phaseAtPause = service?.state?.phase; return pauseOK }
        func apply(limit: Int) async -> Bool { applied.append(limit); if succeed { obs.observedLimit = limit }; return succeed }
    }
    @MainActor final class Wake: WakeScheduling {
        var permitted = true; var scheduled: [Date] = []; var cancelled: [Date] = []; var cancelledStamps: [String?] = []; var scheduleOK = true
        var isPermitted: Bool { permitted }
        static func stamp(_ date: Date) -> String { NativeWakeScheduler.pmsetDate(date, timeZone: TimeZone(identifier: "UTC")!) }
        func schedule(_ date: Date) async -> String? { guard scheduleOK else { return nil }; scheduled.append(date); return Self.stamp(date) }
        func cancel(_ date: Date, stamp: String?) async -> Bool { cancelled.append(date); cancelledStamps.append(stamp); return true }
        func installPermission() async -> Bool { permitted = true; return true }
    }
    @MainActor final class Holder: ActivityHolding {
        var begun = 0, ended = 0
        func begin(reason: String) -> AnyObject { begun += 1; return NSObject() }
        func end(_ token: AnyObject) { ended += 1 }
    }
    private func makeService(env: Env, wake: Wake = Wake(), clock: @escaping @MainActor () -> Date) -> (ChargeByService, UserDefaults, Holder) {
        let suite = TestDefaults.name("ChargeBy"); let defaults = TestDefaults.defaults(suite)
        addTeardownBlock { TestDefaults.remove(suite) }
        let holder = Holder()
        let service = ChargeByService(defaults: defaults, wake: wake, holder: holder, now: clock)
        service.environment = env
        return (service, defaults, holder)
    }

    func testPlanUsesMacOSTimeToFullWhileChargingAndKeepsItFreshInTheChargingPhase() async throws {
        let env = Env(); env.obs.isCharging = true; env.obs.systemTimeToFullSeconds = 55 * 60
        let (service, _, _) = makeService(env: env) { self.now }
        let armed = await service.arm(deadline: now.addingTimeInterval(60 * 60), target: 100)
        XCTAssertTrue(armed)
        XCTAssertEqual(service.plan?.usedSystemEstimate, true)
        XCTAssertEqual(service.state?.phase, .charging, "The charge is already due, so the limit is lifted at once")
        env.obs.systemTimeToFullSeconds = 20 * 60
        await service.tick()
        XCTAssertEqual(service.plan?.chargeSeconds ?? 0, 30 * 60, accuracy: 0.5, "The status follows macOS's estimate while charging")
    }

    func testLatePlanSuggestsTheEarliestWorkingTimeAndShiftingItWorksWhileCharging() async throws {
        let env = Env()
        let (service, _, _) = makeService(env: env) { self.now }
        let armed = await service.arm(deadline: now.addingTimeInterval(50 * 60), target: 100)
        XCTAssertTrue(armed)
        XCTAssertEqual(service.state?.phase, .charging)
        XCTAssertEqual(service.plan?.reachesTarget, false)
        let suggested = try XCTUnwrap(service.suggestedDeadline)
        XCTAssertGreaterThanOrEqual(suggested.timeIntervalSince(now), (service.plan?.chargeSeconds ?? 0) + ChargeByPlanner.reserveSeconds)
        XCTAssertEqual(suggested.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 300), 0, accuracy: 0.001, "Rounded up to 5 minutes")
        await service.setDeadline(suggested)
        XCTAssertEqual(service.state?.deadline, suggested)
        XCTAssertEqual(service.plan?.reachesTarget, true)
        XCTAssertNil(service.suggestedDeadline, "A plan that fits needs no suggestion")
    }
    func testArmSchedulesTheWakeBeforeTheStartAndSurvivesRelaunch() async throws {
        let env = Env(), wake = Wake(); var clock = now
        let (service, defaults, _) = makeService(env: env, wake: wake) { clock }
        let armed79 = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed79)
        let armed = try XCTUnwrap(service.state)
        XCTAssertEqual(armed.previousLimit, 80)
        XCTAssertEqual(wake.scheduled.count, 1)
        XCTAssertEqual(wake.scheduled[0], armed.startAt.addingTimeInterval(-ChargeByRule.wakeLead))
        XCTAssertEqual(armed.wakeAt, wake.scheduled[0], "Only a read-back wake is recorded.")
        XCTAssertEqual(armed.wakeStamp, Wake.stamp(wake.scheduled[0]), "The exact string the wake was made with is kept")
        XCTAssertTrue(env.applied.isEmpty, "Nothing is written before the planned start.")
        clock = clock.addingTimeInterval(1)
        let reopened = ChargeByService(defaults: defaults, wake: wake)
        XCTAssertEqual(reopened.state, armed)
    }
    func testWakeAtTheStartLiftsUnderAnActivityHoldAndThenWatchesTheCharge() async throws {
        let env = Env(), wake = Wake(); var clock = now
        let (service, _, holder) = makeService(env: env, wake: wake) { clock }
        let armed94 = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed94)
        let start = try XCTUnwrap(service.state).startAt
        await service.tick()
        XCTAssertTrue(env.applied.isEmpty)
        clock = start.addingTimeInterval(-ChargeByRule.wakeLead)
        await service.systemDidWake()
        XCTAssertEqual(env.applied, [100])
        XCTAssertEqual(env.pauses, 1, "macOS Optimized Charging is paused right after the lift, so it cannot hold at 80 %")
        XCTAssertEqual(service.state?.phase, .charging)
        XCTAssertNil(service.message)
        XCTAssertEqual(holder.begun, 1); XCTAssertEqual(holder.ended, 1)
        // Unplugged: the user's limit returns and the plan ends.
        env.obs.externalPower = false
        await service.tick()
        XCTAssertEqual(env.applied, [100, 80]); XCTAssertNil(service.state)
    }
    func testLiftIsRecordedBeforeTheOptimizedChargingPauseAndAFailedPauseIsShown() async throws {
        let env = Env(), wake = Wake(); var clock = now
        let (service, _, _) = makeService(env: env, wake: wake) { clock }
        env.service = service; env.pauseOK = false
        let armed = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed)
        clock = try XCTUnwrap(service.state).startAt.addingTimeInterval(-ChargeByRule.wakeLead)
        await service.systemDidWake()
        XCTAssertEqual(env.phaseAtPause, .charging, "a relaunch during the pause already knows the limit is raised")
        XCTAssertNil(service.state?.wakeAt, "the wake is gone before the pause")
        XCTAssertEqual(service.state?.phase, .charging, "a failed pause never stops the plan")
        XCTAssertTrue(service.optimizedPauseFailed)
        XCTAssertNil(service.message, "the charging status stays visible")
        env.obs.externalPower = false   // unplugged: the plan ends and so does its warning
        await service.tick()
        XCTAssertNil(service.state)
        XCTAssertFalse(service.optimizedPauseFailed)
    }
    func testNoPermissionFallsBackToLiftingWhenTheMacGoesToSleep() async {
        let env = Env(), wake = Wake(); wake.permitted = false
        let (service, _, _) = makeService(env: env, wake: wake) { self.now }
        let armed112 = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed112)
        XCTAssertFalse(service.wakeConfirmed)
        await service.systemWillSleep()
        XCTAssertEqual(env.applied, [100], "Charging early beats not charging at all.")
    }
    func testFailedWakeIsNotClaimedAndFailedApplyIsRetried() async throws {
        let env = Env(), wake = Wake(); wake.scheduleOK = false; var clock = now
        let (service, _, _) = makeService(env: env, wake: wake) { clock }
        let armed121 = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed121)
        XCTAssertNil(service.state?.wakeAt)
        clock = try XCTUnwrap(service.state).startAt.addingTimeInterval(1)
        env.succeed = false
        await service.tick()
        XCTAssertEqual(service.state?.phase, .armed, "A failed apply never pretends to be charging.")
        env.succeed = true
        await service.tick()
        XCTAssertEqual(service.state?.phase, .charging)
    }
    func testCancelWhileChargingPutsTheLimitBack() async throws {
        let env = Env()
        let (service, _, _) = makeService(env: env) { self.now }
        // 50 minutes are not enough for the whole charge, so the plan is already due and lifts at once.
        let armed = await service.arm(deadline: now.addingTimeInterval(50 * 60), target: 100)
        XCTAssertTrue(armed)
        XCTAssertEqual(service.state?.phase, .charging)
        XCTAssertEqual(env.applied, [100])
        await service.cancel()
        XCTAssertEqual(env.applied.last, 80); XCTAssertNil(service.state)
    }
    func testRejectsPastDeadlineAndLevelsAtOrBelowTheLimit() async {
        let env = Env()
        let (service, _, _) = makeService(env: env) { self.now }
        let armed145 = await service.arm(deadline: now.addingTimeInterval(300), target: 100)
        XCTAssertFalse(armed145)
        let armed147 = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 80)
        XCTAssertFalse(armed147)
        XCTAssertNil(service.state)
    }
    func testTickerRunsTheTimerOnlyWhileAPlanExists() async throws {
        let env = Env(), wake = Wake()
        let (service, defaults, _) = makeService(env: env, wake: wake) { self.now }
        let ticker = ChargeByTicker(service: service)
        ticker.start()
        XCTAssertFalse(ticker.isTimerRunning, "No plan, no periodic tick")
        let armed = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed)
        XCTAssertTrue(ticker.isTimerRunning, "Arming starts the tick")
        await service.cancel()
        XCTAssertNil(service.state)
        XCTAssertFalse(ticker.isTimerRunning, "Cancelling stops it")
        let rearmed = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(rearmed)
        ticker.stop()
        XCTAssertFalse(ticker.isTimerRunning)
        // A plan saved by an earlier run: the timer starts with the ticker, and the launch tick acts on a due plan.
        let restored = ChargeByService(defaults: defaults, wake: wake, holder: Holder(), now: { self.now.addingTimeInterval(9 * 3600) })
        restored.environment = env
        XCTAssertNotNil(restored.state)
        let relaunched = ChargeByTicker(service: restored)
        relaunched.start()
        XCTAssertTrue(relaunched.isTimerRunning)
        for _ in 0..<50 where restored.state != nil { await Task.yield() }
        XCTAssertNil(restored.state, "The launch tick ran: past the deadline and the hold, the plan was dropped")
        XCTAssertFalse(relaunched.isTimerRunning, "A finished plan stops the tick")
        relaunched.stop()
    }
    func testWakeCommandsAreExactlyScheduleAndCancelOfOneWake() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = NativeWakeScheduler.pmsetDate(date, timeZone: utc)
        XCTAssertEqual(stamp, "01/15/2027 08:00:00")
        XCTAssertEqual(NativeWakeScheduler.scheduleArguments(stamp: stamp), ["-n", "/usr/bin/pmset", "schedule", "wake", "01/15/2027 08:00:00", "Tilvero"])
        XCTAssertEqual(NativeWakeScheduler.cancelArguments(stamp: stamp), ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", "01/15/2027 08:00:00", "Tilvero"])
        XCTAssertEqual(NativeWakeScheduler.rule(uid: 501), "#501 ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *")
        let listing = "Scheduled power events:\n [0]  wake at 01/15/2027 08:00:00 by 'Tilvero'\n [1]  wake at 01/15/2027 09:00:00 by 'other'"
        XCTAssertTrue(NativeWakeScheduler.schedulePresent(listing, stamp: stamp))
        XCTAssertFalse(NativeWakeScheduler.schedulePresent(listing, stamp: "01/15/2027 09:00:00"), "Another owner's wake does not count.")
        XCTAssertTrue(NativeWakeScheduler.schedulePresent(" [0]  wakeorpoweron at 01/15/2027 08:00:00 by 'Tilvero'", stamp: stamp),
                      "Any remaining Tilvero wake entry with that string counts as not cancelled")
    }

    func testCancelAfterATimeZoneChangeRemovesTheWakeThatWasScheduled() async throws {
        let pmset = FakeWakeSchedule()
        var zone = TimeZone(identifier: "Europe/Berlin")!
        let scheduler = NativeWakeScheduler(run: { path, arguments in await pmset.run(path, arguments) }, timeZone: { zone }, permitted: { true })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = await scheduler.schedule(date)
        let stamp = try XCTUnwrap(scheduled)
        XCTAssertEqual(stamp, "01/15/2027 09:00:00", "Scheduled in the zone of the moment")
        let listedAfterSchedule = await pmset.entries
        XCTAssertEqual(listedAfterSchedule, [stamp])
        zone = TimeZone(identifier: "America/New_York")!   // travel (or a DST switch) before the plan ends
        let cancelled = await scheduler.cancel(date, stamp: stamp)
        XCTAssertTrue(cancelled)
        let remaining = await pmset.entries
        XCTAssertTrue(remaining.isEmpty, "The cancel names the entry by the string it was made with")
        let commands = await pmset.commands
        XCTAssertEqual(commands.filter { $0.first == "-n" }.last, ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", stamp, "Tilvero"])
    }

    func testAWakeThatSurvivesItsCancelIsReportedAsNotCancelled() async throws {
        let pmset = FakeWakeSchedule(); await pmset.ignoreCancels()
        let utc = TimeZone(identifier: "UTC")!
        let scheduler = NativeWakeScheduler(run: { path, arguments in await pmset.run(path, arguments) }, timeZone: { utc }, permitted: { true })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = await scheduler.schedule(date)
        let stamp = try XCTUnwrap(scheduled)
        let cancelled = await scheduler.cancel(date, stamp: stamp)
        XCTAssertFalse(cancelled, "A Tilvero wake still listed with the saved string is not cancelled")
        let legacy = await scheduler.cancel(date, stamp: nil)
        XCTAssertFalse(legacy, "A plan saved before stamps were kept formats the date in the current zone")
        let denied = NativeWakeScheduler(run: { path, arguments in await pmset.run(path, arguments) }, timeZone: { utc }, permitted: { false })
        let deniedStamp = await denied.schedule(date)
        XCTAssertNil(deniedStamp, "No permission, no command")
    }

    func testAStoredStampMustHaveTheExactPmsetShapeBeforeItIsUsed() async throws {
        for valid in ["01/15/2027 08:00:00", "12/31/2026 23:59:59"] { XCTAssertTrue(NativeWakeScheduler.isValidStamp(valid), valid) }
        for invalid in ["", "1/15/2027 08:00:00", "01/15/2027 08:00:00 ", "01/15/2027 08:00:00; reboot", "13/15/2027 08:00:00",
                        "02/30/2027 08:00:00", "01/15/2027 24:00:00", "01-15-2027 08:00:00", "０1/15/2027 08:00:00", "01/15/2027T08:00:00"] {
            XCTAssertFalse(NativeWakeScheduler.isValidStamp(invalid), invalid)
        }
        let defaults = makeTestDefaults("ChargeByStamp").defaults
        func load(_ stamp: String) throws -> ChargeByPlanState? {
            let json = #"{"deadline":1000,"target":100,"previousLimit":80,"phase":"armed","startAt":500,"wakeAt":440,"wakeStamp":"\#(stamp)"}"#
            defaults.set(Data(json.utf8), forKey: "chargeByPlan.v1")
            return ChargeByService(defaults: defaults, wake: Wake()).state
        }
        XCTAssertEqual(try load("01/15/2027 08:00:00")?.wakeStamp, "01/15/2027 08:00:00")
        let tampered = try XCTUnwrap(try load("01/15/2027 08:00:00 -a"))
        XCTAssertNil(tampered.wakeStamp, "A malformed stamp never reaches sudo")
        XCTAssertNotNil(tampered.wakeAt, "The wake itself is kept; its cancel falls back to the formatted date")
        let pmset = FakeWakeSchedule(), utc = TimeZone(identifier: "UTC")!
        let scheduler = NativeWakeScheduler(run: { path, arguments in await pmset.run(path, arguments) }, timeZone: { utc }, permitted: { true })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await scheduler.cancel(date, stamp: "01/15/2027 08:00:00 -a")
        let commands = await pmset.commands
        XCTAssertEqual(commands.first, ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", "01/15/2027 08:00:00", "Tilvero"])
    }

    func testArmedPlanKeepsTheStampAndEveryCancelUsesIt() async throws {
        let env = Env(), wake = Wake(); var clock = now
        let (service, _, _) = makeService(env: env, wake: wake) { clock }
        let armed = await service.arm(deadline: now.addingTimeInterval(8 * 3600), target: 100)
        XCTAssertTrue(armed)
        let first = try XCTUnwrap(service.state)
        await service.setDeadline(now.addingTimeInterval(10 * 3600))   // replans: the old wake goes, a new one is made
        XCTAssertEqual(wake.cancelledStamps.first, first.wakeStamp)
        let second = try XCTUnwrap(service.state)
        XCTAssertNotEqual(second.wakeStamp, first.wakeStamp)
        clock = second.startAt.addingTimeInterval(-ChargeByRule.wakeLead)
        await service.systemDidWake()   // lifts and removes the wake it no longer needs
        XCTAssertEqual(wake.cancelledStamps.last, second.wakeStamp)
        XCTAssertNil(service.state?.wakeStamp)
        let saved = try JSONDecoder().decode(ChargeByPlanState.self, from: Data(#"{"deadline":0,"target":100,"previousLimit":80,"phase":"armed","startAt":0,"wakeAt":0}"#.utf8))
        XCTAssertNil(saved.wakeStamp, "A plan saved before stamps were kept still loads")
    }
}

/// `sudo -n pmset schedule …` and `pmset -g sched` against an in-memory schedule; nothing is run.
private actor FakeWakeSchedule {
    private(set) var entries: [String] = []
    private(set) var commands: [[String]] = []
    private var cancelsWork = true
    func ignoreCancels() { cancelsWork = false }
    func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        commands.append(arguments)
        if path == "/usr/bin/sudo", arguments.count == 6, Array(arguments.prefix(4)) == ["-n", "/usr/bin/pmset", "schedule", "wake"], arguments[5] == "Tilvero" {
            entries.append(arguments[4]); return (0, "")
        }
        if path == "/usr/bin/sudo", arguments.count == 7, Array(arguments.prefix(5)) == ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake"], arguments[6] == "Tilvero" {
            if cancelsWork { entries.removeAll { $0 == arguments[5] } }
            return (0, "")
        }
        if path == "/usr/bin/pmset", arguments == ["-g", "sched"] {
            return (0, "Scheduled power events:\n" + entries.enumerated().map { " [\($0.offset)]  wake at \($0.element) by 'Tilvero'" }.joined(separator: "\n"))
        }
        return (1, "unexpected command")
    }
}
