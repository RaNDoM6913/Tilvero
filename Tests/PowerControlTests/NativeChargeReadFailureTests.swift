import XCTest
@testable import ChargeBackends

final class NativeChargeReadFailureTests: XCTestCase {
    // Losing only the unrecognized state must not erase independently valid
    // capability discovery, and must never manufacture a state snapshot.
    func testUnknownStateRetainsOnlyValidatedSupportedTargets() throws {
        let original = bridgeError(targets: [80, 85, 90, 95, 100])
        let mapped = PowerUIChargeClient.readError(original)
        let failure = try XCTUnwrap(mapped as? NativeChargeReadFailure)
        XCTAssertEqual(failure.supportedTargets, [80, 85, 90, 95, 100])
        XCTAssertNotNil(failure.errorDescription)
    }

    func testForeignDomainsAndOtherCodesPreserveTheirOriginalErrors() {
        for (domain, code) in [("other.client", 5), ("Tilvero.NativeCharge.extra", 5), ("Tilvero.NativeCharge", 4), ("Tilvero.NativeCharge", 6)] {
            let original = bridgeError(domain: domain, code: code, targets: [80, 100])
            XCTAssertTrue(PowerUIChargeClient.readError(original) as NSError === original)
        }
    }

    func testMalformedTargetMetadataNeverBecomesPartialDiscovery() {
        let invalid: [Any] = [
            [], [80, 80, 100], [100, 80], [79, 100], [80, 101],
            [NSNumber(value: 80.5), NSNumber(value: 100)],
            [NSNumber(value: true), NSNumber(value: 100)],
            [NSNumber(value: Double.nan)], [NSNumber(value: Double.infinity)],
            ["80", "100"], [NSNull()], "80,100", ["targets": [80, 100]],
            Array(repeating: 80, count: 22)
        ]
        for (index, targets) in invalid.enumerated() {
            let original = bridgeError(targets: targets)
            XCTAssertTrue(PowerUIChargeClient.readError(original) as NSError === original, "invalid case \(index)")
        }
        let missing = NSError(domain: "Tilvero.NativeCharge", code: 5, userInfo: [NSLocalizedDescriptionKey: "native failure"])
        XCTAssertTrue(PowerUIChargeClient.readError(missing) as NSError === missing)
    }

    func testTypedFailureCannotCarryInvalidOrUnsortedTargets() {
        for targets in [[], [79], [101], [80, 80], [100, 80], Array(repeating: 80, count: 22)] {
            XCTAssertNil(NativeChargeReadFailure(supportedTargets: targets))
        }
        XCTAssertEqual(NativeChargeReadFailure(supportedTargets: [100])?.supportedTargets, [100])
        XCTAssertEqual(NativeChargeReadFailure(supportedTargets: Array(80...100))?.supportedTargets, Array(80...100))
    }

    func testEveryValidIntegralTargetRemainsAvailableWithoutCoercingMetadata() throws {
        let failure = try XCTUnwrap(PowerUIChargeClient.readError(bridgeError(targets: Array(80...100))) as? NativeChargeReadFailure)
        XCTAssertEqual(failure.supportedTargets, Array(80...100))
    }

    private func bridgeError(domain: String = "Tilvero.NativeCharge", code: Int = 5, targets: Any) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "Native charge readback is incomplete or invalid.", "supportedTargets": targets])
    }
}
