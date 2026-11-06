// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class AppInstancePolicyTests: XCTestCase {
    func testOnlySameResolvedBundleCanReopenSilently() {
        let canonical = URL(fileURLWithPath: "/tmp/Tilvero.app")
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: canonical), .reopen)
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: URL(fileURLWithPath: "/tmp/rejected/Tilvero.app")), .requireSwitch)
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: nil), .requireSwitch)
    }
}
