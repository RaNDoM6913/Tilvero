import XCTest
import PowerCore
@testable import TilveroApp

@MainActor final class SleepTimerServiceTests: XCTestCase {
    func testWakeBeforeNotificationCannotSubmitAnOverdueTimerInsideGrace() async throws {
        let fixture = SleepTimerFixture()
        var awake = 0.0
        let service = SleepTimerService(driver: fixture, monotonic: { fixture.now },
            suspending: { awake }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        try service.start(minutes: 1)
        fixture.now = 62; awake = 10
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertFalse(service.isActive)
        service.systemDidWake()
        XCTAssertEqual(fixture.requests, 0)
    }
    func testClockChangesAffectPresentationOnlyAndOneMinuteStartsWarning() async throws {
        let fixture = SleepTimerFixture()
        let service = fixture.service()
        try service.start(minutes: 1)
        XCTAssertEqual(service.phase, .warning)
        XCTAssertEqual(service.remainingSeconds, 60)
        fixture.wall = Date(timeIntervalSince1970: -3_600)
        fixture.now = 30
        XCTAssertEqual(service.remainingSeconds, 30)
        XCTAssertEqual(service.endDate, Date(timeIntervalSince1970: -3_570))
        service.cancel()
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 0)
    }

    func testDeniedSleepKeepsExactDiagnosticAndNeverRetries() async throws {
        let fixture = SleepTimerFixture()
        fixture.failure = NSError(domain: "SleepTest", code: -536870174,
                                  userInfo: [NSLocalizedDescriptionKey: "IOPMSleepSystem returned -536870174"])
        let service = fixture.service()
        try service.start(minutes: 1)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(service.phase, .failed)
        XCTAssertTrue(service.diagnostic?.contains("-536870174") == true)
        fixture.now = 61
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 1)
    }

    func testAcceptedRequestCannotBeReissuedAndTimesOutWithoutObservedSleep() async throws {
        let fixture = SleepTimerFixture(), service: SleepTimerService
        service = fixture.service()
        try service.start(minutes: 1)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(service.phase, .accepted)
        service.cancel()
        XCTAssertEqual(service.phase, .accepted)
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 1)
        fixture.now = 120
        await service.reconcile()
        XCTAssertEqual(service.phase, .unconfirmed)
        service.systemWillSleep()
        XCTAssertEqual(service.phase, .unconfirmed)
    }

    func testEarlySleepWakeSessionSwitchAndStopNeverReplayOverdueTimer() async throws {
        for event in 0..<4 {
            let fixture = SleepTimerFixture(), service: SleepTimerService
            service = fixture.service()
            try service.start(minutes: 1)
            switch event {
            case 0: service.systemWillSleep()
            case 1: service.systemDidWake()
            case 2: service.sessionResigned()
            default: service.stop()
            }
            fixture.now = 60
            await service.reconcile()
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(fixture.requests, 0)
        }
    }

    func testLateCallbackAndOffConsoleNeverPrepareOrSubmit() async throws {
        for late in [false, true] {
            let fixture = SleepTimerFixture()
            var preparationCount = 0
            let service = fixture.service(prepare: { preparationCount += 1; return true })
            try service.start(minutes: 1)
            fixture.now = late ? 65.01 : 60
            fixture.console = late
            await service.reconcile()
            XCTAssertEqual(preparationCount, 0)
            XCTAssertEqual(fixture.requests, 0)
            XCTAssertFalse(service.isActive)
        }
    }

    func testPreparationFailureAndOverrunNeverSubmit() async throws {
        for overrun in [false, true] {
            let fixture = SleepTimerFixture()
            let service = fixture.service(prepare: {
                if overrun { fixture.now = 66 }
                return overrun
            })
            try service.start(minutes: 1)
            fixture.now = 60
            await service.reconcile()
            XCTAssertEqual(fixture.requests, 0)
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(service.phase, overrun ? .expired : .cancelled)
        }
    }

    func testCancellationDuringPreparationAndNewSessionCannotSubmitOldRequest() async throws {
        let fixture = SleepTimerFixture(), gate = SleepPreparationGate()
        let service = fixture.service(prepare: { await gate.wait() })
        try service.start(minutes: 1)
        fixture.now = 60
        let request = Task { await service.reconcile() }
        while gate.waiter == nil { await Task.yield() }
        XCTAssertEqual(service.phase, .preparing)
        service.cancel()
        try service.start(minutes: 20)
        let replacement = service.sessionID
        gate.resume(true)
        await request.value
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(service.sessionID, replacement)
        XCTAssertEqual(service.phase, .armed)
        service.stop()
    }

    func testConsoleRecheckedAfterPreparationAndWillSleepObservation() async throws {
        let fixture = SleepTimerFixture()
        let service = fixture.service(prepare: { fixture.console = false; return true })
        try service.start(minutes: 1)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(service.phase, .cancelled)
        fixture.console = true
        service.prepare = { true }
        try service.start(minutes: 1)
        fixture.now = 120
        await service.reconcile()
        service.systemWillSleep()
        service.systemDidWake()
        XCTAssertEqual(service.phase, .completed)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testLifecycleInvalidationDuringRequestingPublicationCannotSubmit() async throws {
        let fixture = SleepTimerFixture()
        let service = fixture.service()
        service.onPhaseChange = { [weak service] phase in
            if phase == .requesting { service?.sessionResigned() }
        }
        try service.start(minutes: 1)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.phase, .cancelled)
    }

    func testSynchronousSleepObservationIsNotOverwrittenByTransportAcceptance() async throws {
        let fixture = SleepTimerFixture()
        let service = fixture.service()
        fixture.onRequest = { [weak service] in service?.systemWillSleep() }
        try service.start(minutes: 1)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(service.phase, .completed)
        XCTAssertEqual(service.message, "System sleep was observed.")
        XCTAssertEqual(fixture.requests, 1)
    }

    func testWarningExtensionRearmsAndOldDeadlineCannotSubmit() async throws {
        let fixture = SleepTimerFixture()
        let service = fixture.service()
        try service.start(minutes: 1)
        let id = service.sessionID
        fixture.now = 30
        try service.extend()
        XCTAssertEqual(service.sessionID, id)
        XCTAssertEqual(service.phase, .armed)
        XCTAssertEqual(service.remainingSeconds, 930)
        fixture.now = 60
        await service.reconcile()
        XCTAssertEqual(fixture.requests, 0)
        XCTAssertEqual(service.remainingSeconds, 900)
        service.stop()
    }

    func testSleepOrWakeDuringPreparationInvalidatesThePendingRequest() async throws {
        for woke in [false, true] {
            let fixture = SleepTimerFixture(), gate = SleepPreparationGate()
            let service = fixture.service(prepare: { await gate.wait() })
            try service.start(minutes: 1)
            fixture.now = 60
            let request = Task { await service.reconcile() }
            while gate.waiter == nil { await Task.yield() }
            if woke { service.systemDidWake() } else { service.systemWillSleep() }
            gate.resume(true)
            await request.value
            XCTAssertEqual(fixture.requests, 0)
            XCTAssertEqual(service.phase, .cancelled)
        }
    }

    func testDisallowedContextAndRelaunchHaveNoExecutableIntent() throws {
        let fixture = SleepTimerFixture()
        let denied = fixture.service(allowed: false)
        XCTAssertFalse(denied.isAvailable)
        XCTAssertThrowsError(try denied.start(minutes: 1))
        let first = fixture.service()
        try first.start(minutes: 30)
        let reopened = fixture.service()
        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertNil(reopened.sessionID)
        XCTAssertEqual(fixture.requests, 0)
        first.stop()
    }

    func testStaleScheduledCallbackCannotRequestForCancelledSession() async throws {
        let fixture = SleepTimerFixture(), schedule = SleepTimerScheduleGate()
        let service = SleepTimerService(driver: fixture, monotonic: { fixture.now }, suspending: { fixture.now },
                                       sleeper: { await schedule.wait($0) })
        try service.start(minutes: 2)
        while schedule.waiters.count < 1 { await Task.yield() }
        service.cancel()
        try service.start(minutes: 20)
        while schedule.waiters.count < 2 { await Task.yield() }
        let replacement = service.sessionID
        fixture.now = 120
        schedule.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.sessionID, replacement)
        XCTAssertEqual(service.phase, .armed)
        XCTAssertEqual(fixture.requests, 0)
        service.stop()
        schedule.resumeAll()
    }

    func testSchedulerUsesWarningDeadlineAndObservationBoundariesOnly() async throws {
        let fixture = SleepTimerFixture(), schedule = SleepTimerScheduleGate()
        let service = SleepTimerService(driver: fixture, monotonic: { fixture.now }, suspending: { fixture.now },
                                       sleeper: { await schedule.wait($0) })
        try service.start(minutes: 2)
        while schedule.waiters.count < 1 { await Task.yield() }
        XCTAssertEqual(schedule.delays, [60])
        fixture.now = 60
        schedule.resumeFirst()
        while schedule.delays.count < 2 { await Task.yield() }
        XCTAssertEqual(service.phase, .warning)
        XCTAssertEqual(schedule.delays, [60, 60])
        fixture.now = 120
        schedule.resumeFirst()
        while schedule.delays.count < 3 { await Task.yield() }
        XCTAssertEqual(service.phase, .accepted)
        XCTAssertEqual(schedule.delays, [60, 60, 60])
        service.stop()
        schedule.resumeAll()
    }
}

