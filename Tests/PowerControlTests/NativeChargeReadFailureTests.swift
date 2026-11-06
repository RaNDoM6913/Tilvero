// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import ChargeBackends

final class NativeChargeReadFailureTests: XCTestCase {
    func testUnknownManualStateRetainsIndependentCurrentAndDiagnosticTargets() throws {
        let original = NSError(domain: "Tilvero.NativeCharge", code: 5, userInfo: [
            "supportedTargets": [80, 85, 90, 95, 100],
            "currentTarget": NSNumber(value: 100),
            "rawManualState": NSNumber(value: UInt64(3)),
            "diagnosticStoredTarget": NSNumber(value: 90)
        ])
        let failure = try XCTUnwrap(PowerUIChargeClient.readError(original) as? NativeChargeReadFailure)
        XCTAssertEqual(failure.currentTarget, 100)
        XCTAssertEqual(failure.rawManualState, 3)
        XCTAssertEqual(failure.diagnosticStoredTarget, 90)
        XCTAssertEqual(failure.supportedTargets, [80, 85, 90, 95, 100])
        XCTAssertTrue(failure.isFresh())
    }

    func testInvalidOptionalTargetsAreOmittedWithoutLosingValidObservations() throws {
        let invalid: [Any] = [
            79, 101, 85, NSNumber(value: true), NSNumber(value: 90.5),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity), "90", NSNull(),
            NSDecimalNumber(string: "90.000000000000000001")
        ]
        for key in ["currentTarget", "diagnosticStoredTarget"] {
            for (index, invalidValue) in invalid.enumerated() {
                var metadata: [String: Any] = ["currentTarget": 100, "rawManualState": UInt64(3), "diagnosticStoredTarget": 90]
                metadata[key] = invalidValue
                let failure = try XCTUnwrap(PowerUIChargeClient.readError(bridgeError(targets: [80, 90, 100], metadata: metadata)) as? NativeChargeReadFailure)
                XCTAssertEqual(failure.supportedTargets, [80, 90, 100], "\(key) case \(index)")
                XCTAssertEqual(failure.rawManualState, 3, "\(key) case \(index)")
                XCTAssertEqual(failure.currentTarget, key == "currentTarget" ? nil : 100, "\(key) case \(index)")
                XCTAssertEqual(failure.diagnosticStoredTarget, key == "diagnosticStoredTarget" ? nil : 90, "\(key) case \(index)")
            }
        }
    }

    func testInvalidOptionalRawManualStateIsOmittedWithoutCoercionOrOverflow() throws {
        let invalid: [Any] = [
            -1, NSNumber(value: true), "3", NSNull(), NSNumber(value: 3.5),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: Double(UInt64.max)), NSDecimalNumber(string: "18446744073709551616"),
            NSDecimalNumber(string: "3.000000000000000001")
        ]
        for (index, raw) in invalid.enumerated() {
            let failure = try XCTUnwrap(PowerUIChargeClient.readError(bridgeError(targets: [80, 90, 100], metadata: [
                "currentTarget": 100, "rawManualState": raw, "diagnosticStoredTarget": 90
            ])) as? NativeChargeReadFailure)
            XCTAssertNil(failure.rawManualState, "raw case \(index)")
            XCTAssertEqual(failure.currentTarget, 100, "raw case \(index)")
            XCTAssertEqual(failure.diagnosticStoredTarget, 90, "raw case \(index)")
        }
    }

    func testRawManualStateRetainsUnsignedExtremesAndExactNumericValues() throws {
        let valid: [(NSNumber, UInt64)] = [
            (NSNumber(value: UInt64(0)), 0), (NSNumber(value: UInt64(3)), 3),
            (NSNumber(value: UInt64.max), UInt64.max), (NSNumber(value: 3.0), 3),
            (NSDecimalNumber(string: "18446744073709551615"), UInt64.max)
        ]
        for (raw, expected) in valid {
            let failure = try XCTUnwrap(PowerUIChargeClient.readError(bridgeError(targets: [80, 100], metadata: ["rawManualState": raw])) as? NativeChargeReadFailure)
            XCTAssertEqual(failure.rawManualState, expected)
            XCTAssertNil(failure.currentTarget)
        }
    }

    func testMissingCurrentTargetNeverUsesDiagnosticOrDefaultTarget() throws {
        let failure = try XCTUnwrap(PowerUIChargeClient.readError(bridgeError(targets: [80, 90, 100], metadata: [
            "rawManualState": UInt64(3), "diagnosticStoredTarget": 90
        ])) as? NativeChargeReadFailure)
        XCTAssertNil(failure.currentTarget)
        XCTAssertEqual(failure.diagnosticStoredTarget, 90)
        XCTAssertFalse(failure.isFresh(at: failure.collectedAt))
        let capabilitiesOnly = try XCTUnwrap(NativeChargeReadFailure(supportedTargets: [80, 100]))
        XCTAssertNil(capabilitiesOnly.currentTarget)
        XCTAssertNil(capabilitiesOnly.rawManualState)
        XCTAssertNil(capabilitiesOnly.diagnosticStoredTarget)
        XCTAssertFalse(capabilitiesOnly.isFresh(at: capabilitiesOnly.collectedAt))
    }

    func testPartialCurrentTargetFreshnessIsBoundedAndDoesNotRefreshDiagnosticSource() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let failure = try XCTUnwrap(NativeChargeReadFailure(supportedTargets: [80, 90, 100], currentTarget: 100,
            rawManualState: 3, diagnosticStoredTarget: 90, collectedAt: now))
        XCTAssertTrue(failure.isFresh(at: now))
        XCTAssertTrue(failure.isFresh(at: now.addingTimeInterval(-5)))
        XCTAssertTrue(failure.isFresh(at: now.addingTimeInterval(65)))
        XCTAssertFalse(failure.isFresh(at: now.addingTimeInterval(-5.01)))
        XCTAssertFalse(failure.isFresh(at: now.addingTimeInterval(65.01)))
        XCTAssertEqual(failure.diagnosticStoredTarget, 90)
        XCTAssertEqual(NativeChargeReadFailure.diagnosticStoredTargetFreshness, "unknown")
    }

    func testTypedFailureRejectsSuppliedTargetsThatAreNotOffered() {
        for target in [79, 85, 101] {
            XCTAssertNil(NativeChargeReadFailure(supportedTargets: [80, 90, 100], currentTarget: target))
            XCTAssertNil(NativeChargeReadFailure(supportedTargets: [80, 90, 100], diagnosticStoredTarget: target))
        }
        XCTAssertNotNil(NativeChargeReadFailure(supportedTargets: [100], currentTarget: 100))
    }

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

    private func bridgeError(domain: String = "Tilvero.NativeCharge", code: Int = 5, targets: Any, metadata: [String: Any] = [:]) -> NSError {
        var userInfo = metadata
        userInfo[NSLocalizedDescriptionKey] = "Native charge readback is incomplete or invalid."
        userInfo["supportedTargets"] = targets
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
}
