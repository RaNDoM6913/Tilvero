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

    /// The single exception: the first-run window, only for a fresh install's very first ordinary launch.
    func testTheFirstRunWindowIsTheOnlyExceptionAndNeverReturns() {
        let fresh = FirstRunSignals()
        XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero"], firstRun: FirstRunDecision.decide(signals: fresh, context: .init())), .firstRun)
        var second = fresh; second.introduced = true
        var updated = fresh; updated.historyStoreExists = true; updated.historyPreferenceStored = true
        let quiet: [(FirstRunSignals, FirstRunLaunchContext)] = [
            (second, .init()),                                   // second launch
            (fresh, .init(launchedAsLoginItem: true)),           // login launch
            (updated, .init()),                                  // post-Sparkle relaunch of an existing user
            (fresh, .init(isDemo: true)), (fresh, .init(monitoringOnly: true)),
        ]
        for (signals, context) in quiet {
            XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero"], firstRun: FirstRunDecision.decide(signals: signals, context: context)), .none, "\(context)")
        }
    }
}
