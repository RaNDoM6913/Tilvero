// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp
import PowerCore

@MainActor
final class QuickPanelLayoutTests: XCTestCase {
    func testLivePanelFitsItsContentInsteadOfReservingOldBlankTail() async throws {
        let fixture = try Fixture(isDemo: false)
        defer { fixture.cleanUp() }
        await fixture.model.refresh()
        let host = NSHostingController(rootView: QuickPanel(model: fixture.model))
        let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 1000))
        print("Live overview fitted size: \(size)")
        XCTAssertEqual(size.width, QuickPanelMetrics.width, accuracy: 1)
        XCTAssertLessThan(size.height, 620, "Forecast and real history may grow the overview; its height still follows content and remains screen-bounded.")
        XCTAssertGreaterThan(size.height, 180)
    }

    func testRussianPendingChargeFitsCompactDesignWithoutExplanatoryTail() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, value in value }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let fixture = try Fixture(isDemo: true); defer { fixture.cleanUp() }
        fixture.model.demoPercent = 98
        await fixture.model.refresh()
        fixture.model.setDraft(80); fixture.model.applyDemoTarget()
        for _ in 0..<100 where fixture.model.isApplying { await Task.yield() }
        let host = NSHostingController(rootView: QuickPanel(model: fixture.model, maximumHeight: 1000, section: .charge))
        let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 1200))
        print("Russian pending charge natural height: \(size.height)")
        XCTAssertLessThanOrEqual(size.height, 470, "The quick charge surface needs state and actions without an explanatory tail")
        XCTAssertEqual(fixture.model.control?.charge.pendingTarget, 80)
        XCTAssertEqual(fixture.model.control?.charge.appliedTarget, 100)
    }

    func testLongPendingChargeContentIsScreenBoundedAndScrollable() async throws {
        let fixture = try Fixture(isDemo: true)
        defer { fixture.cleanUp() }
        fixture.model.demoPercent = 98
        await fixture.model.refresh()
        fixture.model.setDraft(80)
        fixture.model.applyDemoTarget()
        for _ in 0..<100 where fixture.model.isApplying { await Task.yield() }
        XCTAssertEqual(fixture.model.pendingTarget, 80)
        let host = NSHostingController(rootView: QuickPanel(model: fixture.model, maximumHeight: 240, section: .charge))
        let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 1000))
        XCTAssertEqual(size.width, QuickPanelMetrics.width, accuracy: 1)
        XCTAssertLessThanOrEqual(size.height, 240)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(size)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(scroll.contentView.documentRect.height, scroll.contentView.bounds.height,
                             "Pending-target warnings and footer must remain reachable by scrolling.")
    }

    func testExistingHostResizesAfterPendingWarningAndScreenCapChanges() async throws {
        let fixture = try Fixture(isDemo: true)
        defer { fixture.cleanUp() }
        fixture.model.demoPercent = 98
        await fixture.model.refresh()
        let host = QuickPanelHostingController(model: fixture.model, maximumHeight: 900, section: .charge)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initialHeight = host.preferredContentSize.height
        var reports: [NSSize] = []
        host.onSizeChange = { size in
            reports.append(size)
            window.setContentSize(size)
        }
        fixture.model.setDraft(80)
        fixture.model.applyDemoTarget()
        for _ in 0..<100 where fixture.model.isApplying { await Task.yield() }
        try await settle(host)
        XCTAssertGreaterThan(host.preferredContentSize.height, initialHeight,
                             "The existing host must expand for a pending target without replacing its editor.")
        XCTAssertFalse(reports.isEmpty, "The popover owner must receive a size change after content updates.")
        host.updateMaximumHeight(240)
        XCTAssertLessThanOrEqual(host.preferredContentSize.height, 240)
        host.updateMaximumHeight(900)
        XCTAssertGreaterThan(host.preferredContentSize.height, 240)
    }

    func testScreenCapKeepsTheSelectedSleepPageInTheSameContentTree() async throws {
        let fixture = try Fixture(isDemo: true)
        defer { fixture.cleanUp() }
        let host = QuickPanelHostingController(model: fixture.model, maximumHeight: 900, section: .awake)
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        host.onSizeChange = { window.setContentSize($0) }
        window.setContentSize(host.preferredContentSize)
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutSubtreeIfNeeded()
        let tabs = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        tabs.selectedSegment = 1
        XCTAssertTrue(tabs.sendAction(tabs.action, to: tabs.target))
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(tabs.selectedSegment, 1)

        host.updateMaximumHeight(240)
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutSubtreeIfNeeded()
        let cappedTabs = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 })
        XCTAssertTrue(cappedTabs === tabs, "Introducing scrolling must not replace the active Sleep editor or its local disclosure state.")
        XCTAssertEqual(cappedTabs.selectedSegment, 1, "The viewport cap must preserve the selected Awake page.")
        XCTAssertLessThanOrEqual(host.preferredContentSize.height, 240)
        XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(fixture.model.sleepTimer.isActive)
    }

    func testRussianChargeAndModesFitWidthWithoutUnboundedHeight() async throws {
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": "ru"]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain) }
        let fixture = try Fixture(isDemo: false)
        defer { fixture.cleanUp() }
        fixture.model.language = "ru"
        XCTAssertEqual(L10n.language, "ru")
        for section in [QuickPanelSection.charge, .modes] {
            let host = NSHostingController(rootView: QuickPanel(model: fixture.model, maximumHeight: 280, section: section))
            let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 1000))
            XCTAssertEqual(size.width, QuickPanelMetrics.width, accuracy: 1)
            XCTAssertLessThanOrEqual(size.height, 280)
            XCTAssertGreaterThan(size.height, 180)
        }
    }

    func testNativeSegmentChangeResizesSameHostAndKeepsChargeActionsInsidePanel() async throws {
        let fixture = try Fixture(isDemo: true)
        defer { fixture.cleanUp() }
        await fixture.model.refresh()
        fixture.model.setDraft(90)
        var openedDetails = false
        fixture.model.openDetails = { openedDetails = true }
        let host = QuickPanelHostingController(model: fixture.model, maximumHeight: 900)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let oldHeight = host.preferredContentSize.height
        var reported: NSSize?
        host.onSizeChange = { size in reported = size; window.setContentSize(size) }
        let segments = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(segments.segmentCount, 4)
        segments.selectedSegment = 2   // Charge: the tabs are Overview, Sleep, Charge, Modes
        _ = segments.sendAction(segments.action, to: segments.target)
        try await settle(host)
        XCTAssertNotEqual(host.preferredContentSize.height, oldHeight)
        XCTAssertNotNil(reported, "A tab change must resize the existing popover.")
        let views = descendants(of: host.view)
        // macOS 27 draws SwiftUI sliders in the host instead of creating an
        // NSSlider descendant. Check the visible editor and shared draft contract;
        // actual slider and Apply accessibility actions require the native Lab.
        if #unavailable(macOS 27) {
            XCTAssertFalse(views.compactMap { $0 as? NSSlider }.isEmpty,
                           "Charge controls belong to the selected quick-panel tab.")
        }
        let percentage = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.stringValue == fixture.model.draftText
        }, "The selected Charge tab must contain its editable percentage field.")
        XCTAssertEqual(percentage.stringValue, "90")
        XCTAssertEqual(segments.selectedSegment, 2)
        XCTAssertTrue(fixture.model.canEdit)
        XCTAssertTrue(fixture.model.canApply)
        XCTAssertEqual(fixture.model.sliderIndex, Double(try XCTUnwrap(fixture.model.acceptedTargets.firstIndex(of: 90))))
        XCTAssertFalse(openedDetails, "A segment switch must keep the owner in the quick panel.")
    }

    /// The page area changes height on a spring (about a third of a second); wait until the reported size is stable.
    private func settle(_ host: QuickPanelHostingController) async throws {
        var previous: CGFloat = -1, stable = 0
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutSubtreeIfNeeded()
            let height = host.preferredContentSize.height
            stable = abs(height - previous) < 0.01 ? stable + 1 : 0
            previous = height
            if stable >= 6 { return }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private struct Fixture {
        let model: TilveroModel
        let preferences: UserDefaults
        let suite: String
        let directory: URL
        init(isDemo: Bool) throws {
            suite = "TilveroPanelLayoutTests.\(UUID().uuidString)"
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set(false, forKey: "historyEnabled")
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            model = TilveroModel(isDemo: isDemo, preferences: preferences,
                                 historyURL: directory.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "Layout fixture — no hardware read") })
        }
        func cleanUp() {
            model.stop()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
