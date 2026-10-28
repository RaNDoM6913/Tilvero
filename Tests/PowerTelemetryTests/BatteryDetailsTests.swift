import XCTest
import PowerCore
import PowerDiagnostics
@testable import PowerTelemetry

final class BatteryDetailsTests: XCTestCase {
    func testObservedGaugeProfileKeepsMixedLifetimeScalesAndSignedCurrentExplicit() throws {
        let value = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:], registry: ["DeviceName":"bq40z651", "DesignCapacity":5000,"AppleRawMaxCapacity":4900,
            "BatteryData":["LifetimeData":["MaximumTemperature":40,"MinimumTemperature":10,"AverageTemperature":250,"MaximumPackVoltage":13362,"MinimumPackVoltage":10270,"MaximumChargeCurrent":5485,"MaximumDischargeCurrent":-3333,"TemperatureSamples":81247,"TotalOperatingTime":5077]]], system: ["model":"Mac17,3"])
        func reading(_ id: String) -> CatalogReading? { value.catalog.first { $0.id == id } }
        XCTAssertEqual(reading("103")?.value?.doubleValue, 40)
        XCTAssertEqual(reading("105")?.value?.doubleValue, 25)
        XCTAssertEqual(reading("107")?.value?.doubleValue, 10.270)
        XCTAssertEqual(reading("109")?.value?.doubleValue, -3.333)
        XCTAssertEqual(reading("112")?.value?.doubleValue, -100)
        XCTAssertEqual(reading("105")?.provenance, .inferred)
        XCTAssertEqual(reading("105")?.freshness, .unknown)
        XCTAssertEqual(reading("064")?.keyPath, "BatteryData/LifetimeData/TotalOperatingTime")
    }
    func testCellVoltageProfileRequiresCoherentPackAndPreservesNominalCapacitySeparately() {
        let provider = MacBatteryProvider(qualification: .appleSilicon)
        let registry: [String: Any] = ["DeviceName":"bq40z651","Voltage":12000,"DesignCapacity":5000,"AppleRawMaxCapacity":4900,"NominalChargeCapacity":5100,
            "BatteryData":["CellVoltage":[4000,4001,3999],"Qmax":[5200,5300,5400]],"PermanentFailureStatus":0]
        let value = provider.normalize(powerSource: [:], registry: registry, system:["model":"Mac17,3"])
        XCTAssertNotNil(value.catalog.first { $0.id == "041" }?.value)
        XCTAssertEqual(value.catalog.first { $0.id == "042" }?.value?.doubleValue, 2)
        XCTAssertEqual(value.catalog.first { $0.id == "113" }?.value?.doubleValue, 5100)
        XCTAssertEqual(value.catalog.first { $0.id == "115" }?.value?.doubleValue, 102)
        XCTAssertEqual(value.catalog.first { $0.id == "026" }?.value?.doubleValue, 98)
        XCTAssertNotNil(value.catalog.first { $0.id == "114" }?.value)
        var invalid = registry; invalid["Voltage"] = 9000
        XCTAssertNil(provider.normalize(powerSource: [:],registry: invalid,system:["model":"Mac17,3"]).catalog.first { $0.id == "041" }?.value)
    }
    func testRawCountersPreserveExactIntegersAndStandardReportExcludesRawObjects() throws {
        let snapshot = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:], registry:["DesignCapacity":5000,"NominalChargeCapacity":5100,
            "PowerTelemetryData":["SystemEnergyConsumed":UInt64(9_007_199_254_740_993),"AccumulatedWallEnergyEstimate":UInt64.max],
            "LifetimeData":["TimeAtHighSoc":Data([1,2,3])],"PermanentFailureStatus":0])
        guard case .object(let raw) = snapshot.catalog.first(where: { $0.id == "102" })?.value else { return XCTFail("Raw counters missing") }
        XCTAssertEqual(raw["SystemEnergyConsumed"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(raw["AccumulatedWallEnergyEstimate"], .text("18446744073709551615"))
        let fields = DoctorReport(snapshot: snapshot).fields
        for id in ["101","102","114"] { XCTAssertFalse(fields.contains { $0.id == id }) }
        XCTAssertTrue(fields.contains { $0.id == "115" && $0.value != nil })
    }
    func testUnknownGaugeKeepsRawCountersAndCorrectFallbackPathWithoutGuessingUnits() throws {
        let value = MacBatteryProvider(qualification: .appleSilicon).normalize(powerSource: [:], registry: ["LifetimeData":["MaximumTemperature":4000,"AverageTemperature":250,"TotalOperatingTime":5077,"TimeAtHighSoc":Data([1,2,3])],"PowerTelemetryData":["AdapterEfficiencyLoss":426,"WallEnergyEstimate":4044]], system:["model":"Unknown"])
        XCTAssertNil(value.catalog.first { $0.id == "103" }?.value)
        XCTAssertNil(value.catalog.first { $0.id == "105" }?.value)
        let raw = try XCTUnwrap(value.catalog.first { $0.id == "101" })
        XCTAssertNotNil(raw.value)
        XCTAssertEqual(raw.keyPath, "LifetimeData")
        XCTAssertEqual(raw.provenance, .raw)
        XCTAssertEqual(value.catalog.first { $0.id == "064" }?.keyPath, "LifetimeData/TotalOperatingTime")
        XCTAssertNotNil(value.catalog.first { $0.id == "102" }?.value)
    }
}
