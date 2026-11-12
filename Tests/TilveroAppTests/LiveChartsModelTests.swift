// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerTelemetry
@testable import TilveroApp

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

@MainActor final class LiveChartsModelTests: XCTestCase {
    private func make(isDemo: Bool = false, counter: Counter) -> (TilveroModel, () -> Void) {
        let suite = "LiveCharts-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: isDemo, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 liveSampler: {
                                     let i = counter.next()
                                     return LivePowerSample(collectedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                                                            systemWatts: Double(i), adapterWatts: 10, temperatureCelsius: 33)
                                 })
        return (model, { model.stop(); prefs.removePersistentDomain(forName: suite) })
    }

    func testLiveTicksFeedTheOverviewSeriesOnlyWhileTheMenuIsOpenOnOverview() async {
        let counter = Counter(); let (model, cleanUp) = make(counter: counter); defer { cleanUp() }
        XCTAssertFalse(model.wantsLiveCharts, "Closed menu: nothing is read.")
        await model.liveTick()
        XCTAssertEqual(counter.value, 0)

        model.isPopoverVisible = true; model.quickPanelSection = .overview
        XCTAssertTrue(model.wantsLiveCharts)
        for _ in 0..<3 { await model.liveTick() }
        XCTAssertGreaterThanOrEqual(counter.value, 3)
        let series = model.metricSeries(id: "043")
        XCTAssertEqual(series.points.last?.value, Double(model.liveTail.points(id: "043").count), "The newest chart point is the newest live reading.")
        XCTAssertEqual(model.overviewChartWindow.upperBound, model.liveTail.latest, "The window follows the live data.")
        XCTAssertEqual(series.state, .data)

        let before = counter.value
        model.quickPanelSection = .awake
        XCTAssertFalse(model.wantsLiveCharts, "Another page: no reads.")
        await model.liveTick()
        XCTAssertEqual(counter.value, before)
        model.quickPanelSection = .overview; model.isPopoverVisible = false
        XCTAssertFalse(model.wantsLiveCharts, "Closed menu again: no reads.")
    }

    func testDemoNeverReadsSensors() async {
        let counter = Counter(); let (model, cleanUp) = make(isDemo: true, counter: counter); defer { cleanUp() }
        model.isPopoverVisible = true; model.quickPanelSection = .overview
        XCTAssertFalse(model.wantsLiveCharts)
        await model.liveTick()
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(model.liveTail.isEmpty)
    }

    func testEachLivePointInvalidatesTheSeriesCacheOnce() async {
        let counter = Counter(); let (model, cleanUp) = make(counter: counter); defer { cleanUp() }
        model.isPopoverVisible = true; model.quickPanelSection = .overview
        await model.liveTick()
        _ = model.metricSeries(id: "043"); _ = model.metricSeries(id: "043")
        let afterFirst = model.metricSeriesComputations
        await model.liveTick()
        _ = model.metricSeries(id: "043"); _ = model.metricSeries(id: "043")
        XCTAssertEqual(model.metricSeriesComputations, afterFirst + 1, "Rebuilt once per tick, then served from the cache.")
    }

    func testOneTickIsCheap() async {
        let counter = Counter(); let (model, cleanUp) = make(counter: counter); defer { cleanUp() }
        model.isPopoverVisible = true; model.quickPanelSection = .overview
        for _ in 0..<600 { await model.liveTick() }           // a full ten-minute tail
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            await model.liveTick()
            for id in ["038", "039", "043", "054"] { _ = model.metricSeries(id: id) }
        }
        let perTick = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1e6
        print("LIVE tick + four series rebuilds: \(perTick) ms")
        XCTAssertLessThan(perTick, 25, "Far below the one-second budget.")
    }
}
