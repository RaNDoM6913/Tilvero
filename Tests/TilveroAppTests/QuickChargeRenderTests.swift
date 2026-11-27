// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

private actor RenderChargeTransport: NativeChargeTransport {
    /// false: macOS offers no 95, a level set Tilvero does not change (the value is still shown).
    let recognised: Bool
    init(recognised: Bool = true) { self.recognised = recognised }
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 90, optimizedCharging: true),
              supportedTargets: recognised ? [80, 85, 90, 95, 100] : [80, 85, 90, 100], registeredManualLimit: 90)
    }
    func setLimit(_ target: Int) { XCTFail("Rendering never writes") }
}

@MainActor final class QuickChargeRenderTests: XCTestCase {
    /// A native limit Tilvero cannot change right now shows what macOS reports, read-only, with no validation button.
    func testANotAdmittedLimitRendersTheReportedValueWithoutAButton() async throws {
        let suite = TestDefaults.name("ChargeRender"), prefs = TestDefaults.defaults(suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let m = await model(recognised: false, prefs: prefs, root: root)
        defer { m.stop() }
        XCTAssertEqual(ChargeLimitKit.mode(m), .unavailable)
        XCTAssertEqual(ChargeLimitKit.reported(m), 90)
        XCTAssertFalse(m.nativeCharge.admitted)
        XCTAssertFalse(m.nativeCharge.notReadYet, "the note is shown (not the quiet first-launch state)")
        // Read-only: nothing to act on, so no dimmed charge-once pill or charge-by block (no dead controls).
        XCTAssertFalse(ChargeLimitKit.showsChargeOnce(m))
        XCTAssertFalse(ChargeLimitKit.showsChargeBy(m, armed: false))
        XCTAssertTrue(ChargeLimitKit.showsChargeBy(m, armed: true), "an armed plan keeps its cancel")
        let host = NSHostingController(rootView: QuickPanel(model: m, section: .charge).frame(width: 360))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(host.view.fittingSize.height, 0)
        window.orderOut(nil)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TilveroApp/ChargeLimitKit.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("qualifyNativeCharge"), "no validation entry on any surface")
    }

    private func model(recognised: Bool, prefs: UserDefaults, root: URL) async -> TilveroModel {
        let native = NativeChargeService(client: RenderChargeTransport(recognised: recognised), journalURL: root.appendingPathComponent("native.json"))
        await native.refresh()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") }, nativeCharge: native)
        await model.quickPanelWillOpen()
        return model
    }

