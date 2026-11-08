// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import PowerPersistence
import PowerTelemetry
@testable import TilveroApp

/// The provider closure is `@Sendable`; the box lets a test move the "latest" snapshot between refreshes.
final class SnapshotBox: @unchecked Sendable {
    var value: BatterySnapshot
    init(_ value: BatterySnapshot) { self.value = value }
}

/// A live-mode model over a temporary history store holding one battery-power / system / temperature / adapter sample a minute.
@MainActor struct SeriesFixture {
    let model: TilveroModel
    let box: SnapshotBox
    let base: Date
    let cleanup: () -> Void

    static func snapshot(at date: Date, minutesAgo: Double, adapterConnected: Bool) -> BatterySnapshot {
        func reading(_ id: String, _ value: Double, _ path: String) -> CatalogReading {
            CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(value), source: "fixture", keyPath: path, collectedAt: date, provenance: .measured)
        }
        var catalog = [reading("038", -10 + 2 * sin(minutesAgo / 6), "Voltage×Amperage"),
                       reading("039", 31 + sin(minutesAgo / 8), "Temperature"),
                       reading("043", 12 + sin(minutesAgo / 7), "SystemPowerIn")]
        if adapterConnected { catalog.append(reading("054", 7.5 + sin(minutesAgo / 9), "SystemPowerIn")) }
        return BatterySnapshot(chargePercent: .init(value: 62, source: "fixture"), isExternalPower: .init(value: adapterConnected, source: "fixture"),
                               collectedAt: date, catalog: catalog)
    }

    static func make(minutesOfHistory: Int = 55, adapterConnected: Bool = true) async throws -> SeriesFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TilveroSeries-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let url = root.appendingPathComponent("history.sqlite")
        let now = Date()
        let store = try BatteryHistoryStore(url: url)
        for minute in stride(from: Double(minutesOfHistory), to: 0, by: -1) {
            try store.record(snapshot(at: now.addingTimeInterval(-minute * 60), minutesAgo: minute, adapterConnected: adapterConnected))
        }
        try store.close()
        let box = SnapshotBox(snapshot(at: now, minutesAgo: 0, adapterConnected: adapterConnected))
        let model = TilveroModel(isDemo: false, preferences: defaults, historyURL: url, snapshotProvider: { box.value })
        await model.refresh()
        return SeriesFixture(model: model, box: box, base: now, cleanup: {
            model.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        })
    }
}

@MainActor final class MetricSeriesCacheTests: XCTestCase {
    private func assertEqual(_ a: MetricChartSeries, _ b: MetricChartSeries, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.points.map(\.id), b.points.map(\.id), message, file: file, line: line)
        XCTAssertEqual(a.points.map(\.value), b.points.map(\.value), message, file: file, line: line)
        XCTAssertEqual(a.points.map(\.date), b.points.map(\.date), message, file: file, line: line)
        XCTAssertEqual(a.points.map(\.series), b.points.map(\.series), message, file: file, line: line)
        XCTAssertEqual(a.gaps.map { [$0.start.id, $0.end.id] }, b.gaps.map { [$0.start.id, $0.end.id] }, message, file: file, line: line)
        XCTAssertEqual(a.isolatedPoints.map(\.id), b.isolatedPoints.map(\.id), message, file: file, line: line)
        XCTAssertEqual(a.staleSince, b.staleSince, message, file: file, line: line)
        XCTAssertEqual(a.state, b.state, message, file: file, line: line)
    }

    func testSeriesIsComputedOncePerRefresh() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        var counter = model.metricSeriesComputations
        for _ in 0..<5 { _ = model.metricSeries(id: "038") }
        XCTAssertEqual(model.metricSeriesComputations, counter + 1, "Five reads of one id between refreshes compute once.")
        counter = model.metricSeriesComputations
        _ = model.metricSeries(id: "054")
        _ = model.metricSeries(id: "054")
        _ = model.metricSeries(id: "038")
        XCTAssertEqual(model.metricSeriesComputations, counter + 1, "Another id computes once; the first id is still cached.")

        // A new snapshot (and the sample the refresh records) invalidates every id.
        fixture.box.value = SeriesFixture.snapshot(at: fixture.base.addingTimeInterval(60), minutesAgo: -1, adapterConnected: true)
        await model.refresh()
        counter = model.metricSeriesComputations
        _ = model.metricSeries(id: "038"); _ = model.metricSeries(id: "038")
        _ = model.metricSeries(id: "054"); _ = model.metricSeries(id: "054")
        XCTAssertEqual(model.metricSeriesComputations, counter + 2, "After a refresh each id recomputes once.")
    }

    func testHistoryChangeWithTheSameSnapshotRecomputes() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        XCTAssertFalse(model.metricSeries(id: "038").points.isEmpty)
        let collectedAt = model.snapshot.collectedAt
        let counter = model.metricSeriesComputations
        model.eraseHistory()
        XCTAssertEqual(model.snapshot.collectedAt, collectedAt, "Only the history changed.")
        XCTAssertTrue(model.metricSeries(id: "038").points.isEmpty, "A stale series must not survive an erase.")
        XCTAssertEqual(model.metricSeriesComputations, counter + 1)
    }

    func testMemoisedSeriesEqualsUncachedSeries() async throws {
        let fixture = try await SeriesFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        for id in ["038", "039", "043", "054"] {
            let window = model.overviewChartWindow
            let uncached = MetricChartSeries.make(points: PowerMetricHistory.points(model.history, id: id, since: window.lowerBound), window: window, now: model.snapshot.collectedAt)
            XCTAssertFalse(uncached.points.isEmpty, "\(id) has fixture data.")
            assertEqual(model.metricSeries(id: id), uncached, "first read of \(id)")
            assertEqual(model.metricSeries(id: id), uncached, "cached read of \(id)")
        }
    }
}
