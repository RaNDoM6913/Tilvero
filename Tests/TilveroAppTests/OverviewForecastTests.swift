import XCTest
@testable import TilveroApp
import PowerCore
import PowerTelemetry

final class OverviewForecastTests: XCTestCase {
    func testNormalizedSnapshotQualifiesForecastInputs() {
        let provider = MacBatteryProvider(identitySalt: "salt")
        let now = Date()
        func normalized(_ state: String) -> BatterySnapshot {
            provider.normalize(powerSource: ["Current Capacity": 80, "Max Capacity": 100, "Is Charging": false, "Power Source State": state],
                               registry: ["Serial": "S1"], at: now, uptime: 1000)
        }
        let battery = DischargeForecast.currentInputs(normalized("Battery Power"))
        XCTAssertEqual(battery.percent, 80); XCTAssertTrue(battery.fresh, "Live IOPS rows have unknown source freshness but are app-observed.")
        XCTAssertTrue(battery.onBattery)
        XCTAssertFalse(DischargeForecast.currentInputs(normalized("AC Power")).onBattery)
        XCTAssertFalse(DischargeForecast.currentInputs(normalized("unexpected")).onBattery)
        let retained = provider.normalize(powerSource: nil, registry: ["Serial": "S1"], at: now.addingTimeInterval(5), uptime: 1005)
            .retainingPreviousReadings(normalized("Battery Power"))
        XCTAssertFalse(DischargeForecast.currentInputs(retained).fresh, "A retained display value is not a current observation.")
        let fixture = BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: now, freshness: .unknown),
                                      isExternalPower: .init(value: false, source: "fixture", collectedAt: now, freshness: .unknown), collectedAt: now)
        let unknown = DischargeForecast.currentInputs(fixture)
        XCTAssertFalse(unknown.fresh); XCTAssertFalse(unknown.onBattery)
        let fresh = BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: now),
                                    isExternalPower: .init(value: false, source: "fixture", collectedAt: now), collectedAt: now)
        XCTAssertTrue(DischargeForecast.currentInputs(fresh).fresh); XCTAssertTrue(DischargeForecast.currentInputs(fresh).onBattery)
    }
    func testQualifiedContinuousDischargeProducesAnUncertainRange() throws {
        let now = Date()
        let samples = (0...15).map { index in
            DischargeForecast.Sample(date: now.addingTimeInterval(Double(index - 15) * 60), percent: 84 - Double(index) / 3,
                                     segment: "one", externalPower: false, charging: false, monotonic: Double(index) * 60)
        }
        let value = try XCTUnwrap(DischargeForecast.estimate(samples, currentPercent: 79, currentFresh: true, onBattery: true, now: now))
        XCTAssertGreaterThan(value.lowerSeconds, 0)
        XCTAssertLessThan(value.lowerSeconds, value.upperSeconds)
        XCTAssertGreaterThan(value.upperSeconds, 3 * 3600)
    }
    func testInsufficientRoundedLossAndFreshnessCannotInventAnETA() {
        let now = Date()
        let values = (0...15).map { DischargeForecast.Sample(date: now.addingTimeInterval(Double($0 - 15) * 60), percent: 80, segment: "one", externalPower: false, charging: false, monotonic: Double($0) * 60) }
        XCTAssertNil(DischargeForecast.estimate(values, currentPercent: 80, currentFresh: true, onBattery: true, now: now))
        XCTAssertNil(DischargeForecast.estimate(values, currentPercent: 80, currentFresh: false, onBattery: true, now: now))
        XCTAssertNil(DischargeForecast.estimate(values, currentPercent: 80, currentFresh: true, onBattery: false, now: now))
    }
    func testPowerSleepReplacementAndClockBoundariesBreakForecastCoverage() {
        let now = Date()
        for boundary in 0...3 {
            var samples: [DischargeForecast.Sample] = []
            for index in 0...15 {
                let date = now.addingTimeInterval(Double(index - 15) * 60)
                let percent = 90.0 - Double(index)
                let segment = boundary == 0 && index > 10 ? "new" : "one"
                let external = boundary == 1 && index == 10
                let stamp = boundary == 2 && index == 10 ? -100.0 : Double(index) * 60
                let aggregate = boundary == 3 && index == 10
                samples.append(.init(date: date, percent: percent, segment: segment, externalPower: external,
                                     charging: false, monotonic: stamp, aggregate: aggregate))
            }
            XCTAssertNil(DischargeForecast.estimate(samples, currentPercent: 75, currentFresh: true, onBattery: true, now: now))
        }
    }
}
