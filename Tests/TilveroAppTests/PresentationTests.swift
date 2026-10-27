import XCTest
@testable import TilveroApp
import PowerCore

final class PresentationTests: XCTestCase {
    func testFreshUnplugCannotBePresentedAsChargingFromStaleCachedFlag() {
        let snapshot = BatterySnapshot(isCharging: .init(value: true, source: "old", availability: .temporarilyUnavailable, freshness: .stale), isExternalPower: .init(value: false, source: "new", freshness: .fresh))
        XCTAssertFalse(ReadingPresentation.isCurrentlyCharging(snapshot))
        XCTAssertEqual(ReadingPresentation.chargingStateKey(snapshot), "On battery")
    }
    func testInvalidReadingCannotAppearAsMeasuredZero() {
        let reading = TelemetryReading<Double>(value: 0, source: "fixture", availability: .invalid)
        XCTAssertNil(ReadingPresentation.number(reading))
        XCTAssertNotNil(ReadingPresentation.number(TelemetryReading(value: 0.0, source: "fixture")))
    }
    func testNonfiniteReadingCannotReachNumberFormatter() {
        XCTAssertNil(ReadingPresentation.number(TelemetryReading(value: Double.infinity, source: "fixture")))
    }
    func testFreshnessAndUnknownLevelAreVisibleInAccessibleSummary() {
        XCTAssertTrue(ReadingPresentation.ageLabel(collectedAt: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 220), language: "en").contains("120"))
        XCTAssertEqual(ReadingPresentation.validLevel(-1), nil)
        XCTAssertEqual(ReadingPresentation.validLevel(101), nil)
        XCTAssertEqual(ReadingPresentation.validLevel(0), 0)
    }
    func testLocalePercentageInputDoesNotCoerceUnsupportedValues() {
        XCTAssertEqual(ReadingPresentation.percentInput(" ８５ ", acceptedTargets: [80,85,90,100]), 85)
        XCTAssertNil(ReadingPresentation.percentInput("85.5", acceptedTargets: [80,85,90,100]))
        XCTAssertNil(ReadingPresentation.percentInput("81", acceptedTargets: [80,85,90,100]))
    }
}

final class HistoryChartTests: XCTestCase {
    func testMissingMetricAndBatteryBoundaryBreakLineButAdjacentValuesStayJoined() {
        let origin = Date(timeIntervalSince1970: 100)
        let readings: [ChartObservation] = [
            .init(id: UUID(), date: origin, value: 30, continuityID: "battery-A"),
            .init(id: UUID(), date: origin.addingTimeInterval(60), value: nil, continuityID: "battery-A"),
            .init(id: UUID(), date: origin.addingTimeInterval(120), value: 31, continuityID: "battery-A"),
            .init(id: UUID(), date: origin.addingTimeInterval(180), value: 32, continuityID: "battery-A"),
            .init(id: UUID(), date: origin.addingTimeInterval(240), value: 28, continuityID: "battery-B")
        ]
        let points = HistoryChart.points(readings)
        XCTAssertEqual(points.map(\.value), [30,31,32,28])
        XCTAssertNotEqual(points[0].series, points[1].series)
        XCTAssertEqual(points[1].series, points[2].series)
        XCTAssertNotEqual(points[2].series, points[3].series)
    }
}

final class ControlCatalogTests: XCTestCase {
    func testPendingIntentCannotBecomeEffectiveReadbackOrSurviveMissingConnectionAsKnown() {
        var state = ChargePolicyState(); state.requested = .ceiling(80); state.appliedTarget = 100; state.pendingTarget = 80
        let rows = ControlCatalog.readings(state: state, capabilities: [], fans: nil, isDemo: false, connected: true, at: Date())
        XCTAssertEqual(rows.first { $0.id == "018" }?.value?.doubleValue, 80)
        XCTAssertEqual(rows.first { $0.id == "020" }?.value?.doubleValue, 100)
        let disconnected = ControlCatalog.readings(state: state, capabilities: [], fans: nil, isDemo: false, connected: false, at: Date())
        XCTAssertNil(disconnected.first { $0.id == "020" }?.value)
    }
}
