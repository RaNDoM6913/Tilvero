import XCTest
@testable import TilveroApp

@MainActor final class ChargeOnceTests: XCTestCase {
    func testRuleKeepsWhileChargingAtTheLiftedLimit() {
        XCTAssertEqual(ChargeOnceRule.decide(previous: 85, observedTarget: 100, percent: 72, isCharging: true, externalPower: true), .keep)
        XCTAssertEqual(ChargeOnceRule.decide(previous: 85, observedTarget: nil, percent: nil, isCharging: nil, externalPower: nil), .keep, "Unknown readings change nothing.")
    }
    func testRuleRestoresWhenFullOrUnplugged() {
        XCTAssertEqual(ChargeOnceRule.decide(previous: 85, observedTarget: 100, percent: 100, isCharging: false, externalPower: true), .restore(85))
        XCTAssertEqual(ChargeOnceRule.decide(previous: 90, observedTarget: 100, percent: 60, isCharging: false, externalPower: false), .restore(90))
        XCTAssertEqual(ChargeOnceRule.decide(previous: 85, observedTarget: 100, percent: 100, isCharging: true, externalPower: true), .keep, "Still topping off.")
    }
    func testRuleDropsWhenTheLimitWasChangedElsewhere() {
        XCTAssertEqual(ChargeOnceRule.decide(previous: 85, observedTarget: 90, percent: 100, isCharging: false, externalPower: false), .drop, "The user's own choice wins, nothing is written.")
    }
    func testStorePersistsAndIgnoresInvalidValues() {
        let suite = "TilveroChargeOnce-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ChargeOnceStore(preferences: defaults).isActive)
        let store = ChargeOnceStore(preferences: defaults)
        store.begin(previous: 85)
        XCTAssertEqual(ChargeOnceStore(preferences: defaults).previousTarget, 85, "Survives a relaunch.")
        store.clear()
        XCTAssertNil(ChargeOnceStore(preferences: defaults).previousTarget)
        defaults.set(100, forKey: "chargeOncePreviousTarget")
        XCTAssertNil(ChargeOnceStore(preferences: defaults).previousTarget, "100 is not a limit to return to.")
        defaults.set(42, forKey: "chargeOncePreviousTarget")
        XCTAssertNil(ChargeOnceStore(preferences: defaults).previousTarget)
    }
}
