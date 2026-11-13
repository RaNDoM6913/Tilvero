// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import ComfortBackends

final class ComfortBackendsTests: XCTestCase {
    func testBuiltInResolutionPicksExactlyOne() throws {
        XCTAssertEqual(try DisplayBrightnessRules.resolveBuiltIn(online: [3, 1], isBuiltIn: { $0 == 1 }, remembered: nil), 1)
    }
    func testBuiltInResolutionUsesRememberedWhenPanelLeftTheOnlineList() throws {
        XCTAssertEqual(try DisplayBrightnessRules.resolveBuiltIn(online: [3], isBuiltIn: { _ in false }, remembered: 1), 1)
    }
    func testBuiltInResolutionFailsClosedOnNoneOrSeveral() {
        XCTAssertThrowsError(try DisplayBrightnessRules.resolveBuiltIn(online: [3], isBuiltIn: { _ in false }, remembered: nil)) {
            XCTAssertEqual($0 as? ComfortBackendError, .noBuiltInDisplay)
        }
        XCTAssertThrowsError(try DisplayBrightnessRules.resolveBuiltIn(online: [1, 2], isBuiltIn: { _ in true }, remembered: 1))
    }
    func testBrightnessReadingValidation() throws {
        XCTAssertEqual(try DisplayBrightnessRules.validate(reading: 0.5, status: 0), 0.5, accuracy: 1e-6)
        XCTAssertThrowsError(try DisplayBrightnessRules.validate(reading: 0.5, status: -1))
        XCTAssertThrowsError(try DisplayBrightnessRules.validate(reading: .nan, status: 0))
        XCTAssertThrowsError(try DisplayBrightnessRules.validate(reading: 1.5, status: 0))
        XCTAssertThrowsError(try DisplayBrightnessRules.validate(reading: -0.1, status: 0))
    }
    func testWriteTargetValidation() throws {
        XCTAssertEqual(try DisplayBrightnessRules.validate(target: 0), 0)
        XCTAssertThrowsError(try DisplayBrightnessRules.validate(target: 1.2))
        XCTAssertThrowsError(try OutputVolumeRules.validate(target: .infinity))
        XCTAssertThrowsError(try OutputVolumeRules.validate(reading: .nan))
        XCTAssertEqual(try OutputVolumeRules.validate(reading: 0.50000006), 0.5, accuracy: 1e-6)
    }
    func testNoNativeCallAtConstruction() {
        _ = NativeDisplayBrightnessTransport(); _ = NativeOutputVolumeTransport()
    }
}
