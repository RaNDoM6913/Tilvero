// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
@testable import PowerPersistence
@testable import TilveroApp

/// Pure layers of the redesigned window: feature flags, theme resolver, display values, lead composition, notice
/// priority, section table, history series.
@MainActor final class WindowFoundationTests: XCTestCase {
    // MARK: Feature flags

    func testFlagsPerBuildKind() {
        let release = FeatureFlags.resolve(development: false, isDemo: false, canShowSetup: true, newWindowOverride: nil)
        XCTAssertEqual(release, FeatureFlags(modes: false, profilesAndSchedules: false, fanControls: false,
                                             simulationControls: false, setupPage: true, newWindow: true))
        let debug = FeatureFlags.resolve(development: true, isDemo: false, canShowSetup: true, newWindowOverride: nil)
        XCTAssertTrue(debug.modes && debug.profilesAndSchedules && debug.newWindow)
        XCTAssertEqual(debug.modes, debug.profilesAndSchedules, "Modes and profiles hide together")
        let laboratory = FeatureFlags.resolve(development: true, isDemo: false, canShowSetup: false, newWindowOverride: nil)
        XCTAssertFalse(laboratory.setupPage)
        let demo = FeatureFlags.resolve(development: false, isDemo: true, canShowSetup: false, newWindowOverride: nil)
        XCTAssertTrue(demo.simulationControls && demo.fanControls)
        XCTAssertFalse(demo.setupPage || demo.modes)
        XCTAssertTrue(demo.newWindow, "the redesigned window is the default without the launch argument")
        XCTAssertFalse(release.fanControls, "a release shows no fan controls")
        XCTAssertTrue(FeatureFlags.resolve(development: false, isDemo: false, canShowSetup: true, newWindowOverride: true).newWindow)
        XCTAssertFalse(FeatureFlags.resolve(development: true, isDemo: false, canShowSetup: true, newWindowOverride: false).newWindow)
        XCTAssertFalse(FeatureFlags.resolve(development: false, isDemo: false, canShowSetup: true, newWindowOverride: false).newWindow,
                       "-TilveroNewWindow NO brings the old window back in a release build")
    }

    func testNewWindowOverrideReadsOnlyLaunchArguments() {
        XCTAssertNil(FeatureFlags.newWindowOverride(arguments: [:]))
        XCTAssertEqual(FeatureFlags.newWindowOverride(arguments: ["TilveroNewWindow": "YES"]), true)
        XCTAssertEqual(FeatureFlags.newWindowOverride(arguments: ["TilveroNewWindow": "NO"]), false)
        XCTAssertEqual(FeatureFlags.newWindowOverride(arguments: ["TilveroNewWindow": NSNumber(value: true)]), true)
        XCTAssertNil(FeatureFlags.newWindowOverride(arguments: ["TilveroNewWindow": "maybe"]))
    }

    func testModelCarriesFlags() {
        let suite = TestDefaults.name("WindowFlags"), defaults = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        let model = TilveroModel(isDemo: true, preferences: defaults, developmentFeatures: false, newWindow: true)
        defer { model.stop() }
        XCTAssertTrue(model.features.newWindow)
        XCTAssertTrue(model.features.simulationControls)
        XCTAssertEqual(model.features.modes, model.developmentFeatures)
    }

    // MARK: Theme