    func testNativeChargePageUsesTheNewPanelAndHasNoLegacyControls() async throws {
        let suite = TestDefaults.name("ChargeRender"), prefs = TestDefaults.defaults(suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let m = await model(recognised: true, prefs: prefs, root: root)
        defer { m.stop() }
        m.setDraft(95)
        let host = NSHostingController(rootView: QuickPanel(model: m, section: .charge).frame(width: 360))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let texts = all(host.view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(texts.contains { $0 == "80%" || $0 == "90%" || $0 == "100%" }, "The old preset buttons are gone")
        XCTAssertFalse(texts.contains(L10n.text("Apply")), "There is no Apply button: letting go of the slider applies")
        XCTAssertTrue(m.canApply, "A different draft can be applied")
        // The control for the read-only case: with the slider, the pill and the charge-by block are drawn.
        XCTAssertEqual(ChargeLimitKit.mode(m), .slider)
        XCTAssertTrue(ChargeLimitKit.showsChargeOnce(m))
        XCTAssertTrue(ChargeLimitKit.showsChargeBy(m, armed: false))
        window.orderOut(nil)
    }

    /// Opt-in render of the real page (TILVERO_LOOK_DIR).
    func testRenderChargePage() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] else { throw XCTSkip("render is opt-in") }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, recognised, draft) in [("applied", true, 90), ("changed", true, 95), ("unrecognised", false, 0)] as [(String, Bool, Int)] {
            for language in ["ru"] {
                let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
                defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
                let suite = TestDefaults.name("ChargeRender"), prefs = TestDefaults.defaults(suite)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
                prefs.set(false, forKey: "historyEnabled")
                let m = await model(recognised: recognised, prefs: prefs, root: root)
                defer { m.stop() }
                if draft > 0 { m.setDraft(draft) }
                let host = NSHostingController(rootView: QuickPanel(model: m, section: .charge).frame(width: 360)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                    .environment(\.controlActiveState, .key).environment(\.locale, L10n.locale))
                let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
                window.setContentSize(host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                window.setContentSize(host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-charge-\(name)-\(language).png"))
                window.orderOut(nil)
            }
        }
    }
}

/// The page must not move while the limit is applied: same height before, during and after, no transient text rows.
@MainActor final class QuickChargeStabilityTests: XCTestCase {
    func testChangingTheLimitNeverResizesThePage() async throws {
        let suite = TestDefaults.name("ChargeStable"), prefs = TestDefaults.defaults(suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let native = NativeChargeService(client: StableChargeTransport(), journalURL: root.appendingPathComponent("native.json"))
        await native.refresh()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") }, nativeCharge: native)
        defer { model.stop() }
        await model.quickPanelWillOpen()
        let host = QuickPanelHostingController(model: model, maximumHeight: 900, section: .charge)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        var heights: [CGFloat] = []
        host.onSizeChange = { size in heights.append(size.height); window.setContentSize(size) }
        for target in [85, 100, 80, 95] {
            model.setDraft(target)
            for _ in 0..<12 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        }
        XCTAssertTrue(heights.isEmpty, "Changing the chosen level must not resize the open menu: \(heights)")
        // And the apply itself (pending read, write, readback) must not move the page either.
        model.setDraft(85)
        model.applyDraftTarget()
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(25)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(model.nativeCharge.observed?.configuration.target, 85, "The limit was applied")
        XCTAssertTrue(heights.isEmpty, "Applying must not resize the open menu: \(heights)")
        window.orderOut(nil)
    }
}

/// Stateful and slow enough for the pending states to be on screen.
private actor StableChargeTransport: NativeChargeTransport {
    private var target = 90
    func read() async -> NativeChargeSnapshot {
        try? await Task.sleep(for: .milliseconds(40))
        let off = target == 100
        return .init(configuration: .init(enabled: !off, target: target, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100],
                     registeredManualLimit: off ? nil : target)
    }
    func setLimit(_ target: Int) async { try? await Task.sleep(for: .milliseconds(80)); self.target = target }
}

/// The slider's own choice never outlives the slider: when the menu closes the page shows what macOS holds when it opens
/// again (its state is reused). Fixture transport only.
@MainActor final class ChargeSliderDisappearTests: XCTestCase {
    final class Harness: ObservableObject {
        @Published var visible = true
        var chosen: Int?
    }
    struct HarnessView: View {
        @ObservedObject var harness: Harness
        let model: TilveroModel
        var body: some View {
            VStack {
                if harness.visible {
                    ChargeLimitLevelSlider(model: model, targets: [80, 85, 90, 95, 100],
                                           chosen: Binding(get: { harness.chosen }, set: { harness.chosen = $0 }))
                }
            }.frame(width: 300, height: 80)
        }
    }

    private func host(_ harness: Harness, _ model: TilveroModel) async throws -> (NSWindow, NSHostingController<HarnessView>) {
        let host = NSHostingController(rootView: HarnessView(harness: harness, model: model))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 300, height: 80)); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        return (window, host)
    }

    func testAChoiceThatWasNotLetGoOfIsDroppedWhenTheSliderGoesAway() async throws {
        let f = ScopeFixture(initialTarget: 90); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let harness = Harness()
        let (window, host) = try await host(harness, model)
        defer { window.orderOut(nil) }
        harness.chosen = 85   // shown on the slider, never let go of
        XCTAssertEqual(ChargeLimitKit.shown(chosen: harness.chosen, model: model), 85)
        harness.visible = false   // the menu closes
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertNil(harness.chosen, "reopened, the page shows what macOS holds")
        XCTAssertEqual(ChargeLimitKit.shown(chosen: harness.chosen, model: model), 90)
        await f.assertWrites([])
    }

    func testTheReadoutIsADashWhenNothingIsKnown() {
        XCTAssertEqual(ChargeLimitKit.readout(nil), "—")
        XCTAssertEqual(ChargeLimitKit.readout(85), "85")
    }
}
