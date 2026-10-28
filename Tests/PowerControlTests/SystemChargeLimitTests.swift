import XCTest
@testable import ChargeBackends

final class SystemChargeLimitTests: XCTestCase {
    func testManualLimitIsSeparateFromOptimizedAndTerminatedRequests() throws {
        let value = try SystemChargeLimitParser.parse("""
        Battery level limits:
        (
          { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 85; },
          { Terminated = 0; chargeSocLimitReason = optimizedBatteryCharging; chargeSocLimitSoc = 80; },
          { Terminated = 1; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 90; }
        )
        """)
        XCTAssertEqual(value.manualLimit, 85)
        XCTAssertEqual(value.otherLimits, [80])
        XCTAssertFalse(value.manualLimitIsConflicting)
    }

    func testNoPolicyIsDifferentFromUnavailableOrConflicting() throws {
        XCTAssertNil(try SystemChargeLimitParser.parse("No battery level limits set").manualLimit)
        XCTAssertThrowsError(try SystemChargeLimitParser.parse("Battery level limits:\n({chargeSocLimitSoc = 180;})"))
        XCTAssertThrowsError(try SystemChargeLimitParser.parse("unknown output"))
        let conflict = try SystemChargeLimitParser.parse("""
        Battery level limits:
        ({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;},
         {Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=90;})
        """)
        XCTAssertNil(conflict.manualLimit)
        XCTAssertTrue(conflict.manualLimitIsConflicting)
    }

    func testObservationExpiresAndMissingReadbackNeverBecomesFresh() throws {
        let now = Date()
        let limits = try SystemChargeLimitParser.parse("No battery level limits set")
        XCTAssertTrue(SystemChargeLimitObservation(collectedAt: now, limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now.addingTimeInterval(-66), limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now.addingTimeInterval(10), limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now, limits: nil).isFresh(at: now))
    }

    func testUnknownAndMalformedRowsNeverBecomeManualLimit() throws {
        XCTAssertEqual(try SystemChargeLimitParser.parse("Battery level limits:\n({Terminated=0;chargeSocLimitReason=newPolicy;chargeSocLimitSoc=70;})").otherLimits, [70])
        for row in ["{chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;}",
                    "{Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85.5;}",
                    "{Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;} trailing"] {
            XCTAssertThrowsError(try SystemChargeLimitParser.parse("Battery level limits:\n(\(row))"))
        }
    }
}
