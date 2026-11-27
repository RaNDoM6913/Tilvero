// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

/// What the real views draw for the charge limit, read from `RenderProbe` (the text each `StudioText` drew), not from a
/// helper's result: "—" on the quick Charge page and the window tile when macOS has not reported a value, the reported
/// target on the Overview capsule after an incomplete read, and a lapsed value that keeps the page's layout. Fixture
/// transport only; nothing is written.
@MainActor final class ChargeLimitReadoutRenderTests: XCTestCase {
    override func tearDown() { RenderProbe.isEnabled = false; RenderProbe.reset(); super.tearDown() }

    /// Hosts `view`, lets it draw, and returns the texts its `StudioText`s drew.
    private func drawnTexts<V: View>(_ view: V, width: CGFloat) async throws -> [String: String] {
        try await drawn(view, width: width).texts
    }

    /// Hosts `view`, lets it draw, and returns the texts it drew and whether each readout was drawn as held (primary) or
    /// dimmed.
    private func drawn<V: View>(_ view: V, width: CGFloat) async throws -> (texts: [String: String], held: [String: Bool]) {
        RenderProbe.isEnabled = true; RenderProbe.reset()
        let host = NSHostingController(rootView: view.frame(width: width))
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(host.sizeThatFits(in: NSSize(width: width, height: 1200))); host.view.layoutSubtreeIfNeeded()
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        let result = (texts: RenderProbe.texts, held: RenderProbe.heldReadouts)
        RenderProbe.isEnabled = false; RenderProbe.reset()
        return result
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A write whose outcome is unknown (its setter past the deadline): nothing is known, so both editors draw "—", never
    /// an empty readout or a guessed number.
    func testBothEditorsDrawADashWhenMacOSHasNotReportedAValue() async throws {
        let f = ScopeFixture(initialTarget: 90); defer { f.cleanup() }
        let service = f.makeService(operationTimeout: .milliseconds(150))
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let known = try await drawnTexts(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(known["charge.readout"], "90", "the probe reads the drawn readout")
        await f.client.holdWrites()
        model.releaseChargeLimit(at: 85)
        await waitUntil { await f.client.isHoldingWrite }
        await waitUntil { !model.isApplying }   // the gate deadline passed: nothing fresh is known
        XCTAssertNil(ChargeLimitKit.reported(model))
        XCTAssertEqual(ChargeLimitKit.mode(model), .unavailable)
        let quick = try await drawnTexts(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(quick["charge.readout"], "—", "the quick Charge page")
        let window = try await drawnTexts(ChargingPage(model: model), width: 800)
        XCTAssertEqual(window["charging.readout"], "—", "the window's Charging tile")
        await f.client.releaseWrite()
        await waitUntil { !service.operationPending }
        await f.assertWrites(["limit85"])
    }

    /// An incomplete read after the grant (a state Tilvero does not recognise, its current target readable): the Overview
    /// capsule draws the reported target, as the Charge page does, not "—".
    func testTheOverviewCapsuleDrawsTheReportedTargetOfAnIncompleteRead() async throws {
        let f = ScopeFixture(initialTarget: 90); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let fresh = try await drawnTexts(OverviewHero(model: model, openCharge: {}), width: QuickPanelMetrics.width)
        XCTAssertEqual(fresh["quick.charge.limit.value"], "90%")
        await f.client.setMode("unknown")   // rawManualState 3, current target 100
        await model.refreshNativeCharge()
        XCTAssertNil(service.presentation().currentPreference)
        let incomplete = try await drawnTexts(OverviewHero(model: model, openCharge: {}), width: QuickPanelMetrics.width)
        XCTAssertEqual(incomplete["quick.charge.limit.value"], "100%", "the capsule agrees with the page")
        let page = try await drawnTexts(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(page["charge.readout"], "100")
        await f.assertWrites([])
    }

    /// The Mac slept and the last valid value lapsed: the Charge page draws that value (dimmed) in the slider layout, and
    /// the read that confirms it does not resize the open menu (no read-only layout, note or status line in between).
    func testALapsedValueKeepsTheChargePageLayoutUntilTheReadConfirmsIt() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await f.client.setMode("agingSoon")
        await model.refreshNativeCharge()   // also stamps the panel's own read as recent: opening it reads nothing more
        await waitUntil { service.reportedLimit == nil }
        XCTAssertTrue(service.settingLapsed)
        let lapsed = try await drawnTexts(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(lapsed["charge.readout"], "85", "the last value macOS reported, not «—» in a read-only layout")
        let host = QuickPanelHostingController(model: model, maximumHeight: 900, section: .charge)
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(host.preferredContentSize); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(service.settingLapsed, "still lapsed while the menu is open")
        var heights: [CGFloat] = []
        host.onSizeChange = { size in heights.append(size.height); window.setContentSize(size) }
        await f.client.setMode("")
        await model.refreshNativeCharge()
        for _ in 0..<12 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertTrue(ChargeLimitKit.isConfirmed(model))
        XCTAssertTrue(heights.isEmpty, "the read that confirms a lapsed value must not resize the open menu: \(heights)")
        await f.assertWrites([])
    }

    /// A lapsed value is drawn dimmed on the quick Charge page and on the window's Charging tile, never as the value macOS
    /// holds now; the read that confirms it draws it as held on both.
    func testALapsedValueIsDrawnDimmedOnBothEditors() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await f.client.setMode("agingSoon")
        await model.refreshNativeCharge()
        await waitUntil { service.reportedLimit == nil }
        XCTAssertTrue(service.settingLapsed)
        let quick = try await drawn(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(quick.texts["charge.readout"], "85")
        XCTAssertEqual(quick.held["charge.readout"], false, "the quick Charge page dims a lapsed value")
        let window = try await drawn(ChargingPage(model: model), width: 800)
        XCTAssertEqual(window.texts["charging.readout"], "85")
        XCTAssertEqual(window.held["charging.readout"], false, "the window's Charging tile dims a lapsed value")
        await f.client.setMode("")
        await model.refreshNativeCharge()
        let quickConfirmed = try await drawn(QuickNativeChargePanel(model: model), width: QuickPanelMetrics.width)
        XCTAssertEqual(quickConfirmed.texts["charge.readout"], "85")
        XCTAssertEqual(quickConfirmed.held["charge.readout"], true, "confirmed: drawn as held")
        let windowConfirmed = try await drawn(ChargingPage(model: model), width: 800)
        XCTAssertEqual(windowConfirmed.texts["charging.readout"], "85")
        XCTAssertEqual(windowConfirmed.held["charging.readout"], true, "confirmed: drawn as held")
        await f.assertWrites([])
    }

    /// The level picked in the charge-by strip survives a lapsed limit (the Mac slept, the next read is due): neither a
    /// page left open nor a menu opened meanwhile resets the user's choice, and the read keeps it.
    func testTheChargeByLevelPickedSurvivesALapsedLimit() async throws {
        let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        model.chargeBy.draftTarget = 90
        // A page left open across the sleep.
        let width = QuickPanelMetrics.width
        let host = NSHostingController(rootView: QuickNativeChargePanel(model: model).frame(width: width))
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(host.sizeThatFits(in: NSSize(width: width, height: 1200)))
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(model.chargeBy.draftTarget, 90)
        await f.client.setMode("agingSoon")
        await model.refreshNativeCharge()
        await waitUntil { service.reportedLimit == nil }
        XCTAssertTrue(ChargeLimitKit.showsChargeBy(model, armed: false), "the block is drawn while the limit lapsed")
        model.chargeBy.objectWillChange.send()   // anything that redraws the open page while the limit is unknown
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(model.chargeBy.draftTarget, 90, "a page left open keeps the choice")
        // A menu opened while the limit is unknown.
        _ = try await drawnTexts(QuickNativeChargePanel(model: model), width: width)
        XCTAssertEqual(model.chargeBy.draftTarget, 90, "a menu opened meanwhile keeps the choice")
        await f.client.setMode("")
        await model.refreshNativeCharge()
        _ = try await drawnTexts(QuickNativeChargePanel(model: model), width: width)
        XCTAssertEqual(model.chargeBy.draftTarget, 90, "the read keeps it: 90 is above the limit")
        await f.assertWrites([])
    }
}
