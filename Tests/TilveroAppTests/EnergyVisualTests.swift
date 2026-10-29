import XCTest
import PowerCore
@testable import TilveroApp

final class EnergyVisualTests: XCTestCase {
    @MainActor func testSchematicArtworkIsBundledAndDecodesAsLandscape() throws {
        for artwork in [EnergyArtwork.image, EnergyArtwork.adapter, EnergyArtwork.mac] {
            let image = try XCTUnwrap(artwork)
            XCTAssertTrue(image.isValid)
            XCTAssertGreaterThan(image.size.width, image.size.height)
        }
    }

    func testProminentPowerRetainsVisibleStaleQualificationAndSource() {
        for id in ["054", "038"] {
            let reading = CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(24.6), source: "fixture/" + id, freshness: .stale)
            let headline = PowerHeadlineReading(reading)
            XCTAssertEqual(headline.qualificationKey, "Stale")
            XCTAssertEqual(headline.source, "fixture/" + id)
            XCTAssertTrue(headline.value.contains("24"))
            let fresh = CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(24.6), source: "fixture/" + id, freshness: .fresh)
            XCTAssertNil(PowerHeadlineReading(fresh).qualificationKey)
        }
        let unknown = CatalogReading(definition: BatteryCatalog.definition("038"), value: .decimal(-8.4), source: "fixture/battery", freshness: .unknown)
        XCTAssertEqual(PowerHeadlineReading(unknown).qualificationKey, "Freshness unknown")
        XCTAssertEqual(PowerHeadlineReading(nil).value, "—")
        XCTAssertEqual(PowerHeadlineReading(nil).qualificationKey, "Unavailable")
    }

    func testFlowRequiresFreshObservedDirectionAndNeverGuessesFromConnection() {
        let connected = TelemetryReading(value: true, source: "fixture")
        let noFlow = EnergyVisualSnapshot(.init(isExternalPower: connected))
        XCTAssertEqual(noFlow.direction, .unknown)
        XCTAssertEqual(noFlow.sourceConnected, true)
        let into = CatalogReading(definition: BatteryCatalog.definition("017"), value: .text("intoBattery"), source: "fixture", freshness: .fresh)
        XCTAssertEqual(EnergyVisualSnapshot(.init(catalog: [into])).direction, .intoBattery)
        let stale = CatalogReading(definition: BatteryCatalog.definition("017"), value: .text("intoBattery"), source: "fixture", freshness: .stale)
        XCTAssertEqual(EnergyVisualSnapshot(.init(catalog: [stale])).direction, .unknown)
        let quiet = CatalogReading(definition: BatteryCatalog.definition("017"), value: .text("nearZeroMeasuredCurrent"), source: "fixture", freshness: .fresh)
        XCTAssertEqual(EnergyVisualSnapshot(.init(catalog: [quiet])).direction, .stationary)
    }

    func testInvalidLevelAndStaleConnectionDoNotBecomeLiveGraphicState() {
        let snapshot = BatterySnapshot(chargePercent: .init(value: 145, source: "fixture"),
                                       isExternalPower: .init(value: true, source: "fixture", freshness: .stale))
        let state = EnergyVisualSnapshot(snapshot)
        XCTAssertNil(state.level)
        XCTAssertNil(state.sourceConnected)
        XCTAssertFalse(state.canAnimateLevel)
        let stale = EnergyVisualSnapshot(.init(chargePercent: .init(value: 78, source: "fixture", freshness: .stale)))
        XCTAssertEqual(stale.level, 78)
        XCTAssertTrue(stale.levelIsStale)
        XCTAssertFalse(stale.canAnimateLevel)
    }
    func testReportedSourceWithUnknownSampleTimeRemainsKnownWithoutInventedFlow() {
        let state = EnergyVisualSnapshot(.init(chargePercent: .init(value: 80, source: "IOPowerSources", freshness: .unknown),
                                             isExternalPower: .init(value: true, source: "IOPowerSources", freshness: .unknown)))
        XCTAssertEqual(state.sourceConnected, true)
        XCTAssertEqual(state.level, 80)
        XCTAssertEqual(state.direction, .unknown)
        XCTAssertTrue(state.canAnimateLevel)
    }
}
