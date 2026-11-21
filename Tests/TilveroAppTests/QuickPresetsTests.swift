// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

/// A model whose Keep Awake and sleep timer run on in-memory fakes (no assertion, no sleep request, no pmset).
@MainActor struct PresetFixture {
    let model: TilveroModel
    let preferences: UserDefaults
    let cleanup: () -> Void

    static func make(presets: QuickPresets? = nil, prepare: (UserDefaults) -> Void = { _ in }) -> PresetFixture {
        let suite = TestDefaults.name("QuickPresets"), prefs = TestDefaults.defaults(suite)
        prefs.set(false, forKey: "historyEnabled")
        if let presets { prefs.set(try! JSONEncoder().encode(presets), forKey: QuickPresetStore.key) }
        prepare(prefs)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "Quick presets fixture") },
                                 keepAwakeService: KeepAwakeService(driver: AwakeFixture()),
                                 sleepTimerService: SleepTimerService(driver: CountdownTimerTransport(), allowed: true),
                                 lidSleepSystem: CountdownLid())
        return PresetFixture(model: model, preferences: prefs, cleanup: {
            model.stop(); TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class QuickPresetsTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]
    override func setUp() async throws { savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain) }
    override func tearDown() async throws { UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain) }
    private func setLanguage(_ language: String) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
    }

    // MARK: Defaults, normalisation, versions

    func testDefaultsAreTheListsTheQuickMenuShowedBefore() {
        let value = QuickPresets.defaults
        XCTAssertEqual(value.sleepTimer, [15, 30, 60])
        XCTAssertEqual(value.keepAwake, [15, 30, 60, 120, 240, 480])
        XCTAssertEqual(value.keepAwake, KeepAwakeDuration.allCases.map(\.rawValue))
        XCTAssertEqual(value.overviewAwake, [15, 30, 60, 240])
        XCTAssertEqual(value.sleepAtCharge, [50, 30, 20, 10, 5])
        XCTAssertEqual(value.awakeUntilCharge, [50, 30, 20, 10, 5])
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value, value.normalized(), "the defaults are already normal")
    }

    func testNormalisationDropsOutOfRangeDuplicatesSortsCutsAndRefillsEmptyRows() {
        XCTAssertEqual(QuickPresets.normalize([60, 0, 15, 1441, 15, 30, -5], row: .sleepTimer), [15, 30, 60])
        XCTAssertEqual(QuickPresets.normalize(Array(1...20), row: .sleepTimer), Array(1...7), "cut to the maximum of 7")
        XCTAssertEqual(QuickPresets.normalize(Array(1...20), row: .keepAwake).count, 6)
        XCTAssertEqual(QuickPresets.normalize(Array(1...20), row: .overviewAwake), [1, 2, 3, 4])
        XCTAssertEqual(QuickPresets.normalize([5, 95, 50, 50, 7, 100, 0], row: .sleepAtCharge), [95, 50, 5], "levels descend, steps of 5")
        XCTAssertEqual(QuickPresets.normalize([], row: .awakeUntilCharge), QuickPresets.defaults.awakeUntilCharge)
        XCTAssertEqual(QuickPresets.normalize([0, 2000], row: .keepAwake), QuickPresets.defaults.keepAwake, "emptied → default")
        XCTAssertEqual(QuickPresets.normalize(stride(from: 95, through: 5, by: -5).map { $0 }, row: .sleepAtCharge), [95, 90, 85, 80, 75, 70])
    }

    func testRangesAreTheServicesBounds() {
        for row in [QuickPresets.Row.sleepTimer, .keepAwake, .overviewAwake] {
            XCTAssertTrue(row.accepts(1)); XCTAssertTrue(row.accepts(1440))
            XCTAssertFalse(row.accepts(0)); XCTAssertFalse(row.accepts(1441))
        }
        for row in [QuickPresets.Row.sleepAtCharge, .awakeUntilCharge] {
            XCTAssertEqual(row.legalLevels, Array(stride(from: 95, through: 5, by: -5)))
            XCTAssertFalse(row.accepts(0)); XCTAssertFalse(row.accepts(100)); XCTAssertFalse(row.accepts(12))
        }
        XCTAssertEqual(QuickPresets.Row.allCases.map(\.maximum), [7, 6, 6, 6, 4])
    }

    func testLoadHandlesMissingDamagedNewerAndPartialPayloads() throws {
        XCTAssertEqual(QuickPresets.load(nil), .defaults)
        XCTAssertEqual(QuickPresets.load(Data("not json".utf8)), .defaults)
        XCTAssertEqual(QuickPresets.load(Data(#"{"version":1,"sleepTimer":"x"}"#.utf8)), .defaults, "a wrong type damages the payload")
        XCTAssertEqual(QuickPresets.load(Data(#"{"sleepTimer":[5]}"#.utf8)), .defaults, "no version is damaged")
        XCTAssertEqual(QuickPresets.load(Data(#"{"version":2,"sleepTimer":[5]}"#.utf8)), .defaults, "a newer build's payload")
        let partial = QuickPresets.load(Data(#"{"version":1,"sleepTimer":[90,5,5,2000]}"#.utf8))
        XCTAssertEqual(partial.sleepTimer, [5, 90], "normalised on load")
        XCTAssertEqual(partial.keepAwake, QuickPresets.defaults.keepAwake, "a missing row takes its default")
    }

    func testStorePersistsResetsAndLeavesANewerPayloadUntouched() throws {
        let suite = TestDefaults.name("PresetStore"), prefs = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        let newer = Data(#"{"version":9,"future":true}"#.utf8)
        prefs.set(newer, forKey: QuickPresetStore.key)
        let store = QuickPresetStore(defaults: prefs)
        XCTAssertEqual(store.presets, .defaults)
        XCTAssertEqual(prefs.data(forKey: QuickPresetStore.key), newer, "nothing is written until the user edits")
        store.set(.sleepTimer, [90, 45, 45, 0])
        XCTAssertEqual(store.presets.sleepTimer, [45, 90])
        XCTAssertEqual(QuickPresetStore(defaults: prefs).presets.sleepTimer, [45, 90], "saved as quickPresets.v1")
        prefs.set(Data("{}".utf8), forKey: "overviewPreferences.v1")
        store.resetToDefaults()
        XCTAssertEqual(store.presets, .defaults)
        XCTAssertNil(prefs.object(forKey: QuickPresetStore.key))
        XCTAssertNotNil(prefs.object(forKey: "overviewPreferences.v1"), "resetting presets leaves the blocks alone")
    }

    // MARK: Labels

    func testLabelsRussianAndEnglishIncludingTheNarrowForm() {
        let cases: [(Int, String, String, String)] = [
            (45, "45 мин", "45 min", "45 мин"), (60, "1 ч", "1 h", "1 ч"), (90, "1 ч 30 мин", "1 h 30 min", "1 ч 30"),
            (120, "2 ч", "2 h", "2 ч"), (599, "9 ч 59 мин", "9 h 59 min", "9 ч 59"), (630, "10 ч 30", "10 h 30", "10 ч 30"),
            (1439, "23 ч 59", "23 h 59", "23 ч 59"), (1440, "24 ч", "24 h", "24 ч"), (1, "1 мин", "1 min", "1 мин"),
        ]
        for (minutes, ru, en, narrow) in cases {
            XCTAssertEqual(PresetLabel.duration(minutes, language: "ru"), ru)
            XCTAssertEqual(PresetLabel.duration(minutes, language: "en"), en)
            XCTAssertEqual(PresetLabel.duration(minutes, form: .narrow, language: "ru"), narrow)
        }
        XCTAssertEqual(PresetLabel.level(50), "50 %")
        XCTAssertEqual(PresetLabel.spokenDuration(90, language: "ru"), "1 час 30 минут")
        XCTAssertEqual(PresetLabel.spokenDuration(121, language: "ru"), "2 часа 1 минута")
        XCTAssertEqual(PresetLabel.spokenDuration(660, language: "ru"), "11 часов")
        XCTAssertEqual(PresetLabel.spokenDuration(22, language: "ru"), "22 минуты")
        XCTAssertEqual(PresetLabel.spokenDuration(90, language: "en"), "1 hour 30 minutes")
        XCTAssertEqual(PresetLabel.spokenDuration(1, language: "en"), "1 minute")
        XCTAssertEqual(PresetLabel.spokenLevel(50, language: "ru"), "50 процентов")
        XCTAssertEqual(PresetLabel.spokenLevel(5, language: "en"), "5 percent")
    }

    /// Every legal label fits its cell at SF 12 pt medium (AppKit text measurement), without the 0.8 scale safety net.
    func testEveryLegalLabelFitsItsCellWidth() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let grid: CGFloat = (312 - 3 * 6) / 4            // 73.5
        let strip: CGFloat = (232 - 6 - 3 * 2) / 4        // 55.0: four segments in the 232 pt track (3 pt padding, 2 pt gaps)
        let level: CGFloat = (312 - 5 * 6) / 6            // 47.0
        for language in ["ru", "en"] {
            var widest: CGFloat = 0, widestNarrow: CGFloat = 0
            for minutes in 1...1440 {
                let label = PresetLabel.duration(minutes, language: language)
                widest = max(widest, width(label, font))
                XCTAssertLessThanOrEqual(width(label, font), grid, label)
                let narrow = PresetLabel.duration(minutes, form: .narrow, language: language)
                widestNarrow = max(widestNarrow, width(narrow, font))
                XCTAssertLessThanOrEqual(width(narrow, font), strip, narrow)
            }
            print("\(language): widest grid label \(widest), widest strip label \(widestNarrow)")
            for levelValue in stride(from: 5, through: 95, by: 5) {
                XCTAssertLessThanOrEqual(width(PresetLabel.level(levelValue), font), level)
            }
            for tail in [language == "ru" ? "Своё" : "Custom", language == "ru" ? "До…" : "Until…", "∞"] {
                XCTAssertLessThanOrEqual(width(tail, font), grid, tail)
            }
        }
        let countdownFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        XCTAssertLessThanOrEqual(width("23:59:59", countdownFont), grid, "the running countdown fits a grid cell")
    }

    // MARK: Selection and remembered choices

    func testSelectionFollowsTheAppliedDurationAndTheCustomLists() throws {
        let f = PresetFixture.make(presets: QuickPresets(sleepTimer: [45, 90], keepAwake: [45, 90], overviewAwake: [45],
                                                          sleepAtCharge: [40], awakeUntilCharge: [40]))
        defer { f.cleanup() }
        let model = f.model
        try SleepPillActions.awake(model, request: .duration(45))
        XCTAssertEqual(SleepPillActions.awakeSelection(model), .preset(45))
        XCTAssertEqual(SleepPillActions.awakeSelection(model, presets: model.quickPresets.presets.overviewAwake), .preset(45))
        model.quickPresets.set(.keepAwake, [30, 90])
        XCTAssertEqual(SleepPillActions.awakeSelection(model), .custom, "its preset removed meanwhile: no pill, the countdown line")
        XCTAssertEqual(model.keepAwake.appliedPillDurationSeconds, 45 * 60, "editing presets never changes a running session")
        try SleepPillActions.awake(model, request: .duration(15))
        XCTAssertEqual(SleepPillActions.awakeSelection(model), .custom, "a duration off the list")
        try model.keepAwake.stop()

        try model.selectSleepTimer(minutes: 90)
        XCTAssertEqual(SleepPillActions.timerSelection(model), .preset(90))
        model.quickPresets.set(.sleepTimer, [45])
        XCTAssertEqual(SleepPillActions.timerSelection(model), .custom, "«Своё» shows a timer no longer listed")
        XCTAssertEqual(model.sleepTimer.activePillMinutes, 90)
        model.sleepTimer.cancel()
    }

    func testRememberedLevelFallsBackToTheListedLevels() {
        let f = PresetFixture.make(presets: QuickPresets(sleepTimer: [15], keepAwake: [15], overviewAwake: [15],
                                                          sleepAtCharge: [60, 40, 10], awakeUntilCharge: [35, 25])) {
            $0.set(50, forKey: "sleepAtChargeTarget")
        }
        defer { f.cleanup() }
        XCTAssertEqual(f.model.sleepAtChargeChoice, 60, "50 is no longer listed: the highest listed level")
        XCTAssertEqual(f.preferences.integer(forKey: "sleepAtChargeTarget"), 50, "the remembered choice itself is kept")
        XCTAssertEqual(f.model.keepAwakeUntilChargeChoice, 35, "nothing remembered and 20 not listed")
        f.model.quickPresets.set(.sleepAtCharge, [50, 10])
        XCTAssertEqual(f.model.sleepAtChargeChoice, 50, "listed again: remembered")
        f.model.quickPresets.resetToDefaults()
        XCTAssertEqual(f.model.keepAwakeUntilChargeChoice, 20, "today's default level")
        XCTAssertEqual(f.model.sleepAtCharge.levels(), QuickPresets.defaults.sleepAtCharge, "the service reads the list")
    }

    func testCustomFlagsReadTheLists() {
        let f = PresetFixture.make(presets: QuickPresets(sleepTimer: [45], keepAwake: [45], overviewAwake: [45],
                                                          sleepAtCharge: [40], awakeUntilCharge: [40])) {
            $0.set(45, forKey: "sleepTimerMinutes"); $0.set(45, forKey: "keepAwakeMinutes")
        }
        defer { f.cleanup() }
        XCTAssertFalse(f.model.sleepTimerUsesCustom)
        XCTAssertFalse(f.model.keepAwakeUsesCustomDuration)
        f.model.keepAwakeDuration = KeepAwakeDuration(rawValue: 30)!
        XCTAssertTrue(f.model.keepAwakeUsesCustomDuration)
    }

    // MARK: Popover height

    /// Rows follow the configuration: up to four cells is one row, five to eight two rows (one pill + 6 pt more).
    func testPopoverHeightGrowsByOnePillRowForTwoRows() {
        setLanguage("en")
        func height(_ presets: QuickPresets?) -> CGFloat {
            let f = PresetFixture.make(presets: presets)
            defer { f.cleanup() }
            let host = NSHostingController(rootView: QuickPanel(model: f.model, maximumHeight: 2000, section: .awake))
            return host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 2000)).height
        }
        let base = height(nil)
        var four = QuickPresets.defaults; four.sleepTimer = [10, 20, 30]
        XCTAssertEqual(height(four), base, accuracy: 0.5, "three presets + «Своё»: one row")
        var five = QuickPresets.defaults; five.sleepTimer = [10, 20, 30, 45]
        let twoRows = height(five)
        XCTAssertEqual(twoRows - base, 36 + 6, accuracy: 1, "a second row of 36 pt pills and 6 pt spacing")
        var eight = QuickPresets.defaults; eight.sleepTimer = [5, 10, 20, 30, 45, 60, 90]
        XCTAssertEqual(height(eight), twoRows, accuracy: 0.5, "eight cells are still two rows")

    }
}
