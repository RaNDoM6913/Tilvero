// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
@testable import PowerPersistence
@testable import TilveroApp

@MainActor final class WindowHistoryPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]
    private let ru = Locale(identifier: "ru_RU"), en = Locale(identifier: "en_US")

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: Pure composition

    func testSampleCountUsesRussianPluralForms() {
        XCTAssertEqual(HistoryPageText.samples(1, language: "ru", locale: ru), "1 измерение")
        XCTAssertEqual(HistoryPageText.samples(3, language: "ru", locale: ru), "3 измерения")
        XCTAssertEqual(HistoryPageText.samples(12, language: "ru", locale: ru), "12 измерений")
        XCTAssertEqual(HistoryPageText.samples(1440, language: "ru", locale: ru), "1\u{00A0}440 измерений")
        XCTAssertEqual(HistoryPageText.samples(1440, language: "en", locale: en), "1,440 samples")
        XCTAssertEqual(HistoryPageText.samples(1, language: "en", locale: en), "1 sample")
    }

    func testValuesKeepZeroAndUseTrueMinus() {
        XCTAssertEqual(HistoryPageText.value(72, measurement: .charge, fahrenheit: false, language: "ru", locale: ru), "72 %")
        XCTAssertEqual(HistoryPageText.value(72, measurement: .charge, fahrenheit: false, language: "en", locale: en), "72%")
        XCTAssertEqual(HistoryPageText.value(0, measurement: .power, fahrenheit: false, language: "en", locale: en), "0.0 W")
        XCTAssertEqual(HistoryPageText.value(-0.01, measurement: .power, fahrenheit: false, language: "en", locale: en), "0.0 W")
        XCTAssertEqual(HistoryPageText.value(-6.1, measurement: .power, fahrenheit: false, language: "ru", locale: ru), "−6,1 Вт")
        XCTAssertEqual(HistoryPageText.value(32.4, measurement: .temperature, fahrenheit: false, language: "en", locale: en), "32.4 °C")
        XCTAssertEqual(HistoryPageText.value(nil, measurement: .charge, fahrenheit: false), "—")
    }

    func testLeadStates() {
        var input = HistoryPageText.LeadInputs(current: 72, minimum: 41, maximum: 88, count: 1440)
        let now = HistoryPageText.lead(input, measurement: .charge, fahrenheit: false, language: "ru", locale: ru)
        XCTAssertEqual(now.value, "72 %")
        XCTAssertEqual(now.status, L10n.text("Now"))
        XCTAssertEqual(now.detail, "мин 41 % · макс 88 % · 1\u{00A0}440 измерений")

        input.recording = false
        let off = HistoryPageText.lead(input, measurement: .charge, fahrenheit: false, language: "ru", locale: ru)
        XCTAssertEqual(off.value, "—")
        XCTAssertEqual(off.status, L10n.text("Recording is off"))

        let missing = HistoryPageText.lead(.init(current: nil), measurement: .power, fahrenheit: false, language: "en", locale: en)
        XCTAssertEqual(missing.value, "—")
        XCTAssertEqual(missing.status, L10n.text("No data"))
        XCTAssertEqual(missing.detail, "", "no range statistics without recorded points")

        let stale = HistoryPageText.lead(.init(current: 31, currentStale: true), measurement: .temperature, fahrenheit: false,
                                         language: "en", locale: en)
        XCTAssertTrue(stale.stale)

        let demo = HistoryPageText.lead(.init(current: 50, recording: false, demo: true, minimum: 1, maximum: 2, count: 3),
                                        measurement: .charge, fahrenheit: false, language: "en", locale: en)
        XCTAssertEqual(demo.value, "50%")
        XCTAssertEqual(demo.detail, "", "simulation has no recorded range")
    }

    func testEnergyAndCountsNeverInventZero() {
        XCTAssertEqual(HistoryPageText.energy(nil, sign: .plus), .unavailable)
        XCTAssertEqual(HistoryPageText.count(nil), .unavailable)
        XCTAssertEqual(HistoryPageText.count(0, locale: en).text, "0")
        XCTAssertEqual(HistoryPageText.energy(412.3, sign: .plus, language: "ru", locale: ru).text, "≈ +412 Вт·ч")
        XCTAssertEqual(HistoryPageText.energy(398, sign: .minus, language: "en", locale: en).text, "≈ −398 Wh")
        XCTAssertEqual(HistoryPageText.energy(2.25, sign: .plus, language: "en", locale: en).text, "≈ +2.2 Wh")
        XCTAssertEqual(HistoryPageText.energy(0, sign: .minus, language: "en", locale: en).text, "≈ 0.0 Wh")
    }

    func testSessionRowsShowRecordedChargingSessionsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 14, minute: 30))!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        func session(_ kind: String, _ from: Date, _ to: Date?, known: Bool = true) -> HistorySession {
            HistorySession(id: UUID(), segmentID: UUID(), kind: kind, observedFrom: from, endedAt: to, originalStartKnown: known)
        }
        let sessions = [session("charging", at(18, 22, 0), at(19, 1, 0)),
                        session("charging", at(19, 18, 40), at(19, 19, 55)),
                        session("onBattery", at(19, 20, 0), at(20, 12, 0)),
                        session("charging", at(20, 12, 10), nil, known: false)]
        let rows = HistoryPageText.sessionRows(sessions, now: now, language: "ru", locale: ru, calendar: calendar)
        XCTAssertEqual(rows.count, 3, "only charging sessions")
        XCTAssertTrue(rows[0].label.hasPrefix("Сегодня "))
        XCTAssertTrue(rows[0].label.hasSuffix("– сейчас"))
        XCTAssertEqual(rows[0].value, "≥ 2 ч 20 мин", "start before monitoring is a lower bound")
        XCTAssertTrue(rows[1].label.hasPrefix("Вчера "))
        XCTAssertEqual(rows[1].value, "1 ч 15 мин")
        XCTAssertTrue(rows[2].label.contains("Вчера"), "an end on another day names its day")
        XCTAssertEqual(rows[2].value, "3 ч")
        XCTAssertFalse(rows.contains { $0.label.contains("%") }, "no session levels")
    }

    func testSeriesStatisticsComeFromRecordedPointsOnly() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let samples = fixture.model.history
        XCTAssertFalse(samples.isEmpty)
        let now = Date()
        let built = HistoryPageSeries.build(samples, measurement: .charge, range: .day, fahrenheit: false, now: now)
        let recorded = samples.filter { $0.collectedAt >= now.addingTimeInterval(-86_400) && $0.chargePercent != nil }
        XCTAssertEqual(built.count, recorded.count)
        XCTAssertEqual(built.minimum, recorded.compactMap(\.chargePercent).min())
        XCTAssertEqual(built.maximum, recorded.compactMap(\.chargePercent).max())
        XCTAssertGreaterThan(Set(built.points.map(\.series)).count, 1, "the night gap stays a gap")
        let fahrenheit = HistoryPageSeries.build(samples, measurement: .temperature, range: .day, fahrenheit: true, now: now)
        XCTAssertGreaterThan(fahrenheit.minimum ?? 0, 80, "°F conversion")
    }

    // MARK: Render

    private func setLanguage(_ language: String, model: TilveroModel) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model.language = language
    }

    private func host(_ model: TilveroModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let root = WindowThemeResolver {
            WindowShell(model: model) {
                HistoryPage(model: model)
                    .background { WindowCanvas().ignoresSafeArea() }
                    .tint(WindowTheme.accent)
            }
        }
        .environment(\.locale, L10n.locale)
        .font(.system(size: 13))
        let view = NSHostingView(rootView: root)
        view.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = view
        window.setContentSize(NSSize(width: 1000, height: 720))
        return window
    }

    private func capture(_ window: NSWindow, _ name: String, to output: URL?) throws {
        guard let output else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit()
    }

    /// RU/EN × light/dark, plus recording off; PNGs when `TILVERO_RENDER_OUT` is set. Rendering never exports,
    /// never writes a control.
    func testHistoryGallery() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.navigation.navigate(to: .section(.history))
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let window = host(model)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(2))
                XCTAssertEqual(window.title, L10n.text("History"))
                try capture(window, "history-\(language)-\(dark ? "dark" : "light")", to: output)
                window.close()
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["HistoryPage"] ?? 0, 1)
        model.historyEnabled = false
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            let window = host(model)
            window.appearance = NSAppearance(named: .aqua)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            try capture(window, "history-off-\(language)-light", to: output)
            window.close()
        }
        XCTAssertNil(model.exportPreview)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertNil(model.nativeCharge.observed)
    }
}