    func testThemeResolverOverEightCombinations() {
        for dark in [false, true] {
            for reduce in [false, true] {
                for contrast in [false, true] {
                    let theme = WindowTheme.resolve(dark: dark, reduceTransparency: reduce, increaseContrast: contrast)
                    let label = "dark \(dark) reduce \(reduce) contrast \(contrast)"
                    XCTAssertEqual(theme.isDark, dark, label)
                    if reduce || contrast {
                        XCTAssertEqual(theme.tileFill.opacity, 1, "opaque tile: \(label)")
                        XCTAssertEqual(theme.tileStrokeWidth, 1, label)
                    } else {
                        XCTAssertLessThan(theme.tileFill.opacity, 1, label)
                        XCTAssertEqual(theme.tileStrokeWidth, 0.5, label)
                    }
                    XCTAssertEqual(theme.secondaryIsPrimary, contrast, label)
                    XCTAssertEqual(theme.canvasTop.opacity, 1, "canvas is opaque paint: \(label)")
                    let brightness = (theme.canvasBottom.red + theme.canvasBottom.green + theme.canvasBottom.blue) / 3
                    if dark { XCTAssertLessThan(brightness, 0.2, label) } else { XCTAssertGreaterThan(brightness, 0.9, label) }
                    if contrast { XCTAssertEqual(theme.tileStroke.opacity, 0.40, accuracy: 0.001, label) }
                }
            }
        }
        // The canvas is green-tinted: green leads the top colour in both schemes.
        for dark in [false, true] {
            let top = WindowTheme.resolve(dark: dark, reduceTransparency: false, increaseContrast: false).canvasTop
            XCTAssertGreaterThan(top.green, top.red)
            XCTAssertGreaterThan(top.green, top.blue)
        }
        XCTAssertEqual(WindowTheme.tileRadius, 12)
    }

    // MARK: Display values

    private func reading(_ id: String, _ value: CatalogValue?, unit: String? = nil, provenance: TelemetryProvenance = .measured,
                         availability: TelemetryAvailability? = nil, freshness: TelemetryFreshness = .fresh) -> CatalogReading {
        CatalogReading(definition: BatteryCatalog.definition(id), value: value, unit: unit, source: "fixture",
                       provenance: provenance, availability: availability, freshness: freshness)
    }

