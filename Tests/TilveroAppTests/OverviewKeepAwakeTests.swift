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

    func testTheEndIsWrittenAsPlainUntilAndATime() {
        let text = OverviewKeepAwake.untilText(Date().addingTimeInterval(1800))
        XCTAssertTrue(text.hasPrefix(L10n.text("Until") + " "))
        XCTAssertFalse(text.contains(L10n.text("Sleep at")), "a Keep Awake end is not a sleep time")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertTrue(OverviewKeepAwake.untilText(tomorrow).hasSuffix(L10n.text("tomorrow")))
    }

    func testOneNameForKeepAwakeOnOverviewAndTheSleepTab() {
        XCTAssertEqual(L10n.text("Keep Mac Awake"), L10n.text("Keep Awake"))
    }
}
