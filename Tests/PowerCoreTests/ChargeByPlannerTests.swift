import XCTest
@testable import PowerCore

final class ChargeByPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func input(current: Double = 80, target: Int = 100, adapter: Double? = 67, draw: Double = 3, wh: Double = 70, hours: Double = 8) -> ChargeByPlanner.Input {
        .init(now: now, deadline: now.addingTimeInterval(hours * 3600), currentPercent: current, targetPercent: target, adapterWatts: adapter, systemDrawWatts: draw, fullEnergyWh: wh)
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
    func testPercentInverseMatchesForwardEstimate() {
        let seconds = ChargeByPlanner.chargeSeconds(from: 60, to: 95, bulkWatts: 50, fullEnergyWh: 70)
        XCTAssertEqual(ChargeByPlanner.percent(from: 60, after: seconds, bulkWatts: 50, fullEnergyWh: 70), 95, accuracy: 0.01)
    }
}
