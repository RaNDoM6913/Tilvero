// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
import PowerPersistence
@testable import TilveroApp

/// A model over a temporary history store with the last hour of battery temperatures (one a minute) and a current
/// snapshot; `fanless` adds the fanless model identifier, `stale` marks the temperature stale. Fixture data only.
@MainActor private struct CoolingFixture {
    let model: TilveroModel
    let cleanup: () -> Void

    static func make(fanless: Bool, stale: Bool = false) async throws -> CoolingFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowCooling"), defaults = TestDefaults.defaults(suite)
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        for minute in stride(from: 70.0, to: 0, by: -1) {
            try await store.record(WindowFixture.snapshot(at: now.addingTimeInterval(-minute * 60), level: 70, minutesAgo: minute))
        }
        try await store.close()
        let base = WindowFixture.snapshot(at: now, level: 72, minutesAgo: 0)
        var catalog = base.catalog.map { reading -> CatalogReading in
            guard stale, reading.id == "039" else { return reading }
            return CatalogReading(definition: reading.definition, value: reading.value, unit: reading.unit, source: reading.source,
                                  keyPath: reading.keyPath, collectedAt: now.addingTimeInterval(-1800),
                                  provenance: reading.provenance, availability: .available, freshness: .stale)
        }
        if fanless {
            catalog.append(CatalogReading(definition: BatteryCatalog.definition("001"), value: .text("Mac17,3"), source: "fixture",
                                          keyPath: "model", collectedAt: now, provenance: .measured, availability: .available,
                                          freshness: .fresh))
        }
        let current = BatterySnapshot(chargePercent: base.chargePercent, isCharging: base.isCharging,
                                      isExternalPower: base.isExternalPower, temperatureCelsius: base.temperatureCelsius,
                                      collectedAt: now, catalog: catalog, monotonicTime: base.monotonicTime,
                                      batteryIdentityToken: base.batteryIdentityToken)
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { current },
                                 liveSampler: { nil }, newWindow: true)
        await model.refresh()
        await model.waitForHistoryWork()
        return CoolingFixture(model: model, cleanup: {
            model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class WindowCoolingPageTests: XCTestCase {
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

    private func reading(_ id: String, _ value: CatalogValue?, freshness: TelemetryFreshness = .fresh,
                         availability: TelemetryAvailability = .available) -> CatalogReading {
        CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: "test", collectedAt: Date(),
                       provenance: .measured, availability: availability, freshness: freshness)
    }

    // MARK: Pure composition

    func testCoolingKindNeverClaimsUndiscoveredFans() {
        XCTAssertEqual(CoolingKind.resolve(fanless: true, discoveredFans: 0), .fanless)
        XCTAssertEqual(CoolingKind.resolve(fanless: true, discoveredFans: 2), .fanless)
        XCTAssertEqual(CoolingKind.resolve(fanless: false, discoveredFans: 2), .fans)
        XCTAssertEqual(CoolingKind.resolve(fanless: false, discoveredFans: 0), .system)
        for kind in [CoolingKind.fanless, .fans, .system] {
            XCTAssertTrue(kind.detailKey.hasPrefix("battery · "), "the lead says it is the battery's temperature")
            XCTAssertNil(kind.detailKey.rangeOfCharacter(from: .decimalDigits), "no fan count")
        }
    }

    func testLeadStates() {
        let live = ReadingDisplay(number: "32,4", unit: "°C", approximate: false, state: .live, masked: false)
        let normal = CoolingPage.lead(temperature: live, thermalRaw: "nominal", thermalText: "Обычное", kind: .fanless,
                                      lastRead: nil, language: "ru", locale: Locale(identifier: "ru_RU"))
        XCTAssertEqual(normal.value, "32,4 °C")
        XCTAssertEqual(normal.status, "Обычное")
        XCTAssertEqual(normal.tone, .accent)
        XCTAssertEqual(normal.detail, L10n.text("battery · fanless cooling"))
        XCTAssertFalse(normal.stale)

        let hot = CoolingPage.lead(temperature: live, thermalRaw: "serious", thermalText: "Высокое", kind: .fans, lastRead: nil)
        XCTAssertEqual(hot.tone, .attention)
        XCTAssertEqual(hot.detail, L10n.text("battery · fans"))

        let missing = CoolingPage.lead(temperature: .unavailable, thermalRaw: "nominal", thermalText: "Обычное", kind: .system, lastRead: nil)
        XCTAssertEqual(missing.value, "—")
        XCTAssertEqual(missing.tone, .secondary)
        XCTAssertEqual(missing.detail, L10n.text("battery · system cooling"))

        let old = ReadingDisplay(number: "32,4", unit: "°C", approximate: false, state: .stale, masked: false)
        var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 20; parts.hour = 14; parts.minute = 2
        let date = Calendar.current.date(from: parts)!
        let stale = CoolingPage.lead(temperature: old, thermalRaw: "nominal", thermalText: "Обычное", kind: .fanless,
                                     lastRead: date, language: "ru", locale: Locale(identifier: "ru_RU"))
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.status, L10n.text("Stale"))
        XCTAssertEqual(stale.detail, "последнее чтение 14:02")
        XCTAssertEqual(stale.value, "32,4 °C", "the last value stays, drawn secondary with a clock")
    }

    func testFanControlsOnlyInDemoOrWhenControllable() {
        XCTAssertFalse(CoolingPage.showsFanControls(fanless: true, isDemo: true, canControlFans: true, discoveredFans: 2))
        XCTAssertTrue(CoolingPage.showsFanControls(fanless: false, isDemo: true, canControlFans: false, discoveredFans: 0))
        XCTAssertFalse(CoolingPage.showsFanControls(fanless: false, isDemo: false, canControlFans: false, discoveredFans: 2))
        XCTAssertFalse(CoolingPage.showsFanControls(fanless: false, isDemo: false, canControlFans: true, discoveredFans: 0))
        XCTAssertTrue(CoolingPage.showsFanControls(fanless: false, isDemo: false, canControlFans: true, discoveredFans: 2))
    }

    func testFanRows() {
        XCTAssertTrue(CoolingPage.fanRows(descriptors: [], rpm: ["0": 1800], phase: .systemAuto).isEmpty)
        let fans = [FanDescriptor(id: "0", minimumRPM: 1200, maximumRPM: 6000), FanDescriptor(id: "1", minimumRPM: 1200, maximumRPM: 6000)]
        let rows = CoolingPage.fanRows(descriptors: fans, rpm: ["0": 1820, "1": 0], phase: .systemAuto,
                                       language: "ru", locale: Locale(identifier: "ru_RU"))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].value, 1820.formatted(.number.locale(Locale(identifier: "ru_RU"))) + " об/мин")
        XCTAssertEqual(rows[1].value, "0 об/мин", "a valid zero stays zero")
        XCTAssertEqual(rows[2].value, L10n.text("macOS (auto)"))
        let unread = CoolingPage.fanRows(descriptors: fans, rpm: [:], phase: .managed, language: "en", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(unread[0].value, "—")
        XCTAssertTrue(unread[0].dim)
        XCTAssertEqual(unread[2].value, "Tilvero")
    }

    func testTemperatureScaleIsFittedNotFromZero() {
        let narrow = CoolingPage.temperatureDomain([32.1, 32.4, 32.7])
        XCTAssertGreaterThanOrEqual(narrow.domain.upperBound - narrow.domain.lowerBound, 3)
        XCTAssertGreaterThan(narrow.domain.lowerBound, 0)
        XCTAssertLessThanOrEqual(narrow.domain.lowerBound, 32.1)
        XCTAssertGreaterThanOrEqual(narrow.domain.upperBound, 32.7)
        XCTAssertEqual(narrow.ticks.first, narrow.domain.lowerBound)
        XCTAssertEqual(narrow.ticks.last, narrow.domain.upperBound)
        let wide = CoolingPage.temperatureDomain([24, 41.5])
        XCTAssertLessThanOrEqual(wide.domain.lowerBound, 24)
        XCTAssertGreaterThanOrEqual(wide.domain.upperBound, 41.5)
        XCTAssertLessThanOrEqual(wide.ticks.count, 10)
    }

    func testCellsAndOtherSensorsNeverInventValues() {
        XCTAssertEqual(CoolingPage.cellsDisplay(nil, fahrenheit: false).text, "—")
        XCTAssertEqual(CoolingPage.cellsDisplay(reading("040", nil, availability: .unavailable), fahrenheit: false).text, "—")
        let cells = CoolingPage.cellsDisplay(reading("040", .list([.decimal(31.2), .decimal(31.6)])), fahrenheit: false,
                                             locale: Locale(identifier: "en_US"))
        XCTAssertEqual(cells.text, "31.2 / 31.6 °C")
        let fahrenheit = CoolingPage.cellsDisplay(reading("040", .list([.decimal(30)])), fahrenheit: true, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fahrenheit.text, "86.0 °F")

        XCTAssertTrue(CoolingPage.otherSensorRows(nil, fahrenheit: false).isEmpty)
        XCTAssertTrue(CoolingPage.otherSensorRows(reading("094", nil, availability: .unavailable), fahrenheit: false).isEmpty)
        let sensors = CoolingPage.otherSensorRows(reading("094", .object(["SSD": .decimal(40.4), "CPU": .decimal(45)])),
                                                  fahrenheit: false, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(sensors.map(\.label), ["CPU", "SSD"])
        XCTAssertEqual(sensors.map(\.value), ["45.0 °C", "40.4 °C"])
    }

    // MARK: Render

    private func host(_ model: TilveroModel, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let root = WindowThemeResolver {
            NavigationStack {
                CoolingPage(model: model)
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
        window.setFrame(NSRect(x: 60, y: 60, width: 800, height: 720), display: true)
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

    /// Fanless, unknown, stale and DEMO (fans) pages in RU/EN × light/dark; PNGs when `TILVERO_RENDER_OUT` is set.
    /// Rendering never changes a control.
    func testCoolingGallery() async throws {
        let rendering = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"] != nil
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }

        let fanless = try await CoolingFixture.make(fanless: true)
        defer { fanless.cleanup() }
        XCTAssertTrue(fanless.model.fanless)
        XCTAssertTrue(fanless.model.fanDescriptors.isEmpty)
        XCTAssertFalse(fanless.model.metricSeries(id: "039").points.isEmpty, "the hour chart has recorded temperatures")

        let unknown = try await CoolingFixture.make(fanless: false)
        defer { unknown.cleanup() }
        XCTAssertFalse(unknown.model.fanless)

        let stale = try await CoolingFixture.make(fanless: true, stale: true)
        defer { stale.cleanup() }

        let suite = TestDefaults.name("WindowCoolingDemo")
        let demo = TilveroModel(isDemo: true, preferences: TestDefaults.defaults(suite))
        defer { demo.stop(); TestDefaults.remove(suite) }
        await demo.refresh()
        XCTAssertFalse(demo.fanDescriptors.isEmpty, "the simulation has fans")

        let cases: [(String, TilveroModel)] = [("fanless", fanless.model), ("unknown", unknown.model),
                                               ("stale", stale.model), ("demo-fans", demo)]
        for (name, model) in cases {
            for language in ["ru", "en"] {
                setLanguage(language, model: model)
                for dark in [false, true] {
                    if !rendering && (dark || language == "en") { continue }
                    let window = host(model, dark: dark)
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(rendering ? 1.5 : 0.5))
                    XCTAssertEqual(window.title, L10n.text("Cooling"), "page title reaches the toolbar")
                    try capture(window, "cooling-\(name)-\(language)-\(dark ? "dark" : "light")")
                    window.close()
                }
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["CoolingPage"] ?? 0, 4)
        for model in [fanless.model, unknown.model, stale.model] {
            XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
            XCTAssertNil(model.nativeCharge.observed)
            XCTAssertEqual(model.fanPhase, .systemAuto)
        }
        XCTAssertEqual(demo.fanPhase, .systemAuto, "rendering never applies a fan policy")
    }
}
