// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class OverviewKeepAwakeTests: XCTestCase {
    func testTheQuickStripOffersFifteenThirtySixtyAndTwoFortyMinutes() {
        XCTAssertEqual(OverviewKeepAwake.presets, [15, 30, 60, 240])
        XCTAssertTrue(OverviewKeepAwake.presets.allSatisfy { KeepAwakeDuration(rawValue: $0) != nil })
    }

    func testOnlyATimedSessionNamesItsEnd() {
        let end = Date().addingTimeInterval(3600)
        let text = OverviewKeepAwake.endText(expiry: .until(end), endDate: end)
        XCTAssertTrue(text?.hasPrefix(L10n.text("Until")) == true, "a timed session says when it ends")
        XCTAssertNil(OverviewKeepAwake.endText(expiry: .untilStopped, endDate: nil), "no end: nothing is written")
        XCTAssertNil(OverviewKeepAwake.endText(expiry: .untilStopped, endDate: end), "until stopped never shows an end")
        XCTAssertNil(OverviewKeepAwake.endText(expiry: nil, endDate: nil))
        XCTAssertNil(OverviewKeepAwake.endText(expiry: .until(end), endDate: nil))
    }
}
