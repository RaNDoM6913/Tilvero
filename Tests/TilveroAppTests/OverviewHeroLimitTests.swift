// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
@testable import TilveroApp

final class OverviewHeroLimitTests: XCTestCase {
    private func snapshot(enabled: Bool, target: Int, registered: Int?? = nil, age: TimeInterval = 0, readback: Bool = true, onBattery: Bool = false) -> NativeChargeSnapshot {
        NativeChargeSnapshot(configuration: .init(enabled: enabled, target: target, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100],
                             registeredManualLimit: registered ?? (enabled ? target : nil), policyReadbackAvailable: readback,
                             collectedAt: Date().addingTimeInterval(-age), registrationExpected: !onBattery)
    }

    func testConfirmedLimitShowsItsTargetAndAnOffLimitShowsOneHundred() {
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: true, target: 90)), .percent(90))
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: false, target: 90)), .percent(100))
        XCTAssertEqual(OverviewHeroLimit.percent(85).text, "85%")
    }

    func testAnUnconfirmedLimitIsADashNeverAPlausibleNumber() {
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: nil), .unconfirmed)
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: true, target: 90, age: 300)), .unconfirmed, "stale")
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: true, target: 90, readback: false)), .unconfirmed, "no policy readback")
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: true, target: 90, registered: .some(80))), .unconfirmed, "registry disagrees")
        XCTAssertEqual(OverviewHeroLimit.unconfirmed.text, "—")
    }

    func testBatteryPowerWithAnEmptyRegistryStillConfirmsTheStoredLimit() {
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: true, observed: snapshot(enabled: true, target: 85, registered: .some(nil), onBattery: true)), .percent(85))
    }

    func testAMacWithoutNativeChargeControlShowsNoCapsule() {
        XCTAssertEqual(OverviewHeroLimit.resolve(usesNativeCharge: false, observed: snapshot(enabled: true, target: 90)), .hidden)
        XCTAssertNil(OverviewHeroLimit.hidden.text)
    }

    func testTheCapsuleIsAsWideAsTheBatteryIcon() {
        XCTAssertEqual(OverviewHero.iconWidth, 54)
    }
}
