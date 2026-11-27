// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
@testable import TilveroApp

/// Fifth review: a charge-by warning ends with its plan; a good read clears an earlier failure for the next lapse; a first
/// read that returns without granting the interface already makes a refusal persistent. Fixture transports only.
@MainActor final class NativeChargeFifthReviewTests: XCTestCase {
    private func plannedModel(_ f: ScopeFixture, _ service: NativeChargeService, plan: ChargeByPlanState,
                              externalPower: Bool) throws -> (TilveroModel, String) {
        let data = try JSONEncoder().encode(plan)
        return f.makeModel(service, configure: { $0.set(data, forKey: "chargeByPlan.v1") },
                           snapshot: { ScopeFixture.snapshot(percent: 60, charging: false, externalPower: externalPower) })
    }

    private func chargingPlan(_ now: Date) -> ChargeByPlanState {
        ChargeByPlanState(deadline: now.addingTimeInterval(8 * 3600), target: 100, previousLimit: 80, phase: .charging,
                          startAt: now.addingTimeInterval(-3600))
    }

    /// A restore refused once (reads failing after a relaunch), then confirmed: the plan is over, so is its warning.
    func testARestoreWarningEndsWhenTheRestoreLands() async throws {
        let f = ScopeFixture(mode: "readError", initialTarget: 100); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = try plannedModel(f, service, plan: chargingPlan(Date()), externalPower: false)
        defer { model.stop(); TestDefaults.remove(suite) }
        let env = FixedObservationChargeByEnvironment(model: model, obs: ChargeByObservation(externalPower: false))
        model.chargeBy.environment = env
        await model.refreshNativeCharge()   // the first read after launch fails
        await model.chargeBy.tick()
        XCTAssertEqual(model.chargeBy.message, "The charge limit could not be restored. Tilvero will try again.")
        await f.client.setMode("")
        await model.refreshNativeCharge()
        env.obs = ChargeByObservation(observedLimit: service.reportedLimit, externalPower: false)
        await model.chargeBy.tick()          // written and confirmed: the plan ends
        await f.assertWrites(["limit80"])
        XCTAssertFalse(model.chargeBy.isArmed)
        XCTAssertNil(model.chargeBy.message)
        XCTAssertNil(ChargeByBlock(model: model, service: model.chargeBy).status, "no plan, nothing retried, no warning")
    }

    /// The same warning, then the plan dropped because the limit was changed in System Settings.
    func testARestoreWarningEndsWhenThePlanIsDropped() async throws {
        let f = ScopeFixture(initialTarget: 100); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = try plannedModel(f, service, plan: chargingPlan(Date()), externalPower: false)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let env = FixedObservationChargeByEnvironment(model: model, obs: ChargeByObservation(observedLimit: nil, externalPower: false))
        model.chargeBy.environment = env
        await f.client.setMode("readError")
        await model.chargeBy.tick()
        XCTAssertNotNil(model.chargeBy.message)
        await f.client.setMode("")
        await f.client.external(target: 90)
        await model.refreshNativeCharge()
        env.obs = ChargeByObservation(observedLimit: service.reportedLimit, externalPower: false)
        await model.chargeBy.tick()          // 90 is the user's: dropped, nothing written
        await f.assertWrites([])
        XCTAssertFalse(model.chargeBy.isArmed)
        XCTAssertNil(ChargeByBlock(model: model, service: model.chargeBy).status)
    }

    /// A lift refused twice ("could not be raised"), then the ✕: the plan is gone and so is the promise to retry.
    /// A standalone plan service (no model ticks racing the test), as in ChargeByTests.
    func testALiftWarningEndsWhenThePlanIsCancelled() async throws {
        let now = Date()
        let f = ScopeFixture(mode: "readError", initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        let planSuite = TestDefaults.name("ChargeByFifth"); let defaults = TestDefaults.defaults(planSuite)
        defer { TestDefaults.remove(planSuite) }
        defaults.set(try JSONEncoder().encode(ChargeByPlanState(deadline: now.addingTimeInterval(8 * 3600), target: 100, previousLimit: 80,
                                                                startAt: now.addingTimeInterval(-60))), forKey: "chargeByPlan.v1")
        let chargeBy = ChargeByService(defaults: defaults, wake: ChargeByTests.Wake(), holder: ChargeByTests.Holder())
        let recorder = RecordingEnv(model: model); chargeBy.environment = recorder
        await model.refreshNativeCharge()   // fails: a read has finished, refusals now count
        await chargeBy.tick(); await chargeBy.tick()
        XCTAssertEqual(recorder.results, [.notWritten, .notWritten], "both lifts refused, nothing written")
        XCTAssertEqual(chargeBy.message, "The charge limit could not be raised. Tilvero will try again.")
        await chargeBy.cancel()
        await f.assertWrites([])
        XCTAssertFalse(chargeBy.isArmed)
        XCTAssertNil(chargeBy.message)
        XCTAssertNil(ChargeByBlock(model: model, service: chargeBy).status)
    }

    /// One failed read, then a good one: the failure is over. The next lapse (sleep) keeps the slider with the last value
    /// dimmed, not the read-only layout.
    func testAGoodReadClearsAnEarlierFailureForTheNextLapse() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await f.client.setMode("readError")
        await model.refreshNativeCharge()
        await f.client.setMode("")
        await model.refreshNativeCharge()
        XCTAssertEqual(service.reportedLimit, 85)
        await f.client.setMode("agingSoon")
        await model.refreshNativeCharge()
        try await waitFor { service.reportedLimit == nil }
        XCTAssertTrue(service.settingLapsed)
        XCTAssertEqual(ChargeLimitKit.mode(model), .slider, "a lapse with no failure since the good read keeps the slider")
        XCTAssertEqual(ChargeLimitKit.shown(chosen: nil, model: model), 85)
        XCTAssertFalse(ChargeLimitKit.isConfirmed(model), "drawn dimmed until the next read confirms it")
        await f.assertWrites([])
    }

    /// The first read after launch returns, but in a state that does not grant the interface (macOS's temporary charge to
    /// full): a read has finished, so the refusal may persist and is not a quiet momentary one.
    func testAFirstReadThatReturnsWithoutAGrantMakesARefusalPersistent() async throws {
        let f = ScopeFixture(mode: "disabled", initialTarget: 90); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: false, externalPower: false)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        XCTAssertFalse(service.admitted)
        let result = await ModelChargeByEnvironment(model: model).apply(limit: 80, expected: 100)
        XCTAssertEqual(result, .notWritten)
        await f.assertWrites([])
    }

    private func waitFor(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let end = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > end { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Records what each apply returned; the observation is AC power with the limit unread.
@MainActor final class RecordingEnv: ChargeByEnvironment {
    let inner: ModelChargeByEnvironment
    var results: [ChargeByApplyResult] = []
    init(model: TilveroModel) { inner = ModelChargeByEnvironment(model: model) }
    func observation() -> ChargeByObservation { ChargeByObservation(externalPower: true) }
    func apply(limit: Int, expected: Int?) async -> ChargeByApplyResult { let r = await inner.apply(limit: limit, expected: expected); results.append(r); return r }
}
