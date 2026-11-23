// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerTelemetry
@testable import TilveroApp

/// Process samples for the Apps page: four real system app bundles with fixed CPU shares and CPU energy rates, plus
/// denied and unavailable processes. Fixture counters only; nothing reads physical processes.
private actor AppsProcessFixture {
    struct App { let key: String; let name: String; let path: String; let processes: Int; let cpu: Double; let watts: Double }
    static let apps: [App] = [
        App(key: "xcode", name: "Xcode", path: "/Applications/Xcode.app", processes: 6, cpu: 0.86, watts: 4.8),
        App(key: "safari", name: "Safari", path: "/Applications/Safari.app", processes: 14, cpu: 0.62, watts: 2.1),
        App(key: "music", name: "Music", path: "/System/Applications/Music.app", processes: 2, cpu: 0.08, watts: 0.4),
        App(key: "finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app", processes: 1, cpu: 0.02, watts: 0.1),
    ]
    var time = 0
    func read() -> ProcessResourceCollection {
        time += 10
        let scale = ProcessActivityProvider.timebase
        var counters: [ProcessResourceCounter] = []
        var pid: Int32 = 100
        for app in Self.apps {
            for _ in 0..<app.processes {
                pid += 1
                let share = 1 / Double(app.processes)
                let ticks = UInt64(Double(time) * app.cpu * share * 1e9 * Double(scale.denominator) / Double(scale.numerator))
                let energy = UInt64(Double(time) * app.watts * share * 1e9) + 1
                counters.append(.init(pid: pid, start: UInt64(pid), name: app.key + "-worker",
                                      application: .init(key: app.key, name: app.name, bundlePath: app.path),
                                      cpuTicks: ticks, cpuEnergyNanojoules: energy))
            }
        }
        return .init(collectedAt: Date(), monotonic: Double(time), counters: counters, deniedCount: 10, unavailableCount: 2)
    }
}

