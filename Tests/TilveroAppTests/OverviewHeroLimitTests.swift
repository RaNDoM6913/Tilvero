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

    /// The capsule takes the presentation's fresh preference (what macOS stores), as the hero does.
    private func resolve(_ value: NativeChargeSnapshot?, native: Bool = true) -> OverviewHeroLimit {
        OverviewHeroLimit.resolve(usesNativeCharge: native, preference: value.flatMap { $0.isFresh ? $0.configuration : nil })
    }

    func testTheStoredLimitShowsItsTargetAndAnOffLimitShowsOneHundred() {
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 90)), .percent(90))
        XCTAssertEqual(resolve(snapshot(enabled: false, target: 90)), .percent(100))
        XCTAssertEqual(OverviewHeroLimit.percent(85).text, "85%")
    }

    func testOnlyANothingFreshReadIsADash() {
        XCTAssertEqual(resolve(nil), .unconfirmed)
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 90, age: 300)), .unconfirmed, "stale")
        XCTAssertEqual(OverviewHeroLimit.unconfirmed.text, "—")
    }

    /// Contract 1 (O3): what macOS reports is shown, also while the registry is not confirmed (the hint lives on the
    /// Charge page), exactly as System Settings shows it.
    func testAnUnconfirmedPolicyStillShowsWhatMacOSStores() {
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 90, readback: false)), .percent(90), "no policy readback")
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 90, registered: .some(80))), .percent(90), "registry disagrees")
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 85, registered: .some(nil), onBattery: true)), .percent(85), "battery")
    }

    func testAMacWithoutNativeChargeControlShowsNoCapsule() {
        XCTAssertEqual(resolve(snapshot(enabled: true, target: 90), native: false), .hidden)
        XCTAssertNil(OverviewHeroLimit.hidden.text)
    }

    func testTheCapsuleIsAsWideAsTheBatteryIcon() {
        XCTAssertEqual(OverviewHero.iconWidth, 54)
    }
}
