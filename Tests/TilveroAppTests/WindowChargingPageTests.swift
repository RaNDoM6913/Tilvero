// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import ChargeBackends
import PowerCore
import PowerPersistence
@testable import TilveroApp

/// The shared limit editor of the quick menu and the window.
private typealias Editor = ChargeLimitKit

/// Native transport that fails the test on any write: rendering the page (and the quick menu beside it) only reads.
private actor ReadOnlyChargeTransport: NativeChargeTransport {
    let target: Int
    init(target: Int) { self.target = target }
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: target, optimizedCharging: false), supportedTargets: [80, 85, 90, 95, 100],
              registeredManualLimit: target)
    }
    func setLimit(_ target: Int) { XCTFail("Rendering never writes") }
    func setEnabled(_ enabled: Bool) { XCTFail("Rendering never writes") }
}

/// In-memory fixture transport (never the Mac's settings) for the "both editors agree after an apply" check.
private actor MemoryChargeTransport: NativeChargeTransport {
    private var target = 90
    func read() -> NativeChargeSnapshot {
        let off = target == 100
        return .init(configuration: .init(enabled: !off, target: target, optimizedCharging: false), supportedTargets: [80, 85, 90, 95, 100],
                     registeredManualLimit: off ? nil : target)
    }
    func setLimit(_ target: Int) { self.target = target }
    func setEnabled(_ enabled: Bool) {}
}

/// A model over a temporary history store (the last hour once a minute) with a native charge service on a fixture
/// transport. Fixture data only; no production preferences, journals or control services.
@MainActor private struct ChargingFixture {
    let model: TilveroModel
    let cleanup: () -> Void

