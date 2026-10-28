import XCTest
import PowerCore
@testable import PowerTelemetry

final class PowerChannelsTests: XCTestCase {
    func testSystemLoadStaysDistinctFromAdapterInputAndRetainsUnknownSensorAge() {
        let snapshot = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:],
            registry: ["PowerTelemetryData":["SystemLoad":4200,"SystemPowerIn":5300,"BatteryPower":1100]], adapter: ["Watts":30])
        let load = snapshot.catalog.first { $0.id == "043" }
        XCTAssertEqual(load?.value?.doubleValue, 4.2)
        XCTAssertEqual(load?.keyPath, "PowerTelemetryData/SystemLoad")
        XCTAssertEqual(load?.freshness, .unknown)
        XCTAssertEqual(snapshot.catalog.first { $0.id == "054" }?.value?.doubleValue, 5.3)
        XCTAssertNil(snapshot.catalog.first { $0.id == "038" }?.value)
    }
    func testMissingOrInvalidLoadNeverFallsBackToInputOrAdapterCapability() {
        for value: Any in [true,Double.nan,-100,1000001] {
            let snapshot = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:],
                registry: ["PowerTelemetryData":["SystemLoad":value,"SystemPowerIn":5000]], adapter: ["Watts":30])
            XCTAssertNil(snapshot.catalog.first { $0.id == "043" }?.value)
        }
        let snapshot = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:], registry: ["PowerTelemetryData":["SystemPowerIn":5000]], adapter: ["Watts":30])
        XCTAssertNil(snapshot.catalog.first { $0.id == "043" }?.value)
    }
}
