import XCTest
import PowerCore

final class RetainedIdentityTests: XCTestCase {
    func testTotalFailureRetainsIdentitySoReplacementCannotInheritOldCycles() {
        let first = BatterySnapshot(chargePercent: .init(value: 80, source: "fixture"), cycleCount: .init(value: 124, source: "fixture"), monotonicTime: 100, batteryIdentityToken: "pack-a")
        let failed = BatterySnapshot(collectedAt: Date(), monotonicTime: 110).retainingPreviousReadings(first)
        XCTAssertEqual(failed.cycleCount.value, 124)
        XCTAssertEqual(failed.batteryIdentityToken, "pack-a")
        let replacement = BatterySnapshot(chargePercent: .init(value: 75, source: "fixture"), monotonicTime: 120, batteryIdentityToken: "pack-b").retainingPreviousReadings(failed)
        XCTAssertNil(replacement.cycleCount.value)
    }
}