@MainActor final class WindowAppsPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]
    private let ru = Locale(identifier: "ru_RU"), en = Locale(identifier: "en_US")

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: Pure composition

    func testHighLoadUsesTheOldPanelThreshold() {
        XCTAssertTrue(AppsComposition.isHigh(cpuPercent: 50))
        XCTAssertTrue(AppsComposition.isHigh(cpuPercent: 186))
        XCTAssertFalse(AppsComposition.isHigh(cpuPercent: 49.9))
        XCTAssertFalse(AppsComposition.isHigh(cpuPercent: nil))
        XCTAssertFalse(AppsComposition.isHigh(cpuPercent: .nan))
        XCTAssertFalse(AppsComposition.isHigh(cpuPercent: -60))
        // Same rule as the "High · ≥50% CPU" filter the toolbar menu offers.
        XCTAssertEqual(AppsComposition.highThreshold, 50)
    }

    func testAccessiblePhraseAgreesWithTheCount() {
        XCTAssertEqual(AppsComposition.accessiblePhrase(214, language: "ru", locale: ru), "из 214 доступных процессов")
        XCTAssertEqual(AppsComposition.accessiblePhrase(21, language: "ru", locale: ru), "из 21 доступного процесса")
        XCTAssertEqual(AppsComposition.accessiblePhrase(11, language: "ru", locale: ru), "из 11 доступных процессов")
        XCTAssertEqual(AppsComposition.accessiblePhrase(214, language: "en", locale: en), "of 214 accessible processes")
        XCTAssertEqual(AppsComposition.accessiblePhrase(1, language: "en", locale: en), "of 1 accessible process")
    }

    func testLeadCountsHighLoadAppsAndNamesTheSample() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let time = at.formatted(.dateTime.hour().minute().locale(en))
        var input = AppsLeadInputs(highCount: 2, accessibleCount: 214, collectedAt: at)
        var lead = AppsComposition.lead(input, language: "en", locale: en)
        XCTAssertEqual(lead.value, "2")
        XCTAssertEqual(lead.status, L10n.text("High load"))
        XCTAssertEqual(lead.tone, .attention)
        XCTAssertEqual(lead.detail, "of 214 accessible processes · " + time)
        XCTAssertFalse(lead.stale)

        input.highCount = 0
        lead = AppsComposition.lead(input, language: "en", locale: en)
        XCTAssertEqual(lead.value, "0", "a valid zero stays 0")
        XCTAssertEqual(lead.status, L10n.text("Calm"))
        XCTAssertEqual(lead.tone, .neutral)

        input.truncated = true
        lead = AppsComposition.lead(input, language: "en", locale: en)
        XCTAssertEqual(lead.detail, "of 214 accessible processes · " + time + " · " + L10n.text("Limited scan"))

        input.stale = true
        lead = AppsComposition.lead(input, language: "en", locale: en)
        XCTAssertTrue(lead.stale, "stale draws the clock in the lead")
        XCTAssertEqual(lead.status, L10n.text("Stale"))
        XCTAssertTrue(lead.detail.contains(time), "the stale lead keeps the sample time")
    }

    func testLeadWithoutAUsableSampleShowsADash() {
        for input in [AppsLeadInputs(demo: true), AppsLeadInputs(pending: true), AppsLeadInputs(warmingUp: true),
                      AppsLeadInputs(failure: "macOS process enumeration is unavailable.", accessibleCount: 3)] {
            let lead = AppsComposition.lead(input, language: "en", locale: en)
            XCTAssertEqual(lead.value, "—")
            XCTAssertEqual(lead.tone, .secondary)
        }
        XCTAssertEqual(AppsComposition.lead(AppsLeadInputs(failure: "macOS process enumeration is unavailable.")).detail,
                       L10n.text("macOS process enumeration is unavailable."), "the reason is in the lead")
        XCTAssertEqual(AppsComposition.lead(AppsLeadInputs(pending: true)).detail, L10n.text("Waiting for process observations."))
        XCTAssertEqual(AppsComposition.lead(AppsLeadInputs(warmingUp: true)).detail,
                       L10n.text("Baseline collected. Waiting for the next sample."))
    }

    func testStaleAfterNinetySeconds() {
        let now = Date()
        XCTAssertFalse(AppsComposition.isStale(collectedAt: now.addingTimeInterval(-90), now: now))
        XCTAssertTrue(AppsComposition.isStale(collectedAt: now.addingTimeInterval(-91), now: now))
    }

    func testListStatePriority() {
        func state(demo: Bool = false, sample: Bool = true, warming: Bool = false, failed: Bool = false, rows: Int = 4,
                   filtering: Bool = false, matches: Int = 4, topThree: Bool = false, rankable: Int = 4) -> AppsListState {
            AppsComposition.listState(demo: demo, hasSample: sample, warmingUp: warming, failed: failed, sampleRowCount: rows,
                                      isFiltering: filtering, matchingCount: matches, topThree: topThree, rankableCount: rankable)
        }
        XCTAssertEqual(state(demo: true, sample: false), .demo)
        XCTAssertEqual(state(sample: false), .pending)
        XCTAssertEqual(state(warming: true, failed: true), .failed)
        XCTAssertEqual(state(warming: true), .warmingUp)
        XCTAssertEqual(state(rows: 0, matches: 0), .noSamples)
        XCTAssertEqual(state(filtering: true, matches: 0, rankable: 0), .noMatches)
        XCTAssertEqual(state(topThree: true, rankable: 0), .noRankable)
        XCTAssertEqual(state(rankable: 0), .rows, "All includes unknown values")
        XCTAssertEqual(state(), .rows)
    }

    func testRowValuesNeverInventANumber() {
        let power = AppsComposition.value(sort: .cpuPower, cpuPercent: 80, cpuPowerWatts: 4.8, locale: ru, language: "ru")
        XCTAssertEqual(power.text, "≈ 4,8 Вт", "CPU power is an interval estimate")
        XCTAssertEqual(AppsComposition.value(sort: .cpuPower, cpuPercent: nil, cpuPowerWatts: 0.42, locale: en, language: "en").text, "≈ 0.4 W")
        XCTAssertEqual(AppsComposition.value(sort: .cpuPower, cpuPercent: nil, cpuPowerWatts: 0.042, locale: en, language: "en").text, "≈ 0.04 W")
        XCTAssertEqual(AppsComposition.value(sort: .cpuPower, cpuPercent: nil, cpuPowerWatts: 0, locale: en, language: "en").text, "≈ 0.0 W")
        XCTAssertEqual(AppsComposition.value(sort: .cpuPower, cpuPercent: 80, cpuPowerWatts: nil).text, "—")
        XCTAssertEqual(AppsComposition.value(sort: .cpuPower, cpuPercent: 80, cpuPowerWatts: -1).text, "—")
        XCTAssertEqual(AppsComposition.value(sort: .cpuUsage, cpuPercent: 62.04, cpuPowerWatts: nil, locale: en, language: "en").text, "62.0 %")
        XCTAssertEqual(AppsComposition.value(sort: .cpuUsage, cpuPercent: 0, cpuPowerWatts: 1, locale: en, language: "en").text, "0.0 %")
        XCTAssertEqual(AppsComposition.value(sort: .cpuUsage, cpuPercent: nil, cpuPowerWatts: 1).text, "—")
        XCTAssertEqual(AppsComposition.inaccessibleCount(denied: 10, unavailable: 2), 12)
    }

    // MARK: Model and render

    private func makeModel(demo: Bool = false) -> (TilveroModel, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = TestDefaults.name("WindowApps"), defaults = TestDefaults.defaults(suite)
        let fixture = AppsProcessFixture()
        let current = WindowFixture.snapshot(at: Date(), level: 72, minutesAgo: 0)
        let model = demo
            ? TilveroModel(isDemo: true, preferences: defaults, newWindow: true)
            : TilveroModel(isDemo: false, preferences: defaults, historyURL: root.appendingPathComponent("history.sqlite"),
                           snapshotProvider: { current }, processActivityProvider: { await fixture.read() },
                           liveSampler: { nil }, newWindow: true)
        return (model, { model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) })
    }

    func testSampleFromTheModelFeedsTheLead() async throws {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        await model.waitForHistoryWork()   // the store opens before cleanup removes its folder
        await model.refreshProcessActivity(force: true)
        XCTAssertEqual(model.processActivity?.isWarmingUp, true)
        await model.refreshProcessActivity(force: true)
        let snapshot = try XCTUnwrap(model.processActivity)
        XCTAssertEqual(snapshot.rows.filter { AppsComposition.isHigh(cpuPercent: $0.cpuPercent) }.map(\.name).sorted(), ["Safari", "Xcode"])
        XCTAssertEqual(snapshot.accessibleCount, 23)
        XCTAssertEqual(AppsComposition.inaccessibleCount(denied: snapshot.deniedCount, unavailable: snapshot.unavailableCount), 12)
    }

    private func setLanguage(_ language: String, model: TilveroModel) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model.language = language
    }

    /// The page inside the production chrome: configured window, the real glass column, canvas, tint.
    private func makeWindow(model: TilveroModel, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MainWindowController.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let root = WindowThemeResolver {
            WindowShell(model: model) {
                AppsPage(model: model).background { WindowCanvas().ignoresSafeArea() }.tint(WindowTheme.accent)
            }
        }
        .environment(\.locale, L10n.locale).font(.system(size: 13)).id(model.language)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)   // gallery only
        window.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 720), display: true)
        return window
    }

    private func capture(_ window: NSWindow, _ name: String, into output: URL?) throws {
        guard let output else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit()
    }

    /// RU/EN × light/dark with a real sample, plus the simulation frame; PNGs only when `TILVERO_RENDER_OUT` is set.
    func testAppsGallery() async throws {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        await model.waitForHistoryWork()   // the store opens before cleanup removes its folder
        model.navigation.navigate(to: .section(.activity))
        await model.refreshProcessActivity(force: true)
        await model.refreshProcessActivity(force: true)
        XCTAssertEqual(model.processActivity?.rows.count, 4)
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let window = makeWindow(model: model, dark: dark)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(2))
                XCTAssertEqual(window.title, L10n.text("Apps (sidebar)"), "page title reaches the window toolbar")
                try capture(window, "apps-\(language)-\(dark ? "dark" : "light")", into: output)
                window.close()
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["AppsPage"] ?? 0, 1)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertNil(model.nativeCharge.observed)

        let (demo, demoCleanup) = makeModel(demo: true)
        defer { demoCleanup() }
        demo.navigation.navigate(to: .section(.activity))
        setLanguage("ru", model: demo)
        let window = makeWindow(model: demo, dark: false)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertNil(demo.processActivity, "simulation never reads processes")
        try capture(window, "apps-demo-ru-light", into: output)
        window.close()
    }
}