@MainActor private final class SleepTimerFixture: SleepTimerTransport {
    var now = 0.0
    var wall = Date(timeIntervalSince1970: 0)
    var console = true
    var requests = 0
    var failure: Error?
    var onRequest: (@MainActor () -> Void)?
    func isCurrentConsoleSession() -> Bool { console }
    func requestSleep() throws { requests += 1; onRequest?(); if let failure { throw failure } }
    func service(allowed: Bool = true, prepare: @escaping @MainActor () async -> Bool = { true }) -> SleepTimerService {
        SleepTimerService(driver: self, allowed: allowed, monotonic: { self.now }, suspending: { self.now },
                          wallClock: { self.wall }, sleeper: { _ in try await Task.sleep(for: .seconds(86_400)) },
                          prepare: prepare)
    }
}
@MainActor private final class SleepPreparationGate {
    var waiter: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { waiter = $0 } }
    func resume(_ value: Bool) { let saved = waiter; waiter = nil; saved?.resume(returning: value) }
}
@MainActor private final class SleepTimerScheduleGate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    var delays: [Double] = []
    func wait(_ seconds: Double) async {
        delays.append(seconds)
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeFirst() { waiters.removeFirst().resume() }
    func resumeAll() { let saved = waiters; waiters = []; saved.forEach { $0.resume() } }
}
