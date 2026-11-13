import XCTest
@testable import PowerCore

final class ChargeByPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func input(current: Double = 80, target: Int = 100, adapter: Double? = 67, draw: Double = 3, wh: Double = 70, hours: Double = 8, systemETA: TimeInterval? = nil) -> ChargeByPlanner.Input {
        .init(now: now, deadline: now.addingTimeInterval(hours * 3600), currentPercent: current, targetPercent: target, adapterWatts: adapter, systemDrawWatts: draw, fullEnergyWh: wh, systemTimeToFullSeconds: systemETA)
    }
    func testFinishesTenMinutesBeforeTheRequestedTimeWithSafetyMargin() throws {
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input()))
        XCTAssertTrue(plan.reachesTarget); XCTAssertFalse(plan.mustStartNow)
        XCTAssertEqual(plan.readyBy, now.addingTimeInterval(8 * 3600 - 600))
        XCTAssertEqual(plan.startAt.addingTimeInterval(plan.chargeSeconds), plan.readyBy, "Charging ends exactly at readyBy.")
        // 80 -> 100 % of 70 Wh at a ~54 W net rate with a 0.4 taper, stretched by 1.2: about 47 minutes.
        XCTAssertEqual(plan.chargeSeconds / 60, 46.7, accuracy: 1.5)
    }
    func testSlowerAdapterAndBusyMacStartEarlier() throws {
        let fast = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: 96, draw: 3)))
        let slow = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: 30, draw: 3)))
        let busy = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: 30, draw: 15)))
        XCTAssertGreaterThan(slow.chargeSeconds, fast.chargeSeconds)
        XCTAssertGreaterThan(busy.chargeSeconds, slow.chargeSeconds, "A Mac that keeps drawing power charges more slowly.")
        XCTAssertLessThan(busy.startAt, slow.startAt)
    }
    func testBulkRateIsCappedByTheBatterySize() throws {
        let a = try XCTUnwrap(ChargeByPlanner.plan(input(current: 20, target: 80, adapter: 140, draw: 3)))
        let b = try XCTUnwrap(ChargeByPlanner.plan(input(current: 20, target: 80, adapter: 96, draw: 3)))
        XCTAssertEqual(a.chargeSeconds, b.chargeSeconds, accuracy: 1, "Both adapters exceed 0.8 C, so the cap decides.")
    }
    func testUnknownAdapterAssumesConservativePower() throws {
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: nil)))
        XCTAssertTrue(plan.adapterAssumed)
        XCTAssertEqual(plan.netChargeWatts, ChargeByPlanner.fallbackAdapterWatts * ChargeByPlanner.adapterEfficiency - 3, accuracy: 0.001)
    }
    func testTooLateReportsWhatWillBeReached() throws {
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input(current: 40, target: 100, adapter: 30, hours: 1)))
        XCTAssertFalse(plan.reachesTarget); XCTAssertTrue(plan.mustStartNow)
        XCTAssertEqual(plan.startAt, now)
        XCTAssertGreaterThan(plan.expectedPercentAtReady, 40); XCTAssertLessThan(plan.expectedPercentAtReady, 100)
    }
    func testAlreadyAtTargetNeedsNothing() throws {
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input(current: 100)))
        XCTAssertTrue(plan.alreadyReached); XCTAssertEqual(plan.chargeSeconds, 0)
    }
    func testInvalidInputGivesNoPlan() {
        XCTAssertNil(ChargeByPlanner.plan(input(wh: 0)))
        XCTAssertNil(ChargeByPlanner.plan(input(target: 20)))
        XCTAssertNil(ChargeByPlanner.plan(input(current: .nan)))
        XCTAssertNil(ChargeByPlanner.plan(input(draw: -1)))
    }
    /// Regression (2026-11-13): no provider publishes catalog 033/034 (Wh), so the plan was never computable on a real Mac
    /// ("Not enough battery data yet"). The planning energy comes from the full capacity in mAh and the pack voltage.
    func testFullEnergyEstimateFromCapacityAndPackVoltage() throws {
        // A 4622 mAh pack reading 12.629 V while charging: never below the 11.4 V nominal, so the estimate errs long, not short.
        XCTAssertEqual(try XCTUnwrap(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: 4622, packVolts: 12.629)), 58.4, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: 4622, packVolts: 10.0)), 52.7, accuracy: 0.1, "A sagging pack never lowers the estimate below nominal.")
        XCTAssertEqual(try XCTUnwrap(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: 4622, packVolts: nil)), 52.7, accuracy: 0.1, "Unknown voltage falls back to nominal.")
        XCTAssertNil(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: nil, packVolts: 12))
        XCTAssertNil(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: 0, packVolts: 12))
        XCTAssertNil(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: .nan, packVolts: 12))
    }
    func testOwnerScenarioFortyMinutesOfWorkIsPlannedInFourHours() throws {
        let wh = try XCTUnwrap(ChargeByPlanner.estimatedFullEnergyWh(fullCapacityMAh: 4622, packVolts: 12.629))
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input(current: 76, target: 100, adapter: 30, draw: 3, wh: wh, hours: 4)))
        XCTAssertTrue(plan.reachesTarget)
        XCTAssertLessThan(plan.startAt, now.addingTimeInterval(3 * 3600), "76 % to 100 % at 30 W needs well under three hours.")
    }
    /// Owner idea 2026-11-13: once the Mac is charging, macOS publishes its own time to full; use it (plus a margin) instead of the model.
    func testMacOSTimeToFullReplacesTheModelWhileChargingToFull() throws {
        let plan = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: 30, wh: 58.4, hours: 1.5, systemETA: 55 * 60)))
        XCTAssertTrue(plan.usedSystemEstimate)
        XCTAssertEqual(plan.chargeSeconds, 55 * 60 * ChargeByPlanner.systemEstimateMargin, accuracy: 0.5)
        XCTAssertTrue(plan.reachesTarget, "55 min from macOS plus 15 % fits in the 80 minutes that remain before the 10-minute reserve")
        let late = try XCTUnwrap(ChargeByPlanner.plan(input(adapter: 30, wh: 58.4, hours: 1.0, systemETA: 55 * 60)))
        XCTAssertFalse(late.reachesTarget)
        XCTAssertLessThan(late.expectedPercentAtReady, 100); XCTAssertGreaterThan(late.expectedPercentAtReady, 80)
    }
    func testSystemTimeToFullIsIgnoredForOtherTargetsAndBadValues() throws {
        XCTAssertFalse(try XCTUnwrap(ChargeByPlanner.plan(input(target: 90, systemETA: 600))).usedSystemEstimate, "macOS reports time to 100 %, not to 90 %")
        XCTAssertFalse(try XCTUnwrap(ChargeByPlanner.plan(input(systemETA: 0))).usedSystemEstimate)
        XCTAssertFalse(try XCTUnwrap(ChargeByPlanner.plan(input(systemETA: .nan))).usedSystemEstimate)
        XCTAssertFalse(try XCTUnwrap(ChargeByPlanner.plan(input(systemETA: nil))).usedSystemEstimate)
    }
    func testPercentInverseMatchesForwardEstimate() {
        let seconds = ChargeByPlanner.chargeSeconds(from: 60, to: 95, bulkWatts: 50, fullEnergyWh: 70)
        XCTAssertEqual(ChargeByPlanner.percent(from: 60, after: seconds, bulkWatts: 50, fullEnergyWh: 70), 95, accuracy: 0.01)
    }
}
