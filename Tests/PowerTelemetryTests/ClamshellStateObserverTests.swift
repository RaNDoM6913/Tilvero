// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import CoreFoundation
@testable import PowerTelemetry

final class ClamshellStateObserverTests: XCTestCase {
    func testDecodesRegistryBooleans() {
        let closed = ClamshellSample.decode(lidClosed: kCFBooleanTrue, causesSleep: kCFBooleanTrue)
        XCTAssertTrue(closed.closedAndWouldSleep); XCTAssertFalse(closed.isOpen)
        let open = ClamshellSample.decode(lidClosed: kCFBooleanFalse, causesSleep: kCFBooleanTrue)
        XCTAssertTrue(open.isOpen); XCTAssertFalse(open.closedAndWouldSleep)
    }
    func testClosedWithExternalDisplayDoesNotCauseSleep() {
        let sample = ClamshellSample.decode(lidClosed: kCFBooleanTrue, causesSleep: kCFBooleanFalse)
        XCTAssertEqual(sample.lidClosed, true); XCTAssertFalse(sample.closedAndWouldSleep)
    }
    func testMissingOrNonBooleanKeysAreUnreadable() {
        let missing = ClamshellSample.decode(lidClosed: nil, causesSleep: nil)
        XCTAssertNil(missing.lidClosed); XCTAssertNil(missing.causesSleep)
        XCTAssertFalse(missing.closedAndWouldSleep); XCTAssertFalse(missing.isOpen)
        let numbers = ClamshellSample.decode(lidClosed: 1 as CFNumber, causesSleep: "Yes" as CFString)
        XCTAssertNil(numbers.lidClosed); XCTAssertNil(numbers.causesSleep)
    }
    func testOnlyTheLidMessageTriggersAResample() {
        XCTAssertTrue(ClamshellStateObserver.shouldResample(message: ClamshellStateObserver.stateChangeMessage))
        XCTAssertFalse(ClamshellStateObserver.shouldResample(message: 0))
        XCTAssertFalse(ClamshellStateObserver.shouldResample(message: ClamshellStateObserver.stateChangeMessage + 1))
    }
    func testCurrentSampleIsReadOnlyAndDoesNotCrash() {
        _ = ClamshellStateObserver.currentSample()
    }
}
