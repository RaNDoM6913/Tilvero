// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class SteadyControlLookTests: XCTestCase {
    /// Regression (2026-11-13): "Charge to 100% once" and the time pill blinked on every limit change because the busy flags of
    /// the apply dimmed them. Busy must ignore taps and leave the look alone.
    func testBusyNeverChangesTheLook() {
        let idle = SteadyControlLook(offered: true, busy: false)
        let busy = SteadyControlLook(offered: true, busy: true)
        XCTAssertEqual(idle.opacity, busy.opacity)
        XCTAssertTrue(idle.acceptsTaps)
        XCTAssertFalse(busy.acceptsTaps)
    }
    func testNotOfferedIsDimmedAndInert() {
        let off = SteadyControlLook(offered: false, busy: false)
        XCTAssertEqual(off.opacity, 0.45)
        XCTAssertFalse(off.acceptsTaps)
        XCTAssertEqual(SteadyControlLook(offered: false, busy: true, dimmedOpacity: 0.6).opacity, 0.6)
    }
}