    static func reading(_ id: String, _ value: CatalogValue, at date: Date, provenance: TelemetryProvenance = .measured) -> CatalogReading {
        CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: "fixture", keyPath: "fixture",
                       collectedAt: date, provenance: provenance, availability: .available, freshness: .fresh)
    }

    static func snapshot(at date: Date, level: Int, adapter: Bool) -> BatterySnapshot {
        let base = WindowFixture.snapshot(at: date, level: level, minutesAgo: 0, charging: adapter)
        var catalog = base.catalog.filter { !["054", "050", "070"].contains($0.id) || adapter }
        catalog.append(reading("015", .boolean(adapter), at: date))
        if adapter {
            catalog += [reading("049", .text("USB-C"), at: date), reading("051", .decimal(20), at: date),
                        reading("052", .decimal(4.7), at: date), reading("047", .text("0x7006 · 1.2"), at: date),
                        reading("048", .text("C06XYZ1234"), at: date), reading("045", .text("96W USB-C Power Adapter"), at: date),
                        reading("046", .text("Apple Inc."), at: date), reading("053", .integer(94), at: date),
                        reading("055", .decimal(20.1), at: date), reading("056", .decimal(0.93), at: date)]
        }
        return BatterySnapshot(chargePercent: base.chargePercent, isCharging: base.isCharging, isExternalPower: base.isExternalPower,
                               temperatureCelsius: base.temperatureCelsius, collectedAt: date,
                               catalog: BatteryCatalog.complete(catalog, at: date), monotonicTime: base.monotonicTime,
                               batteryIdentityToken: base.batteryIdentityToken)
    }

    static func make(adapter: Bool = true, level: Int = 72, admitted: Bool = true, nativeTarget: Int = 80,
                     monitoringOnly: Bool = false, transport: (any NativeChargeTransport)? = nil) async throws -> ChargingFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowCharging"), defaults = TestDefaults.defaults(suite)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        for minute in stride(from: 60.0, to: 0, by: -1) {
            try await store.record(WindowFixture.snapshot(at: now.addingTimeInterval(-minute * 60), level: level, minutesAgo: minute, charging: adapter))
        }
        try await store.close()
        let current = snapshot(at: now, level: level, adapter: adapter)
        let native = NativeChargeService(client: transport ?? ReadOnlyChargeTransport(target: nativeTarget),
                                         journalURL: root.appendingPathComponent("native.json"), admitted: admitted,
                                         monitoringOnly: monitoringOnly)
        await native.refresh()
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { current },
                                 systemChargeLimitProvider: { _ in SystemChargeLimitObservation(limits: nil) },
                                 nativeCharge: native, liveSampler: { nil }, newWindow: true, lowPowerMode: { false })
        await model.refresh()
        await model.waitForHistoryWork()
        return ChargingFixture(model: model, cleanup: {
            model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class WindowChargingPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    private func setLanguage(_ language: String, model: TilveroModel? = nil) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model?.language = language
    }

    private let ru = Locale(identifier: "ru_RU")

    // MARK: Editor rules

    func testEditorModes() {
        typealias E = Editor
        XCTAssertEqual(E.mode(isDemo: false, usesNativeCharge: true, canShowControls: true, hasTargets: true), .slider)
        XCTAssertEqual(E.mode(isDemo: false, usesNativeCharge: true, canShowControls: false, hasTargets: false), .unavailable,
                       "found but not changeable now: the reported value, read-only")
        XCTAssertEqual(E.mode(isDemo: false, usesNativeCharge: false, canShowControls: true, hasTargets: true), .readOnly,
                       "no native control or monitoring only: no control")
        XCTAssertEqual(E.mode(isDemo: true, usesNativeCharge: false, canShowControls: true, hasTargets: true), .slider, "DEMO acts on the simulation")
        XCTAssertEqual(E.mode(isDemo: true, usesNativeCharge: false, canShowControls: false, hasTargets: false), .readOnly)
    }

    func testShownLevelPendingAndApplied() {
        typealias E = Editor
        let held = NativeChargeConfiguration(enabled: true, target: 90, optimizedCharging: false)
        let off = NativeChargeConfiguration(enabled: false, target: 100, optimizedCharging: false)
        // The draft is a DEMO-only source (the native path shows what macOS reports: see the model test below).
        XCTAssertEqual(E.shown(chosen: 85, draft: 95, preference: held), 85, "the user's own choice wins while it is applied")
        XCTAssertEqual(E.shown(chosen: nil, draft: 95, preference: held), 95, "DEMO: the simulation's draft")
        XCTAssertEqual(E.shown(chosen: nil, draft: nil, preference: held), 90)
        XCTAssertEqual(E.shown(chosen: nil, draft: nil, preference: off), 100, "limit off reads as 100")
        XCTAssertNil(E.shown(chosen: nil, draft: nil, preference: nil))

        XCTAssertTrue(E.isApplied(shown: 90, current: 90, pendingTarget: nil))
        XCTAssertFalse(E.isApplied(shown: 80, current: 85, pendingTarget: 80), "pending is never drawn as applied")
        XCTAssertFalse(E.isApplied(shown: 80, current: 80, pendingTarget: 80))
        XCTAssertFalse(E.isApplied(shown: 95, current: 90, pendingTarget: nil), "a level still being applied is not applied")
        XCTAssertFalse(E.isApplied(shown: 90, current: nil, pendingTarget: nil), "unknown macOS limit: nothing is claimed")

        XCTAssertNil(E.pendingText(pendingTarget: nil))
        XCTAssertEqual(E.pendingText(pendingTarget: 80, language: "ru")?.contains("80 %"), true)
        XCTAssertEqual(E.pendingText(pendingTarget: 80, language: "en")?.contains("80%"), true)
        XCTAssertEqual(E.percent(80, language: "ru"), "80 %")
        XCTAssertEqual(E.percent(80, language: "en"), "80%")
        XCTAssertEqual(E.text(off, language: "ru"), "100 %", "limit off reads as 100 %")
        XCTAssertEqual(E.text(held, language: "en"), "90%")
        XCTAssertEqual(E.text(.init(enabled: false, target: 80, optimizedCharging: true), language: "en"), "100%", "disabled+80 shows 100")
        XCTAssertNil(E.text(nil))
        XCTAssertTrue(E.showsOptimizedSwitch(isDemo: false, optimizedAvailable: true), "independent of the limit")
        XCTAssertFalse(E.showsOptimizedSwitch(isDemo: false, optimizedAvailable: false))
        XCTAssertFalse(E.showsOptimizedSwitch(isDemo: true, optimizedAvailable: true))
    }

    // MARK: Composition

    func testLeadOnAdapterOnBatteryStaleAndUnknown() {
        setLanguage("ru")
        func display(_ value: Double) -> ReadingDisplay {
            ReadingDisplay(number: value.formatted(.number.locale(ru).precision(.fractionLength(1))), unit: "Вт",
                           approximate: false, state: .live, masked: false)
        }
        var input = ChargingLeadInputs()
        input.overview.level = 72
        input.overview.power = .charging
        input.input = display(18.6)
        input.battery = display(7.2)
        input.transport = "USB-C"
        input.rating = "96 Вт"
        let adapter = ChargingLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(adapter.value, "18,6 Вт")
        XCTAssertEqual(adapter.status, L10n.text("On adapter"))
        XCTAssertEqual(adapter.tone, .input)
        XCTAssertEqual(adapter.detail, "USB-C · 96 Вт · " + L10n.text("charging"))

        input.input = .unavailable
        input.transport = nil
        input.overview.power = .connectedNotCharging
        let missing = ChargingLead.make(input, language: "ru", locale: ru)
        XCTAssertEqual(missing.value, "—", "a missing input is «—», never 0")
        XCTAssertEqual(missing.detail, "96 Вт · " + L10n.text("not charging"))

        var battery = ChargingLeadInputs()
        battery.overview.level = 60
        battery.overview.power = .onBattery
        battery.overview.forecastSeconds = 18_000...18_000
        battery.battery = display(6.1)
        let onBattery = ChargingLead.make(battery, language: "ru", locale: ru)
        XCTAssertEqual(onBattery.value, "6,1 Вт")
        XCTAssertEqual(onBattery.status, L10n.text("On battery (lead)"))
        XCTAssertEqual(onBattery.tone, .battery)
        XCTAssertEqual(onBattery.detail, L10n.text("no adapter") + " · до 20 % ≈ 5 ч")
        battery.overview.forecastSeconds = nil
        XCTAssertEqual(ChargingLead.make(battery, language: "ru", locale: ru).detail, L10n.text("no adapter"), "no forecast: the fragment is dropped")

        battery.overview.stale = true
        battery.overview.lastRead = Date(timeIntervalSince1970: 0)
        let stale = ChargingLead.make(battery, language: "ru", locale: ru)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.status, L10n.text("Stale"))
        XCTAssertTrue(stale.detail.hasPrefix("последнее чтение "))

        let unknown = ChargingLead.make(ChargingLeadInputs(), language: "ru", locale: ru)
        XCTAssertEqual(unknown.value, "—")
        XCTAssertEqual(unknown.tone, .secondary)
    }

    func testSignedBatteryAndReadOnlyLimit() {
        func battery(_ value: Double?) -> CatalogReading? {
            value.map { ChargingFixture.reading("038", .decimal($0), at: Date()) }
        }
        XCTAssertEqual(ChargingComposition.signedBattery(battery(7.2), locale: ru, language: "ru").text, "+7,2 Вт")
        XCTAssertEqual(ChargingComposition.signedBattery(battery(-6.1), locale: ru, language: "ru").text, "−6,1 Вт")
        XCTAssertEqual(ChargingComposition.signedBattery(battery(0.01), locale: ru, language: "ru").text, "0,0 Вт", "zero carries no sign")
        XCTAssertEqual(ChargingComposition.signedBattery(battery(0), locale: ru, language: "ru").text, "0,0 Вт", "a valid zero stays 0")
        XCTAssertEqual(ChargingComposition.signedBattery(nil).text, "—")

        let held = NativeChargeConfiguration(enabled: true, target: 80, optimizedCharging: false)
        let off = NativeChargeConfiguration(enabled: false, target: 100, optimizedCharging: false)
        XCTAssertEqual(ChargingComposition.macOSLimitText(native: held, systemManual: 90, language: "ru"), "80 %")
        XCTAssertEqual(ChargingComposition.macOSLimitText(native: off, systemManual: nil, language: "ru"), "100 %")
        XCTAssertEqual(ChargingComposition.macOSLimitText(native: nil, systemManual: 85, language: "en"), "85%")
        XCTAssertEqual(ChargingComposition.macOSLimitText(native: nil, systemManual: nil), "—")
        XCTAssertEqual(ChargingComposition.onOff(nil), "—")
        XCTAssertEqual(ChargingComposition.onOff(false), L10n.text("Off"))
    }

    func testAdapterRowsWithAndWithoutAdapter() {
        setLanguage("ru")
        let now = Date()
        let connected = ChargingFixture.snapshot(at: now, level: 72, adapter: true).catalog
        let rows = ChargingComposition.adapterRows(connected, connected: true, language: "ru")
        XCTAssertEqual(rows.map(\.id), ["015", "050", "051", "052", "047", "048"])
        XCTAssertEqual(rows[0].value, "USB-C", "the connection row names the transport")
        XCTAssertEqual(rows.first { $0.id == "048" }?.value, "••••••", "the adapter serial stays masked")
        XCTAssertEqual(rows.first { $0.id == "050" }?.value, "96 Вт")
        let more = ChargingComposition.moreRows(connected, language: "ru")
        XCTAssertEqual(more.map(\.id), ["045", "046", "053", "055", "056"], "049 is not repeated under «Ещё»")

        let absent = ChargingFixture.snapshot(at: now, level: 72, adapter: false).catalog
        let none = ChargingComposition.adapterRows(absent, connected: false, language: "ru")
        XCTAssertEqual(none.map(\.id), ["015"])
        XCTAssertEqual(none[0].value, L10n.text("Not connected"))
        XCTAssertTrue(none[0].dim)
        // Missing readings with an adapter are «—», never zero.
        let sparse = ChargingComposition.adapterRows([], connected: nil, language: "ru")
        XCTAssertTrue(sparse.allSatisfy { $0.value == "—" })
    }

    // MARK: Rendering

    private func host<Content: View>(_ content: Content, dark: Bool, height: CGFloat = 720) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let root = WindowThemeResolver {
            NavigationStack {
                content
                    .background { WindowCanvas().ignoresSafeArea() }
                    .tint(WindowTheme.accent)
            }
        }
        .environment(\.locale, L10n.locale)
        .font(.system(size: 13))
        let view = NSHostingView(rootView: root)
        view.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = view
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)   // gallery only
        window.setFrame(NSRect(x: 60, y: 60, width: 800, height: height), display: true)
        return window
    }

    private func capture(_ window: NSWindow, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit()
    }

    /// Scrolls the page's scroll view to its end (for the lower half of a page in the gallery).
    private func scrollToEnd(_ view: NSView) {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        for scroll in all(view).compactMap({ $0 as? NSScrollView }) {
            guard let document = scroll.documentView else { continue }
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Normal, no-adapter, pending and not-validated pages in RU/EN × light/dark, the quick menu's Charge page on screen
    /// at the same time. The transport fails the test on any write: rendering never writes, never starts a session.
    func testChargingGalleryNeverWrites() async throws {
        let rendering = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"] != nil
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }

        let normal = try await ChargingFixture.make()
        defer { normal.cleanup() }
        XCTAssertEqual(Editor.mode(normal.model), .slider)
        XCTAssertFalse(normal.model.metricSeries(id: "054").points.isEmpty, "the hour chart has recorded input power")

        let noAdapter = try await ChargingFixture.make(adapter: false, level: 64)
        defer { noAdapter.cleanup() }

        // A lower limit below the charge waits for discharge without any write (the transport would fail the test).
        let pending = try await ChargingFixture.make(level: 87, nativeTarget: 90)
        defer { pending.cleanup() }
        pending.model.setDraft(85)
        pending.model.applyDraftTarget()
        for _ in 0..<40 where pending.model.nativeCharge.pendingTarget == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(pending.model.nativeCharge.pendingTarget, 85)
        let state = pending.model.nativeCharge.presentation()
        XCTAssertFalse(Editor.isApplied(shown: Editor.shown(chosen: nil, model: pending.model),
                                                   current: Editor.current(state.currentPreference),
                                                   pendingTarget: state.pendingTarget), "pending is never drawn as applied")

        let unvalidated = try await ChargingFixture.make(admitted: false)
        defer { unvalidated.cleanup() }
        XCTAssertEqual(Editor.mode(unvalidated.model), .unavailable)

        // Monitoring only: no control, the macOS limit as a read-only row.
        let monitoring = try await ChargingFixture.make(monitoringOnly: true)
        defer { monitoring.cleanup() }
        XCTAssertEqual(Editor.mode(monitoring.model), .readOnly)

        let suite = TestDefaults.name("WindowChargingDemo")
        let demo = TilveroModel(isDemo: true, preferences: TestDefaults.defaults(suite))
        defer { demo.stop(); TestDefaults.remove(suite) }
        await demo.refresh()

        let cases: [(String, TilveroModel)] = [("normal", normal.model), ("noadapter", noAdapter.model),
                                               ("pending", pending.model), ("unvalidated", unvalidated.model),
                                               ("readonly", monitoring.model), ("demo", demo)]
        let extra: Set<String> = ["unvalidated", "readonly", "demo"]
        for (name, model) in cases {
            let observedBefore = model.nativeCharge.observed?.configuration
            let demoDraft = model.isDemo ? model.chargeState : nil
            for language in ["ru", "en"] {
                setLanguage(language, model: model)
                for dark in [false, true] {
                    if !rendering && (dark || language == "en") { continue }
                    if rendering && extra.contains(name) && (dark || language == "en") { continue }
                    let window = host(ChargingPage(model: model), dark: dark)
                    // The quick menu's Charge page beside it: both editors on screen at once.
                    let quick = NSWindow(contentViewController: NSHostingController(rootView: QuickPanel(model: model, section: .charge)
                        .frame(width: QuickPanelMetrics.width)))
                    quick.setFrame(NSRect(x: 900, y: 60, width: QuickPanelMetrics.width, height: 700), display: true)
                    quick.orderFront(nil)
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(rendering ? 1.5 : 0.5))
                    XCTAssertEqual(window.title, L10n.text("Charging (sidebar)"), "page title reaches the toolbar")
                    let suffix = "\(language)-\(dark ? "dark" : "light")"
                    try capture(window, "charging-\(name)-\(suffix)")
                    if rendering, let view = window.contentView {
                        scrollToEnd(view)
                        try? await Task.sleep(for: .seconds(0.6))
                        try capture(window, "charging-\(name)-\(suffix)-end")
                    }
                    quick.close()
                    window.close()
                }
            }
            XCTAssertEqual(model.nativeCharge.observed?.configuration, observedBefore, "rendering never changes the limit")
            XCTAssertFalse(model.isChargeOnceRunning, "rendering never starts a one-time charge")
            XCTAssertFalse(model.chargeBy.isArmed, "rendering never arms charge by time")
            XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
            if model.isDemo { XCTAssertEqual(model.chargeState, demoDraft, "rendering never changes the simulation") }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["ChargingPage"] ?? 0, 6)
    }

    /// The window and the quick menu edit one model: after an apply from one surface both show the same level, drawn as
    /// applied, and the draft both read is that level. Uses an in-memory transport (never the Mac's settings).
    func testPopoverAndWindowEditorsAgreeAfterAnApply() async throws {
        let fixture = try await ChargingFixture.make(level: 60, transport: MemoryChargeTransport())
        defer { fixture.cleanup() }
        let model = fixture.model
        let window = host(ChargingPage(model: model), dark: false)
        let quick = NSWindow(contentViewController: NSHostingController(rootView: QuickPanel(model: model, section: .charge)
            .frame(width: QuickPanelMetrics.width)))
        quick.orderFront(nil)
        window.orderFront(nil)
        defer { quick.close(); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(Editor.current(model.nativeCharge.presentation().currentPreference), 90)

        model.setDraft(85)
        model.applyDraftTarget()
        for _ in 0..<60 where model.nativeCharge.observed?.configuration.target != 85 || model.isApplying {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.nativeCharge.observed?.configuration.target, 85, "the limit was applied (fixture transport)")
        let state = model.nativeCharge.presentation()
        // Both surfaces compute their readout from the same function over the same model state.
        let window85 = Editor.shown(chosen: nil, model: model)
        let quick85 = Editor.shown(chosen: nil, model: model)
        XCTAssertEqual(window85, 85)
        XCTAssertEqual(window85, quick85)
        XCTAssertTrue(Editor.isApplied(shown: window85, current: Editor.current(state.currentPreference),
                                                  pendingTarget: state.pendingTarget))
        XCTAssertEqual(Editor.targets(model), [80, 85, 90, 95, 100])
    }
}
