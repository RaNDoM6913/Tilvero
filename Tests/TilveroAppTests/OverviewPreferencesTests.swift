// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class OverviewPreferencesTests: XCTestCase {
    func testPreferencesPersistWithoutMutatingTelemetryOrControl() async throws {
        let suite = TestDefaults.name("Overview"), preferences = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let telemetry = model.snapshot, control = model.control
        model.overviewPreferences.hidden.insert(.temperature)
        model.overviewPreferences.move(.history, by: -1)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.overviewPreferences, model.overviewPreferences)
        XCTAssertEqual(model.snapshot.chargePercent, telemetry.chargePercent)
        XCTAssertEqual(model.control?.charge, control?.charge)
        XCTAssertNil(model.nativeCharge.observed)
    }
    func testCorruptOrDuplicateOrderCannotHideOrDuplicateTheWholePanel() throws {
        XCTAssertEqual(OverviewPreferences.load(Data("bad".utf8)), .init())
        var duplicate = OverviewPreferences(); duplicate.order = [.forecast,.forecast]
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(duplicate)), .init())
    }
    func testChartMetricsAlwaysDrawChartsAndLegacyStylesAreIgnored() throws {
        let old = OverviewPreferences.load(Data(#"{"order":["history","power"],"hidden":["temperature"],"chartStyles":{"power":"sparkline","nonsense":"x"}}"#.utf8))
        for metric in OverviewMetric.allCases {
            XCTAssertEqual(old.chartStyle(for: metric), metric.supportsChartStyle ? .chart : .sparkline)
        }
        XCTAssertEqual(old.order.prefix(2).map(\.rawValue), ["history", "power"])
        XCTAssertTrue(old.hidden.contains(.temperature))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(old), encoding: .utf8))
        XCTAssertFalse(encoded.contains("chartStyles"), "The legacy key is dropped on the next save.")
        let wrongType = OverviewPreferences.load(Data(#"{"order":["history","power"],"chartStyles":[1,2]}"#.utf8))
        XCTAssertEqual(wrongType.order.prefix(2).map(\.rawValue), ["history", "power"])
    }
    func testFirstRunDefaultIsTheOwnerChosenStarterPage() {
        let value = OverviewPreferences.firstRunDefault
        let visible: [OverviewMetric] = [.keepAwake, .powerCombined, .temperature, .batteryHealth]
        XCTAssertEqual(Array(value.order.prefix(4)), visible)
        XCTAssertEqual(value.order.dropFirst(4).map(\.self), OverviewMetric.allCases.filter { !visible.contains($0) }, "the rest keeps its existing order")
        XCTAssertEqual(Set(value.order), Set(OverviewMetric.allCases))
        XCTAssertEqual(value.hidden, Set(OverviewMetric.allCases).subtracting(visible))
        XCTAssertEqual(value.chartSize, .strip)
        let decoded = OverviewPreferences.load(try? JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value, "survives the store")
    }
    func testUntouchedPreferencesKeepTheirOldDefault() {
        let old = OverviewPreferences()
        XCTAssertEqual(old.order, OverviewMetric.allCases)
        XCTAssertEqual(old.hidden, [.keepAwake, .systemPower, .adapter, .batteryHealth, .applications, .keyboardBacklight, .powerTiles, .powerCombined])
        XCTAssertEqual(old.chartSize, .moderate)
        XCTAssertNotEqual(old, .firstRunDefault)
        XCTAssertEqual(OverviewPreferences.load(nil), old, "no stored value still loads the old page")
    }
    func testTheFirstRunLayoutIsWrittenOnlyWhenNothingIsStored() throws {
        let suite = TestDefaults.name("OverviewFirstRun"), preferences = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        let fresh = TilveroModel(isDemo: false, preferences: preferences)
        defer { fresh.stop() }
        XCTAssertEqual(fresh.overviewPreferences, OverviewPreferences(), "nothing changes before the first run")
        XCTAssertNil(preferences.data(forKey: "overviewPreferences.v1"))
        XCTAssertTrue(fresh.applyFirstRunOverviewLayout())
        XCTAssertEqual(fresh.overviewPreferences, .firstRunDefault)
        let reopened = TilveroModel(isDemo: false, preferences: preferences)
        defer { reopened.stop() }
        XCTAssertEqual(reopened.overviewPreferences, .firstRunDefault, "persisted JSON decodes to the same value")
        // A stored layout (here the starter page, moved) is never overwritten.
        reopened.overviewPreferences.move(.temperature, by: -1)
        let customised = reopened.overviewPreferences
        XCTAssertFalse(reopened.applyFirstRunOverviewLayout())
        XCTAssertEqual(reopened.overviewPreferences, customised)
    }
    func testAnExistingStoredLayoutIsNeverReplacedAndDemoIsLeftAlone() throws {
        let suite = TestDefaults.name("OverviewKept"), preferences = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        preferences.set(try JSONEncoder().encode(OverviewPreferences()), forKey: "overviewPreferences.v1")   // even the old default, explicitly stored
        let model = TilveroModel(isDemo: false, preferences: preferences)
        defer { model.stop() }
        XCTAssertFalse(model.applyFirstRunOverviewLayout())
        XCTAssertEqual(model.overviewPreferences, OverviewPreferences())
        let demoSuite = TestDefaults.name("OverviewDemo"), demoPreferences = TestDefaults.defaults(demoSuite)
        defer { TestDefaults.remove(demoSuite) }
        let demo = TilveroModel(isDemo: true, preferences: demoPreferences)
        defer { demo.stop() }
        XCTAssertFalse(demo.applyFirstRunOverviewLayout())
        XCTAssertNil(demoPreferences.data(forKey: "overviewPreferences.v1"))
    }
}