    func testReadingDisplayTable() {
        let ru = Locale(identifier: "ru_RU"), en = Locale(identifier: "en_US")
        // Missing is «—», never zero.
        XCTAssertEqual(ReadingDisplay.make(nil, fahrenheit: false, locale: ru, language: "ru").text, "—")
        XCTAssertEqual(ReadingDisplay.make(reading("054", nil), fahrenheit: false, locale: ru, language: "ru").text, "—")
        XCTAssertEqual(ReadingDisplay.make(reading("054", nil), fahrenheit: false).state, .unavailable)
        // A valid zero stays zero.
        XCTAssertEqual(ReadingDisplay.make(reading("054", .decimal(0)), fahrenheit: false, locale: ru, language: "ru").text, "0,0 Вт")
        XCTAssertEqual(ReadingDisplay.make(reading("038", .decimal(-0.01)), fahrenheit: false, magnitude: true, locale: en, language: "en").text, "0.0 W")
        XCTAssertEqual(ReadingDisplay.make(reading("054", .decimal(-0.04)), fahrenheit: false, locale: ru, language: "ru").text, "0,0 Вт", "never «-0,0»")
        XCTAssertEqual(ReadingDisplay.make(reading("054", .decimal(-0.06)), fahrenheit: false, locale: ru, language: "ru").text, "-0,1 Вт")
        // Locale separators and units.
        XCTAssertEqual(ReadingDisplay.make(reading("054", .decimal(18.6)), fahrenheit: false, locale: ru, language: "ru").text, "18,6 Вт")
        XCTAssertEqual(ReadingDisplay.make(reading("054", .decimal(18.6)), fahrenheit: false, locale: en, language: "en").text, "18.6 W")
        // Sign carried by the title.
        XCTAssertEqual(ReadingDisplay.make(reading("038", .decimal(-6.1)), fahrenheit: false, magnitude: true, locale: ru, language: "ru").number, "6,1")
        // Estimate.
        let estimate = ReadingDisplay.make(reading("026", .decimal(94.2), provenance: .estimated), fahrenheit: false, locale: ru, language: "ru")
        XCTAssertTrue(estimate.approximate)
        XCTAssertEqual(estimate.text, "≈ 94,2 %")
        // Stale keeps the value and says so.
        let stale = ReadingDisplay.make(reading("039", .decimal(32.4), freshness: .stale), fahrenheit: false, locale: ru, language: "ru")
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.number, "32,4")
        // Fahrenheit.
        XCTAssertEqual(ReadingDisplay.make(reading("039", .decimal(30)), fahrenheit: true, locale: en, language: "en").text, "86.0 °F")
        // Masked identifier.
        let serial = BatteryCatalog.definitions.first { $0.privacy == .sensitive }
        if let serial {
            let masked = ReadingDisplay.make(CatalogReading(definition: serial, value: .text("ABC123"), source: "fixture", freshness: .fresh),
                                             fahrenheit: false)
            XCTAssertTrue(masked.masked)
            XCTAssertEqual(masked.text, "••••••")
        }
    }

    func testDurationWords() {
        XCTAssertEqual(WindowDuration.text(minutes: 45, language: "ru"), "45 мин")
        XCTAssertEqual(WindowDuration.text(minutes: 60, language: "ru"), "1 ч")
        XCTAssertEqual(WindowDuration.text(minutes: 90, language: "ru"), "1 ч 30 мин")
        XCTAssertEqual(WindowDuration.text(minutes: 90, language: "en"), "1 h 30 min")
        XCTAssertEqual(WindowDuration.estimate(seconds: 1490, language: "ru"), "25 мин")
        XCTAssertEqual(WindowDuration.estimate(seconds: 30, language: "ru"), "5 мин")
        XCTAssertNil(WindowDuration.estimate(seconds: .infinity))
        XCTAssertNil(WindowDuration.estimate(seconds: 0))
    }

    // MARK: Lead

    func testOverviewLeadComposition() {
        let ruLocale = Locale(identifier: "ru_RU")
        var input = OverviewLeadInputs(level: 72, power: .charging, limit: 80, secondsToTarget: 1500, adapter: "96 Вт")
        var lead = OverviewLead.make(input, language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.value, "72 %")
        XCTAssertEqual(lead.tone, .accent)
        XCTAssertEqual(lead.detail, "до 80 % · ≈ 25 мин · адаптер 96 Вт")
        // Unavailable fragments are dropped, never printed as placeholders.
        input.secondsToTarget = nil; input.adapter = nil
        lead = OverviewLead.make(input, language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.detail, "до 80 %")
        // A limit at or below the level is not a target.
        input.limit = 70
        XCTAssertEqual(OverviewLead.make(input, language: "ru", locale: ruLocale).detail, "")
        // On battery with a forecast.
        // The forecast is a band: both ends are shown.
        lead = OverviewLead.make(OverviewLeadInputs(level: 64, power: .onBattery, forecastSeconds: 18_600...37_200), language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.tone, .battery)
        XCTAssertEqual(lead.detail, "до 20 % ≈ 5 ч 10 мин–10 ч 20 мин")
        lead = OverviewLead.make(OverviewLeadInputs(level: 20, power: .onBattery, forecastSeconds: 0...0), language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.detail, "", "already at 20 %: no forecast fragment")
        // Time to full (069) never sits next to a lower limit; without a limit it is the time shown.
        lead = OverviewLead.make(OverviewLeadInputs(level: 60, power: .charging, limit: 80, secondsToFull: 7200), language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.detail, "до 80 %")
        lead = OverviewLead.make(OverviewLeadInputs(level: 60, power: .charging, secondsToFull: 7200), language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.detail, "≈ 2 ч")
        // A connected adapter with an unknown charging state is not an unknown power source.
        lead = OverviewLead.make(OverviewLeadInputs(level: 60, power: .connectedStateUnknown), language: "en", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(lead.status, L10n.text("Connected, charging state unavailable"))
        // No level: «—» and a grey status.
        lead = OverviewLead.make(OverviewLeadInputs(level: nil, power: .charging), language: "ru", locale: ruLocale)
        XCTAssertEqual(lead.value, "—")
        XCTAssertEqual(lead.tone, .secondary)
        // Stale: orange status, the last read time, the value kept.
        let read = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: 2026, month: 11, day: 20, hour: 14, minute: 2))!
        lead = OverviewLead.make(OverviewLeadInputs(level: 72, stale: true, lastRead: read, power: .charging), language: "ru", locale: ruLocale)
        XCTAssertTrue(lead.stale)
        XCTAssertEqual(lead.tone, .attention)
        XCTAssertEqual(lead.detail, "последнее чтение 14:02")
    }

    // MARK: Notice priority

    func testNoticePriority() {
        var input = NoticeDisplay.Inputs(recoveryRequired: true, ownsSettings: true, attentionKey: "Native journal needs review", storeError: "x", notice: "y")
        XCTAssertEqual(NoticeDisplay.choose(input)?.action, .restore)
        input.recoveryRequired = false
        XCTAssertEqual(NoticeDisplay.choose(input)?.action, .returnControl, "normal ownership is not a fault")
        XCTAssertEqual(NoticeDisplay.choose(input)?.isWarning, false)
        input.ownsSettings = false
        XCTAssertEqual(NoticeDisplay.choose(input)?.action, .diagnostics)
        input.attentionKey = nil
        XCTAssertEqual(NoticeDisplay.choose(input)?.textKey, "Data store error")
        input.storeError = nil
        XCTAssertEqual(NoticeDisplay.choose(input)?.detail, "y")
        XCTAssertEqual(NoticeDisplay.choose(input)?.isWarning, false, "an action result is information")
        input.notice = nil
        XCTAssertNil(NoticeDisplay.choose(input))
    }

    // MARK: Sections

    func testSectionTableMatchesOwnerDecisions() {
        XCTAssertEqual(WindowSection.all.map(\.section), [.overview, .battery, .charging, .sleep, .cooling, .history, .activity, .diagnostics, .settings])
        XCTAssertEqual(Set(WindowSection.all.map(\.section)), Set(InfoSection.allCases), "every page is reachable")
        XCTAssertEqual(WindowSection.sections(in: .main).map(\.section), [.overview, .battery, .charging, .sleep, .cooling])
        XCTAssertEqual(WindowSection.sections(in: .insights).map(\.section), [.history, .activity])
        XCTAssertEqual(WindowSection.sections(in: .system).map(\.section), [.diagnostics, .settings])
        XCTAssertNil(WindowSidebarGroup.main.titleKey)
        XCTAssertEqual(WindowSection.shortcutIndex(.sleep), 4)
        for entry in WindowSection.all {
            XCTAssertNotNil(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil), entry.symbol)
        }
    }

    func testNewStringsHaveRussianAndKeepAwakeWording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        let keys = ["No data", "Insights", "System (sidebar group)", "Charging (sidebar)", "Apps (sidebar)", "Hour (range)",
                    "Day (range)", "Week (range)", "Power, W", "Charge, %", "Into battery", "From battery", "Input",
                    "On battery (lead)", "No measurements (chart)", "Fanless (cooling)", "+15 min"]
        func ru(_ key: String) -> String? {
            ((strings[key]?["localizations"] as? [String: Any])?["ru"] as? [String: Any]).flatMap { ($0["stringUnit"] as? [String: String])?["value"] }
        }
        for key in keys { XCTAssertNotNil(ru(key), key) }
        XCTAssertEqual(ru("Charging (sidebar)"), "Зарядка")
        XCTAssertEqual(ru("Apps (sidebar)"), "Приложения")
        for (key, _) in strings { XCTAssertFalse(ru(key)?.contains("Не спать") ?? false, key) }
    }

    // MARK: History series

    private func sample(_ date: Date, charge: Double?, power: Double? = nil, segment: UUID, external: Bool? = true) -> HistorySample {
        HistorySample(id: UUID(), collectedAt: date, monotonicTime: nil, timeZoneOffsetSeconds: 0, segmentID: segment,
                      chargePercent: charge, temperatureCelsius: nil, batteryPowerWatts: power, capacityRetentionPercent: nil,
                      cycleCount: nil, isCharging: nil, isExternalPower: external, isAggregate: false, aggregateCount: 1,
                      readings: [], observedFrom: date, coveredSeconds: 60, energyEvidenceVersion: nil,
                      chargedWh: nil, dischargedWh: nil, externalPowerSeconds: 0)
    }

    func testHistorySeriesKeepsGapsAndExtremes() {
        let now = Date(), segment = UUID()
        let window = now.addingTimeInterval(-86_400)...now
        var samples = (0..<60).map { sample(now.addingTimeInterval(Double(-7200 + $0 * 60)), charge: 50 + Double($0) / 10, segment: segment) }
        samples += (0..<10).map { sample(now.addingTimeInterval(Double(-600 + $0 * 60)), charge: 70, segment: segment) }
        samples.append(sample(now.addingTimeInterval(-300), charge: nil, segment: segment))
        let points = HistorySeries.points(samples, measurement: .charge, window: window)
        XCTAssertEqual(points.count, 70, "a sample without the value is not drawn as zero")
        XCTAssertEqual(Set(points.map(\.series)).count, 3, "a missing interval and a missing value both break the line")
        XCTAssertEqual(HistorySeries.gaps(points, minimum: 1800).count, 1)
        // Downsampling keeps extremes and never exceeds the cap.
        var dense = (0..<5000).map { HistoryChartPoint(id: UUID(), date: now.addingTimeInterval(Double(-5000 + $0)), value: 10, series: "a") }
        dense[2500] = HistoryChartPoint(id: UUID(), date: dense[2500].date, value: 99, series: "a")
        let reduced = HistorySeries.downsample(dense, window: now.addingTimeInterval(-5000)...now)
        XCTAssertLessThanOrEqual(reduced.count, HistorySeries.maximumBuckets)
        XCTAssertEqual(reduced.map(\.value).max(), 99)
        XCTAssertEqual(reduced.map(\.date), reduced.map(\.date).sorted())
        XCTAssertTrue(HistorySeries.downsample([], window: window).isEmpty)
        // Power-source change breaks a power line.
        let switched = [sample(now.addingTimeInterval(-120), charge: 50, power: 5, segment: segment, external: true),
                        sample(now.addingTimeInterval(-60), charge: 50, power: -5, segment: segment, external: false)]
        XCTAssertEqual(Set(HistorySeries.points(switched, measurement: .batteryPower, window: window).map(\.series)).count, 2)
        XCTAssertEqual(Set(HistorySeries.points(switched, measurement: .charge, window: window).map(\.series)).count, 1)
    }

    func testGapConnectorsJoinOnlySegmentEnds() {
        let now = Date()
        func point(_ offset: Double, _ value: Double, _ series: String) -> HistoryChartPoint {
            HistoryChartPoint(id: UUID(), date: now.addingTimeInterval(offset), value: value, series: series)
        }
        let line = WindowChartSeries(id: "charge", points: [point(0, 50, "a"), point(60, 51, "a"), point(4000, 60, "b"), point(4060, 61, "b")], color: .green)
        let gaps = WindowChartGap.connectors([line])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.start.value, 51)
        XCTAssertEqual(gaps.first?.end.value, 60)
        XCTAssertTrue(WindowChartGap.connectors([WindowChartSeries(id: "x", points: [point(0, 1, "a"), point(60, 2, "a")], color: .green)]).isEmpty)
    }

    func testYDomain() {
        XCTAssertEqual(HistorySeries.yDomain([18.6, 7.2]), 0...20)
        XCTAssertEqual(HistorySeries.yDomain([]), 0...10)
        XCTAssertEqual(HistorySeries.yDomain([-6.1, 3]), -10...10)
    }
}
