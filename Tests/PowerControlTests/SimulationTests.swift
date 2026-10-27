import XCTest
import PowerCore
import PowerSimulator

@MainActor final class SimulationTests: XCTestCase {
    func testSimulationRelaunchCancelsOneShotAndPreservesPendingReturn() async throws {
        let controller = try SimulationController()
        try await controller.observeCharge(percent: 75, externalPower: true)
        try await controller.submit(ChargeControlRequest.setCeiling(percent: 80))
        try await controller.submit(ChargeControlRequest.chargeToFullOnce)
        try await controller.observeCharge(percent: 95, externalPower: true)
        let saved = try await controller.exportState()
        let restarted = try SimulationController(savedState: saved)
        let state = await restarted.snapshot()
        XCTAssertTrue(state.isSimulation)
        XCTAssertEqual(state.charge.appliedTarget, 100)
        XCTAssertEqual(state.charge.pendingTarget, 80)
        XCTAssertEqual(state.charge.requested, .ceiling(80))
        XCTAssertEqual(state.fans.phase, .systemAuto)
    }
    func testBeforeLeavingProfileUsesOneShotAndFanLeaseUsesMonotonicTime() async throws {
        let controller = try SimulationController()
        let result = await controller.applyProfile(PowerProfile(name: "Before leaving", oneShotFullCharge: true))
        XCTAssertTrue(result.isComplete)
        let initial = await controller.snapshot(); XCTAssertEqual(initial.charge.requested, .fullOnce)
        try await controller.setFanPolicy(.boost(rpm: 4000, seconds: 30))
        try await controller.advance(seconds: 16)
        let later = await controller.snapshot(); XCTAssertEqual(later.fans.phase, .systemAuto)
    }
}
