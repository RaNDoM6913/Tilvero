import XCTest
import Foundation
@testable import PowerCore
@testable import PowerTelemetry
import PowerDiagnostics

final class TelemetryTests: XCTestCase {
    func testEverySnapshotExposesAllCatalogAvailabilityResults() {
        let snapshot = BatterySnapshot.unavailable()
        XCTAssertEqual(snapshot.catalog.map(\.id), (1...100).map { String(format: "%03d", $0) })
        XCTAssertTrue(snapshot.catalog.allSatisfy { $0.value == nil && $0.reason != nil && $0.freshness == .unknown })
    }
    func testDemoCatalogMatchesExplicitCompatibilityReadings() {
        let demo = BatterySnapshot.demo()
        XCTAssertTrue(demo.isDemo)
        XCTAssertEqual(demo.catalog.first { $0.id == "011" }?.value?.doubleValue, Double(demo.chargePercent.value!))
        XCTAssertEqual(demo.catalog.first { $0.id == "039" }?.value?.doubleValue, demo.temperatureCelsius.value)
    }
    func testSelectsInternalBatteryRatherThanUPS() {
        let selected = MacBatteryProvider.internalBattery(in: [["Type":"UPS", "Current Capacity": 50], ["Type":"InternalBattery", "Current Capacity": 80]])
        XCTAssertEqual(selected?["Current Capacity"] as? Int, 80)
    }
    func testMalformedNumbersAndNegativeTimeSentinelsStayUnavailable() {
        XCTAssertNil(TelemetryDecoder.integer(true)); XCTAssertNil(TelemetryDecoder.number(false))
        XCTAssertNil(TelemetryDecoder.integer(2.5)); XCTAssertNil(TelemetryDecoder.number(Double.nan))
        XCTAssertNil(TelemetryDecoder.aggregateSeconds(-1)); XCTAssertNil(TelemetryDecoder.aggregateSeconds(-2))
        XCTAssertNil(TelemetryDecoder.minutesToSeconds(-1))
        XCTAssertEqual(TelemetryDecoder.minutesToSeconds(10), 600)
        XCTAssertEqual(TelemetryDecoder.aggregateSeconds(10), 10)
        XCTAssertNil(TelemetryDecoder.percentage(current: 30, maximum: 0))
        XCTAssertEqual(TelemetryDecoder.percentage(current: 25, maximum: 50), 50)
    }
    func testSignedEncodingIsExplicitAndLargeUnsignedIsRejected() {
        XCTAssertEqual(TelemetryDecoder.currentAmps(-1500, encoding: .signedInteger), -1.5)
        XCTAssertEqual(TelemetryDecoder.currentAmps(UInt32(bitPattern: -1500), encoding: .twosComplement32), -1.5)
        XCTAssertNil(TelemetryDecoder.currentAmps(UInt32(bitPattern: -1500), encoding: .signedInteger))
        XCTAssertNil(TelemetryDecoder.currentAmps(UInt64.max - 1499, encoding: .signedInteger))
    }
    func testCapacityRetentionAbove100AndNominalVoltageGate() {
        XCTAssertEqual(TelemetryDecoder.capacityRetention(full: 5200, design: 5000), 104)
        XCTAssertNil(TelemetryDecoder.energyWh(capacityMAh: 5000, nominalVoltage: nil))
        XCTAssertEqual(TelemetryDecoder.energyWh(capacityMAh: 5000, nominalVoltage: 11), 55)
    }
    func testNoGuessedTemperatureOrLivePowerFromAdapterRating() {
        let snapshot = MacBatteryProvider(qualification: .unqualified).normalize(powerSource: ["Type":"InternalBattery", "Current Capacity": 80, "Max Capacity": 100, "Power Source State":"AC Power"],
            registry: ["Temperature": 3100, "Voltage": 12000, "Amperage": 1000, "CycleCount": 0], adapter: ["Watts": 96], aggregateTimeRemaining: -2)
        XCTAssertEqual(snapshot.chargePercent.value, 80)
        XCTAssertEqual(snapshot.voltageVolts.value, 12)
        XCTAssertEqual(snapshot.currentAmps.value, 1)
        XCTAssertEqual(snapshot.cycleCount.value, 0)
        XCTAssertNil(snapshot.temperatureCelsius.value)
        XCTAssertEqual(snapshot.catalog.first { $0.id == "050" }?.value?.doubleValue, 96)
        XCTAssertNil(snapshot.catalog.first { $0.id == "054" }?.value)
        XCTAssertNil(snapshot.catalog.first { $0.id == "038" }?.value)
        XCTAssertEqual(snapshot.voltageVolts.freshness, .unknown)
        XCTAssertNil(snapshot.voltageVolts.sourceSampleAt)
    }
    func testMalformedAndContradictorySourceDoesNotBecomeNotCharging() {
        let snapshot = MacBatteryProvider().normalize(powerSource: ["Current Capacity": true, "Max Capacity": 100, "Is Charging": 1, "Power Source State":"unexpected"], registry: ["CycleCount": false])
        XCTAssertNil(snapshot.chargePercent.value); XCTAssertNil(snapshot.isCharging.value)
        XCTAssertNil(snapshot.isExternalPower.value); XCTAssertNil(snapshot.cycleCount.value)
    }
    func testRepeatedReadDoesNotInventHardwareTimestamp() {
        let first = MacBatteryProvider().normalize(powerSource: ["Current Capacity":80, "Max Capacity":100], at: Date(timeIntervalSince1970: 100))
        let second = MacBatteryProvider().normalize(powerSource: ["Current Capacity":80, "Max Capacity":100], at: Date(timeIntervalSince1970: 200))
        XCTAssertNil(first.chargePercent.sourceSampleAt); XCTAssertNil(second.chargePercent.sourceSampleAt)
        XCTAssertEqual(second.chargePercent.freshness, .unknown)
    }
    func testCatalogRetainsGoodValueAsStaleWhenNewCollectionFails() {
        let definition = BatteryCatalog.definition("039")
        let previous = CatalogReading(definition: definition, value: .decimal(30), source: "qualified", collectedAt: Date(timeIntervalSince1970: 100), freshness: .fresh)
        let missing = CatalogReading(definition: definition, source: "qualified", collectedAt: Date(timeIntervalSince1970: 200), reason: "Sensor unavailable")
        let retained = missing.retainingPrevious(previous, age: 100)
        XCTAssertEqual(retained.value?.doubleValue, 30); XCTAssertEqual(retained.freshness, .stale)
        XCTAssertEqual(retained.availability, .temporarilyUnavailable); XCTAssertEqual(retained.monotonicAgeSeconds, 100)
    }
    func testTypedRoundTripPreservesUnavailableAndMetadata() throws {
        let snapshot = BatterySnapshot.demo()
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(BatterySnapshot.self, from: data), snapshot)
        let invalid = CatalogReading(definition: BatteryCatalog.definition("035"), value: .decimal(.infinity), source: "invalid")
        XCTAssertNil(invalid.value); XCTAssertEqual(invalid.availability, .invalid)
    }
    func testIdentitySaltIsLocalAndMissingSerialDoesNotInventIdentity() {
        let a = MacBatteryProvider(identitySalt: "a").normalize(powerSource: [:], registry: ["Serial":"PRIVATE"])
        let b = MacBatteryProvider(identitySalt: "b").normalize(powerSource: [:], registry: ["Serial":"PRIVATE"])
        XCTAssertNotNil(a.batteryIdentityToken); XCTAssertNotEqual(a.batteryIdentityToken, b.batteryIdentityToken)
        XCTAssertNil(MacBatteryProvider(identitySalt:"a").normalize(powerSource: [:]).batteryIdentityToken)
    }
    func testDoctorIsBoundedAndRedactsSerialTokensAndPersonalPaths() throws {
        let fields = [CatalogReading(definition: BatteryCatalog.definition("059"), value: .text("PRIVATE_SERIAL"), source: "registry"),
            CatalogReading(definition: BatteryCatalog.definition("097"), value: .object(["token":.text("PRIVATE_TOKEN"), "error":.text("Failure /Users/private-name/file token=SECRET")]), source: "/Users/private-name/provider")]
        let snapshot = BatterySnapshot(catalog: fields, batteryIdentityToken: "PRIVATE_IDENTITY")
        let data = try DoctorReport(snapshot: snapshot).encodedJSON()
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["PRIVATE_SERIAL", "PRIVATE_TOKEN", "PRIVATE_IDENTITY", "private-name", "SECRET"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertLessThan(data.count, 256_001)
    }
    func testCollectionFailureRetainsStaleValuesAndRecoveryReplacesThem() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let good = BatterySnapshot(chargePercent: .init(value: 80, source: "test", collectedAt: date), collectedAt: date, monotonicTime: 100, batteryIdentityToken: "pack-a")
        let missing = BatterySnapshot(collectedAt: date.addingTimeInterval(10), monotonicTime: 110)
        let stale = missing.retainingPreviousReadings(good)
        XCTAssertEqual(stale.chargePercent.value, 80)
        XCTAssertEqual(stale.chargePercent.freshness, .stale)
        XCTAssertEqual(stale.chargePercent.availability, .temporarilyUnavailable)
        XCTAssertEqual(stale.chargePercent.collectedAt, date)
        XCTAssertEqual(stale.chargePercent.monotonicAgeSeconds, 10)
        let staleAgain = BatterySnapshot(collectedAt: date.addingTimeInterval(20), monotonicTime: 120).retainingPreviousReadings(stale)
        XCTAssertEqual(staleAgain.chargePercent.monotonicAgeSeconds, 20)
        XCTAssertEqual(staleAgain.chargePercent.collectedAt, date)
        let recovered = BatterySnapshot(chargePercent: .init(value: 79, source: "test", collectedAt: date.addingTimeInterval(30)), collectedAt: date.addingTimeInterval(30), monotonicTime: 130, batteryIdentityToken: "pack-a").retainingPreviousReadings(staleAgain)
        XCTAssertEqual(recovered.chargePercent.value, 79); XCTAssertEqual(recovered.chargePercent.freshness, .fresh)
        let replacement = BatterySnapshot(collectedAt: date.addingTimeInterval(40), monotonicTime: 140, batteryIdentityToken: "pack-b").retainingPreviousReadings(good)
        XCTAssertNil(replacement.chargePercent.value)
        XCTAssertNil(BatterySnapshot().retainingPreviousReadings(.demo()).chargePercent.value)
    }
    func testQualifiedProviderConversionsAndTimestampAge() {
        let date = Date(timeIntervalSince1970: 1700000100)
        let provider = MacBatteryProvider(qualification: .appleSilicon)
        let registry: [String: Any] = ["Temperature": 3097, "Voltage": 12000, "Amperage": -1000,
            "UpdateTime": 1700000090, "DesignCapacity": 5000, "AppleRawMaxCapacity": 5200,
            "AppleRawCurrentCapacity": 2600, "GasGaugeFirmwareVersion": 2,
            "PowerTelemetryData": ["SystemPowerIn": 12000, "SystemVoltageIn": 12000, "SystemCurrentIn": 1000]]
        let first = provider.normalize(powerSource: [:], registry: registry, at: date, uptime: 100)
        let second = provider.normalize(powerSource: [:], registry: registry, at: date.addingTimeInterval(10000), uptime: 110)
        func field(_ id: String) -> CatalogReading { first.catalog.first { $0.id == id }! }
        XCTAssertEqual(first.temperatureCelsius.value, 30.97)
        XCTAssertEqual(field("026").value?.doubleValue, 104)
        XCTAssertEqual(field("012").value?.doubleValue, 50)
        XCTAssertEqual(field("038").value?.doubleValue, -12)
        XCTAssertEqual(field("054").value?.doubleValue, 12)
        XCTAssertEqual(field("056").value?.doubleValue, 1)
        XCTAssertEqual(field("054").freshness, .unknown)
        XCTAssertEqual(second.temperatureCelsius.monotonicAgeSeconds, 20)
        XCTAssertEqual(second.temperatureCelsius.sourceSampleAt, first.temperatureCelsius.sourceSampleAt)
        XCTAssertEqual(RegistryQualification.intelSmartBattery.temperatureCelsius(3000)!, 26.85, accuracy: 0.001)
        XCTAssertNil(RegistryQualification.unqualified.temperatureCelsius(3000))
        XCTAssertNil(TelemetryDecoder.smartBatteryManufactureDate(57390211806259))
    }
    @MainActor func testObserverStopAndRepeatedStartDoNotLeaveRegistrations() {
        let observer = PowerSourceObserver()
        _ = observer.start(onChange: {})
        _ = observer.start(onChange: {})
        observer.stop(); observer.stop()
        XCTAssertFalse(observer.isRunning)
    }
}
