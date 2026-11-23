// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
import PowerTelemetry
import PowerPersistence
@testable import TilveroApp

/// A model over a temporary history store: a day of charging samples (one every five minutes, a recording gap at
/// night) and a charging snapshot at 72 %. Fixture data only; no production preferences, journals or control services.
@MainActor struct WindowFixture {
    let model: TilveroModel
    let defaults: UserDefaults
    let cleanup: () -> Void

    static func snapshot(at date: Date, level: Int, minutesAgo: Double, charging: Bool = true) -> BatterySnapshot {
        // Channel names the history store keeps (others are redacted, which would break every line into points).
        let paths = ["054": "SystemPowerIn", "038": "Voltage×Amperage", "039": "Temperature", "026": "capacityRetention"]
        func reading(_ id: String, _ value: CatalogValue, provenance: TelemetryProvenance = .measured) -> CatalogReading {
            CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: "fixture", keyPath: paths[id] ?? "Watts",
                           collectedAt: date, provenance: provenance, availability: .available, freshness: .fresh)
        }
        let input = 18.6 + 1.5 * sin(minutesAgo / 7), battery = 7.2 + 0.6 * sin(minutesAgo / 5)
        let catalog = [reading("011", .integer(Int64(level))), reading("054", .decimal(input)),
                       reading("038", .decimal(charging ? battery : -6.1)), reading("039", .decimal(32.4 + 0.3 * sin(minutesAgo / 9))),
                       reading("026", .decimal(94.2), provenance: .estimated), reading("050", .integer(96)),
                       reading("070", .decimal(1500)), reading("044", .text("nominal")), reading("027", .integer(146))]
        return BatterySnapshot(chargePercent: .init(value: level, source: "fixture", collectedAt: date, freshness: .fresh),
                               isCharging: .init(value: charging, source: "fixture", collectedAt: date, freshness: .fresh),
                               isExternalPower: .init(value: charging, source: "fixture", collectedAt: date, freshness: .fresh),
                               temperatureCelsius: .init(value: 32.4, source: "fixture", collectedAt: date, freshness: .fresh),
                               collectedAt: date, catalog: catalog, monotonicTime: 2_000_000 - minutesAgo * 60,
                               batteryIdentityToken: "fixture-battery")
    }

    static func make() async throws -> WindowFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowShell"), defaults = TestDefaults.defaults(suite)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        // The last hour once a minute (Hour chart), the rest of the day every five minutes with a night gap.
        let minutes: [Double] = Array(stride(from: 1440.0, to: 0, by: -1)).filter { !(600...960).contains($0) }
        for minute in minutes {
            let level = Int(55 + 25 * sin(minute / 400))
            try await store.record(snapshot(at: now.addingTimeInterval(-minute * 60), level: level, minutesAgo: minute))
        }
        try await store.close()
        let current = snapshot(at: now, level: 72, minutesAgo: 0)
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { current },
                                 liveSampler: { nil }, newWindow: true)
        await model.refresh()
        await model.waitForHistoryWork()
        return WindowFixture(model: model, defaults: defaults, cleanup: {
            model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class WindowShellRenderTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    private func setLanguage(_ language: String, model: TilveroModel) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model.language = language
    }

    private func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The production window: toolbar, unified style, full-size content, no forced appearance, minimum size.
    func testControllerConfiguresTheWindow() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let window = MainWindowController.makeWindow(model: fixture.model, remembersFrame: false)
        defer { window.close() }
        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNil(window.appearance, "light and dark follow the system")
        XCTAssertEqual(window.contentMinSize, MainWindowController.minimumSize)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView is NSHostingView<MainWindowView>)
        // No SwiftUI min/ideal/max sizing passes on every frame (they made the sidebar animation stutter).
        XCTAssertEqual((window.contentView as? NSHostingView<MainWindowView>)?.sizingOptions, [])
        // Shrinking below the minimum is still refused by the window itself.
        window.setContentSize(NSSize(width: 500, height: 300))
        window.setFrame(window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 500, height: 300))), display: false)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, MainWindowController.minimumSize.width)
    }

    /// The builder switches one layout by width: no ViewThatFits measuring the quick-menu preview twice per frame.
    func testQuickPanelBuilderHasNoViewThatFits() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/TilveroApp/QuickPanelBuilder.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertFalse(source.contains("ViewThatFits {") || source.contains("ViewThatFits(in"))
    }

    /// Sub-page tabs are the toolbar's segmented picker in the title row, like the Overview range picker (owner
    /// 2026-11-23); no principal item (it went into the overflow beside the system sidebar). All data builds lazily.
    func testSubPageTabsLiveInTheToolbar() throws {
        func source(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Sources/TilveroApp/\(name).swift").standardizedFileURL, encoding: .utf8)
        }
        for name in ["BatteryPage", "SleepDrainPage", "SettingsPage"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("WindowTabbedPage {"), name)
            XCTAssertTrue(text.contains("WindowPageTabs("), name)
            XCTAssertFalse(text.contains("placement: .principal"), name)
        }
        let kit = try source("WindowKit")
        XCTAssertTrue(kit.contains("ToolbarItem(placement: .primaryAction) { tabs() }"))
        XCTAssertTrue(kit.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(try source("BatteryCatalogPage").contains("LazyVStack"))
    }

    /// Sidebar rows drive the router; the remembered section restores; an off-window route lands on its page.
    func testSidebarAndRouter() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.navigation.navigate(to: .section(.overview))
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let window = MainWindowController.makeWindow(model: model, remembersFrame: false)
        defer { window.close() }
        window.orderFront(nil)
        await spin(0.5)
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["OverviewPage"] ?? 0, 1)
        model.navigation.open(.sleep(.awake))
        XCTAssertEqual(model.navigation.section, .sleep)
        XCTAssertEqual(model.navigation.sleepPage, .awake)
        model.navigation.navigate(to: .section(.cooling))
        XCTAssertEqual(AppNavigation(preferences: fixture.defaults).section, .cooling)
        // Rendering the window never starts or changes a control.
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertNil(model.nativeCharge.observed)
    }

    /// Variant C: the glass column narrows to the icon rail and back; the page keeps the column's width free; the
    /// choice is remembered across launches.
    func testGlassColumnCollapsesToRail() async throws {
        XCTAssertEqual(WindowColumn.inset(progress: 0), 228)
        XCTAssertEqual(WindowColumn.inset(progress: 1), 68)
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.navigation.navigate(to: .section(.overview))
        XCTAssertFalse(model.navigation.sidebarCollapsed, "a new install opens with the full column")
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let window = MainWindowController.makeWindow(model: model, remembersFrame: false)
        defer { window.close() }
        window.orderFront(nil)
        await spin(0.5)
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["WindowColumn"] ?? 0, 1)
        // No system split view any more: the column is ours.
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        XCTAssertNil(views(window.contentView!).compactMap { $0.nextResponder as? NSSplitViewController }.first)
        RenderProbe.reset()
        withAnimation(WindowColumn.motion) { model.navigation.sidebarCollapsed = true }
        await spin(0.8)
        XCTAssertGreaterThan(RenderProbe.counts["WindowColumn"] ?? 0, 1, "the column redraws through the motion")
        XCTAssertTrue(AppNavigation(preferences: fixture.defaults).sidebarCollapsed)
        model.navigation.navigate(to: .section(.cooling))
        XCTAssertEqual(model.navigation.section, .cooling)
        model.navigation.sidebarCollapsed = false
        XCTAssertFalse(AppNavigation(preferences: fixture.defaults).sidebarCollapsed)
    }

    /// At the minimum width, with the column open and the longest set (five Russian Settings tabs), the tabs stay in
    /// the toolbar instead of the overflow menu.
    func testSettingsTabsFitTheToolbarAtMinimumWidth() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        setLanguage("ru", model: model)
        let root = WindowThemeResolver {
            WindowShell(model: model) {
                WindowTabbedPage { SettingsTabPicker(selection: .constant(.general), tabs: SettingsPage.allCases) } content: {
                    Color.clear
                }
                .navigationTitle(WindowSection.entry(.settings).title)
            }
        }.environment(\.locale, L10n.locale).font(.system(size: 13))
        let size = MainWindowController.minimumSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.title, .toolbars]
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        window.orderFront(nil)
        defer { window.close() }
        await spin(0.8)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let tabs = views(window.contentView!.superview!).compactMap { $0 as? NSSegmentedControl }.filter { $0.segmentCount == 5 }
        XCTAssertTrue(tabs.contains { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }, "tabs went into the overflow")
    }

    /// The page title is drawn by the shell, not steered as a toolbar item from a measurement (that fed back into the
    /// toolbar layout and made titles jitter); toolbar items keep clear of it through a computed spacer.
    func testPageTitleIsNotAMeasuredToolbarItem() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/TilveroApp/MainWindowView.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertFalse(source.contains("NSViewRepresentable"), "no view reads toolbar geometry back")
        XCTAssertFalse(source.contains("ToolbarItem(placement: .navigation) {\n                        WindowPageTitle"))
        XCTAssertTrue(source.contains("WindowPageTitle.reservedWidth("))
    }

    /// The Overview Hour chart subscribes to live charts only while it is shown in a visible window: another page
    /// releases it and a hidden window reads nothing. (Day/Week drop the `.liveCharts` view entirely; DEMO never
    /// samples by `wantsLiveCharts`.)
    func testLiveChartSubscriptionFollowsRangeAndVisibility() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.navigation.navigate(to: .section(.overview))
        let window = MainWindowController.makeWindow(model: model, remembersFrame: false)
        defer { window.close() }
        window.orderFront(nil)
        model.isDetailVisible = true
        await spin(0.6)
        XCTAssertTrue(model.visibleLiveSurfaces.contains(.windowOverview), "Hour range on screen subscribes")
        let before = model.recordedPointComputations
        model.live.append(LivePowerSample(collectedAt: Date(), systemWatts: 11, adapterWatts: 18, temperatureCelsius: 32, batteryWatts: 7),
                          boundary: "test", adapterConnected: true, joinsRecorded: true)
        await spin(0.2)
        XCTAssertEqual(model.recordedPointComputations, before, "a live tick never re-extracts recorded points")
        model.isDetailVisible = false
        XCTAssertFalse(model.visibleLiveSurfaces.contains(.windowOverview), "a hidden window reads nothing")
        model.isDetailVisible = true
        model.navigation.navigate(to: .section(.battery))
        await spin(0.6)
        XCTAssertFalse(model.visibleLiveSurfaces.contains(.windowOverview), "another page releases the subscription")
        model.navigation.navigate(to: .section(.overview))
        await spin(0.6)
        XCTAssertTrue(model.visibleLiveSurfaces.contains(.windowOverview))
        model.isDetailVisible = false
    }

    /// RU/EN × light/dark of the shell with Overview; writes PNGs of the real composited window when
    /// `TILVERO_RENDER_OUT` is set (display must be awake; windows flash on screen).
    func testOverviewGallery() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.navigation.navigate(to: .section(.overview))
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let window = MainWindowController.makeWindow(model: model, remembersFrame: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)   // gallery only; production leaves it nil
                window.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 720), display: true)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                await spin(2.0)
                XCTAssertEqual(window.title, L10n.text("Overview"), "page title reaches the window toolbar")
                if let output {
                    let file = output.appendingPathComponent("overview-\(language)-\(dark ? "dark" : "light").png")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
                    try capture.run(); capture.waitUntilExit()
                }
                if let output, language == "ru", !dark {
                    // Another page through the router.
                    model.navigation.navigate(to: .section(.battery))
                    await spin(1.5)
                    XCTAssertEqual(window.title, L10n.text("Battery"))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent("battery-ru-light.png").path]
                    try capture.run(); capture.waitUntilExit()
                    model.navigation.navigate(to: .section(.overview))
                }
                window.close()
            }
        }
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }
}
