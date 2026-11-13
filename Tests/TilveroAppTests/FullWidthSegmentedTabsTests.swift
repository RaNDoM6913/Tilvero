// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class FullWidthSegmentedTabsTests: XCTestCase {
    // Replacing either row with an intrinsic-width Picker must fail this test.
    func testBothQuickPanelRowsFillTheSameContentWidthInBothLanguages() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["en", "ru"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging(["language": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            for dark in [false, true] {
                let host = NSHostingView(rootView: QuickPanel(model: fixture.model, section: .awake)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: QuickPanelMetrics.width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.orderOut(nil) }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                let controls = descendants(host).compactMap { $0 as? NSSegmentedControl }
                let upper = try XCTUnwrap(controls.first { $0.segmentCount == 4 })
                let lower = try XCTUnwrap(controls.first { $0.segmentCount == 2 })
                for control in [upper, lower] {
                    let frame = control.convert(control.bounds, to: host)
                    print("tab-geometry \(language) \(dark ? "dark" : "light") segments=\(control.segmentCount) frame=\(frame)")
                    XCTAssertEqual(frame.width, QuickPanelMetrics.width - 2 * QuickPanelMetrics.padding, accuracy: 0.5, "The native tabs must fill the panel's padded content width.")
                    XCTAssertEqual(frame.minX, QuickPanelMetrics.padding, accuracy: 0.5)
                    XCTAssertEqual(control.segmentDistribution, .fillEqually)
                    XCTAssertEqual(control.controlSize, .regular)
                }
                XCTAssertEqual(upper.frame.height, lower.frame.height, accuracy: 0.5)
                XCTAssertEqual(upper.selectedSegment, 1)
                XCTAssertEqual(lower.selectedSegment, 0)
            }
        }
    }

    func testTypedTabActionsKeepTheirBindingsIndependentAndRespectDisabledState() async throws {
        var section = QuickPanelSection.overview
        var page = SleepPage.timer
        let view = VStack {
            QuickPanelTabs(selection: Binding(get: { section }, set: { section = $0 }))
            CompactSleepTabs(selection: Binding(get: { page }, set: { page = $0 }))
        }.frame(width: 320)
        let host = NSHostingView(rootView: view.disabled(false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let controls = descendants(host).compactMap { $0 as? NSSegmentedControl }
        let upper = try XCTUnwrap(controls.first { $0.segmentCount == 4 })
        let lower = try XCTUnwrap(controls.first { $0.segmentCount == 2 })
        XCTAssertEqual(upper.accessibilityIdentifier(), "quick.tabs")
        XCTAssertEqual(lower.accessibilityIdentifier(), "sleep.tabs")
        XCTAssertEqual(upper.accessibilityLabel(), L10n.text("Battery menu"))
        XCTAssertEqual(lower.accessibilityLabel(), L10n.text("Sleep"))
        XCTAssertTrue(upper.acceptsFirstResponder)
        XCTAssertTrue(lower.acceptsFirstResponder)
        // Tab order: Overview, Sleep, Charge, Modes. The last pick is Sleep, which the rest of the test continues from.
        for (index, expected) in [(0, QuickPanelSection.overview), (2, .charge), (3, .modes), (1, .awake)] {
            upper.selectedSegment = index
            XCTAssertTrue(upper.sendAction(upper.action, to: upper.target))
            XCTAssertEqual(section, expected)
            XCTAssertEqual(page, .timer)
        }
        lower.selectedSegment = 1
        XCTAssertTrue(lower.sendAction(lower.action, to: lower.target))
        XCTAssertEqual(page, .awake)
        XCTAssertEqual(section, .awake)
        lower.selectedSegment = -1
        _ = lower.sendAction(lower.action, to: lower.target)
        XCTAssertEqual(page, .awake, "An absent native selection must not overwrite the typed route.")
        host.rootView = view.disabled(true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(upper.isEnabled)
        XCTAssertFalse(lower.isEnabled)
        upper.selectedSegment = 0
        lower.selectedSegment = 0
        _ = upper.sendAction(upper.action, to: upper.target)
        _ = lower.sendAction(lower.action, to: lower.target)
        XCTAssertEqual(section, .awake)
        XCTAssertEqual(page, .awake, "A disabled native control must not change the page even if an action is delivered.")
    }

    func testFullSleepSurfaceRetainsReportsDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.selectedSleepPage = .reports
        let host = NSHostingView(rootView: SleepControlsPanel(model: fixture.model).frame(width: 560))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let tabs = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
        XCTAssertEqual(tabs.label(forSegment: 2), L10n.text("Reports"))
        XCTAssertEqual(tabs.selectedSegment, 2)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor private struct Fixture {
        let suite = "TilveroTabs-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: UserDefaults
        let model: TilveroModel
        init() throws {
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set(false, forKey: "historyEnabled")
            model = TilveroModel(isDemo: true, preferences: preferences,
                historyURL: directory.appendingPathComponent("History.sqlite"),
                snapshotProvider: { .unavailable(reason: "Tab geometry fixture — no hardware") })
        }
        func cleanUp() {
            model.stop()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
