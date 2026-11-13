// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

private actor RenderChargeTransport: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 90, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 90)
    }
    func setLimit(_ target: Int) { XCTFail("Rendering never writes") }
    func setEnabled(_ enabled: Bool) { XCTFail("Rendering never writes") }
}

@MainActor final class QuickChargeRenderTests: XCTestCase {
    func testValidationNeedsPowerButAnAdmittedLimitDoesNot() {
        XCTAssertTrue(QuickNativeChargePanel.needsPowerForValidation(admitted: false, onBattery: true))
        XCTAssertFalse(QuickNativeChargePanel.needsPowerForValidation(admitted: false, onBattery: false))
        XCTAssertFalse(QuickNativeChargePanel.needsPowerForValidation(admitted: true, onBattery: true), "Once validated, the limit works on battery power")
    }

    private func model(admitted: Bool, prefs: UserDefaults, root: URL) async -> TilveroModel {
        let native = NativeChargeService(client: RenderChargeTransport(), journalURL: root.appendingPathComponent("native.json"), admitted: admitted)
        await native.refresh()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") }, nativeCharge: native)
        await model.quickPanelWillOpen()
        return model
    }

    func testNativeChargePageUsesTheNewPanelAndHasNoLegacyControls() async throws {
        let suite = "ChargeRender-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let m = await model(admitted: true, prefs: prefs, root: root)
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
        window.orderOut(nil)
    }

    /// Opt-in render of the real page (TILVERO_LOOK_DIR).
    func testRenderChargePage() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] else { throw XCTSkip("render is opt-in") }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, admitted, draft) in [("applied", true, 90), ("changed", true, 95), ("unvalidated", false, 0)] as [(String, Bool, Int)] {
            for language in ["ru"] {
                let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
                defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
                let suite = "ChargeRender-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
                prefs.set(false, forKey: "historyEnabled")
                let m = await model(admitted: admitted, prefs: prefs, root: root)
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
        let suite = "ChargeStable-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let native = NativeChargeService(client: StableChargeTransport(), journalURL: root.appendingPathComponent("native.json"), admitted: true,
                                         batteryProvider: { ChargeObservation(percent: 60, externalPower: true, fresh: true) })
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
        model.applyDemoTarget()
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
    func setEnabled(_ enabled: Bool) {}
}
