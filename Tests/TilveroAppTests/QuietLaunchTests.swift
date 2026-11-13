// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class QuietLaunchTests: XCTestCase {
    func testLaunchStaysInTheMenuBarByDefault() {
        XCTAssertFalse(LaunchPresentation.opensDetailsAtLaunch(arguments: ["Tilvero"]))
        XCTAssertFalse(LaunchPresentation.opensDetailsAtLaunch(arguments: ["Tilvero", "--monitor-only", "--demo"]))
    }

    func testOnlyAnExplicitFlagOpensTheDetailsWindowAtLaunch() {
        XCTAssertTrue(LaunchPresentation.opensDetailsAtLaunch(arguments: ["Tilvero", "--show-details"]))
    }

    func testNoSetupStateCanOpenSettingsAtLaunch() {
        // Setup is reachable from Settings; an unreviewed setup never raises a window by itself.
        XCTAssertFalse(LaunchPresentation.opensDetailsAtLaunch(arguments: []))
    }
}
