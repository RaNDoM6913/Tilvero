// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class AppNavigationTests: XCTestCase {
    func testNavigateSelectsTheSectionAndItsPageAndRemembersOnlyTheSection() {
        let prefs = makeTestDefaults("Navigation").defaults
        let navigation = AppNavigation(preferences: prefs)
        XCTAssertEqual(navigation.section, .overview, "A first launch starts on Overview")
        navigation.navigate(to: .settings(.updates))
        XCTAssertEqual(navigation.section, .settings)
        XCTAssertEqual(navigation.settingsPage, .updates)
        navigation.navigate(to: .sleep(.awake))
        XCTAssertEqual(navigation.section, .sleep)
        XCTAssertEqual(navigation.sleepPage, .awake)
        navigation.navigate(to: .section(.settings))
        XCTAssertEqual(navigation.settingsPage, .updates, "A plain section keeps the page the user left it on")

        let relaunched = AppNavigation(preferences: prefs)
        XCTAssertEqual(relaunched.section, .settings, "The section is remembered across launches")
        XCTAssertEqual(relaunched.settingsPage, .general, "Sub-pages start on their first page")
        XCTAssertEqual(relaunched.sleepPage, .timer)
    }

    func testOpenPresentsTheWindowAfterSelectingAndSectionChangesAreReportedOnce() {
        let navigation = AppNavigation(preferences: makeTestDefaults("Navigation").defaults)
        var changes: [String] = []
        var presentedOn: [InfoSection] = []
        navigation.onSectionChange = { old, new in changes.append("\(old.rawValue)→\(new.rawValue)") }
        navigation.presentDetails = { presentedOn.append(navigation.section) }
        navigation.open(.section(.diagnostics))
        navigation.open(.section(.diagnostics))
        navigation.navigate(to: .sleep(.reports))
        navigation.openDetails()
        XCTAssertEqual(changes, ["overview→diagnostics", "diagnostics→sleep"], "Re-selecting the same section is not a change")
        XCTAssertEqual(presentedOn, [.diagnostics, .diagnostics, .sleep], "The window is shown on the page that was just selected")
    }

    func testTheModelRoutesSetupAndUpdateDiagnosticsThroughTheNavigation() {
        let prefs = makeTestDefaults("Navigation").defaults
        prefs.set(InfoSection.history.rawValue, forKey: AppNavigation.lastSectionKey)
        let model = TilveroModel(isDemo: true, preferences: prefs)
        defer { model.stop() }
        XCTAssertEqual(model.navigation.section, .history, "The model restores the remembered section")
        var opened = 0
        model.navigation.presentDetails = { opened += 1 }
        model.openUpdateDiagnostics()
        XCTAssertEqual(model.navigation.section, .diagnostics)
        XCTAssertEqual(opened, 1)
        model.selectedSleepPage = .reports
        XCTAssertEqual(model.navigation.sleepPage, .reports, "The model's conveniences forward to the navigation")
    }
}
