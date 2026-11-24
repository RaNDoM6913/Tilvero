// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

/// A fake PowerUI: nothing here reaches the real Optimized Battery Charging setting.
final class FakeOptimizedCharging: OptimizedChargingTransport, @unchecked Sendable {
    private let lock = NSLock()
    var enabled = true, holding = false, deadline: Date? = nil
    var readable = true, writesApply = true
    private(set) var calls: [String] = []
    func read() async throws -> OptimizedChargingState {
        lock.withLock { calls.append("read") }
        guard readable else { throw PolicyError.unavailable }
        return OptimizedChargingState(enabled: enabled, holding: enabled && holding, fullChargeBy: deadline)
    }
    func setEnabled(_ value: Bool) async throws {
        lock.withLock { calls.append("set \(value)") }
        if writesApply { enabled = value; if !value { holding = false } }
    }
    func pauseUntilTomorrow() async throws {
        lock.withLock { calls.append("pause") }
        if writesApply { holding = false }
    }
}

@MainActor final class OptimizedChargingTests: XCTestCase {
    func testSwitchWritesAndReadsBack() async {
        let fake = FakeOptimizedCharging()
        let service = OptimizedChargingService(transport: fake, allowed: true)
        await service.refresh()
        XCTAssertTrue(service.isAvailable); XCTAssertTrue(service.shownEnabled)
        let ok = await service.setEnabled(false)
        XCTAssertTrue(ok); XCTAssertEqual(service.state?.enabled, false); XCTAssertNil(service.failure)
        XCTAssertEqual(fake.calls.suffix(2), ["set false", "read"], "every write is read back")
        fake.writesApply = false
        let refused = await service.setEnabled(true)
        XCTAssertFalse(refused); XCTAssertEqual(service.state?.enabled, false, "shows what macOS reports, not the request")
        XCTAssertNotNil(service.failure)
        XCTAssertNil(service.requested)
    }

    func testUnreadableOrNotAllowedIsHiddenAndNeverWritten() async {
        let fake = FakeOptimizedCharging(); fake.readable = false
        let hidden = OptimizedChargingService(transport: fake, allowed: true)
        await hidden.refresh()
        XCTAssertFalse(hidden.isAvailable)
        let paused = await hidden.pauseForPlannedCharge()
        XCTAssertFalse(paused)
        XCTAssertFalse(fake.calls.contains { $0 != "read" }, "unreadable: nothing is written")
        let demo = FakeOptimizedCharging()
        let off = OptimizedChargingService(transport: demo, allowed: false)
        await off.refresh(); _ = await off.setEnabled(false); _ = await off.pauseForPlannedCharge()
        XCTAssertTrue(demo.calls.isEmpty, "not allowed (DEMO, monitoring only): never touched")
    }

    func testPlannedChargePausesOnlyWhenOn() async {
        let on = FakeOptimizedCharging(); on.holding = true
        let service = OptimizedChargingService(transport: on, allowed: true)
        let paused = await service.pauseForPlannedCharge()
        XCTAssertTrue(paused); XCTAssertTrue(on.calls.contains("pause"))
        XCTAssertFalse(on.calls.contains { $0.hasPrefix("set") }, "the user's switch is never changed by a plan")
        let offFake = FakeOptimizedCharging(); offFake.enabled = false
        let offService = OptimizedChargingService(transport: offFake, allowed: true)
        let none = await offService.pauseForPlannedCharge()
        XCTAssertFalse(none); XCTAssertFalse(offFake.calls.contains("pause"))
    }

    func testHoldLineUsesOnlyWhatMacOSReports() {
        let now = Date()
        XCTAssertNil(OptimizedChargingText.holdLine(.init(enabled: true, holding: false, fullChargeBy: nil, collectedAt: now)))
        XCTAssertNil(OptimizedChargingText.holdLine(.init(enabled: false, holding: true, fullChargeBy: nil, collectedAt: now)))
        XCTAssertEqual(OptimizedChargingText.holdLine(.init(enabled: true, holding: true, fullChargeBy: nil, collectedAt: now)),
                       L10n.text("macOS is holding the charge"), "no plan time: no time shown")
        let line = OptimizedChargingText.holdLine(.init(enabled: true, holding: true, fullChargeBy: now.addingTimeInterval(7200), collectedAt: now))
        XCTAssertTrue(line?.contains("≈") == true)
    }
}
