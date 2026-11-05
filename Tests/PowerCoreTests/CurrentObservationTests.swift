import XCTest
@testable import PowerCore

final class CurrentObservationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let paths = CurrentObservation.appObservedIOPSKeyPaths

    private func row(_ id: String = "011", source: String = "IOPowerSources", key: String? = nil, value: CatalogValue? = .decimal(80),
                     collected: Double = 0, sample: Date? = nil, monotonic: TimeInterval? = nil,
                     provenance: TelemetryProvenance = .reported, availability: TelemetryAvailability? = nil,
                     freshness: TelemetryFreshness = .unknown) -> CatalogReading {
        CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: source, keyPath: key ?? paths[id] ?? "",
            collectedAt: now.addingTimeInterval(collected), sourceSampleAt: sample, monotonicAgeSeconds: monotonic,
            provenance: provenance, availability: availability, freshness: freshness)
    }

    func testFreshReadingAdmittedUnchanged() {
        XCTAssertTrue(row(source: "qualified", key: "", collected: -600, freshness: .fresh).isCurrentObservation(at: now),
                      "Fresh readings keep their existing behaviour; callers apply their own age guards.")
    }

    func testAppObservedIOPSRowsAdmittedWithinWindow() {
        for id in ["011", "013", "015"] {
            let value: CatalogValue = id == "011" ? .decimal(80) : .boolean(false)
            for (offset, expected) in [(-30.0, true), (-60.0, true), (-61.0, false), (0.5, true), (1.0, true), (1.01, false), (-0.5, true)] {
                // Offset of collectedAt from `now`: negative is in the past, positive in the future (1 s tolerated).
                XCTAssertEqual(row(id, value: value, collected: offset).isCurrentObservation(at: now), expected, "row \(id) offset \(offset)")
            }
            XCTAssertFalse(row(id, value: value, collected: 2).isCurrentObservation(at: now), "row \(id) collected 2 s in the future")
        }
    }

    func testUnknownRowsOutsideAllowlistRejected() {
        for source in ["AppleSmartBattery", "fixture", "Other provider"] {
            XCTAssertFalse(row(source: source).isCurrentObservation(at: now), source)
        }
        XCTAssertFalse(row(key: "").isCurrentObservation(at: now))
        XCTAssertFalse(row("015", key: "Is Charging", value: .boolean(false)).isCurrentObservation(at: now))
        XCTAssertFalse(row("014", key: "Is Charged", value: .boolean(false)).isCurrentObservation(at: now))
        XCTAssertFalse(row("016", key: "Power Source State", value: .text("Battery Power")).isCurrentObservation(at: now))
        XCTAssertFalse(row(sample: now).isCurrentObservation(at: now), "A provider that supplies a sample time has its own freshness rule.")
        XCTAssertFalse(row(monotonic: 0).isCurrentObservation(at: now))
        XCTAssertFalse(row(provenance: .estimated).isCurrentObservation(at: now))
        XCTAssertFalse(row(freshness: .stale).isCurrentObservation(at: now))
        XCTAssertFalse(row(availability: .temporarilyUnavailable).isCurrentObservation(at: now))
        XCTAssertFalse(row(value: nil).isCurrentObservation(at: now))
        let previous = row(freshness: .fresh)
        let missing = CatalogReading(definition: BatteryCatalog.definition("011"), source: "IOPowerSources", collectedAt: now)
        XCTAssertFalse(missing.retainingPrevious(previous, age: 5).isCurrentObservation(at: now), "Retained values are never current.")
    }

    func testTypedReadingUsesSourcePrefixedKeyPath() {
        let typed = TelemetryReading<Int>(value: 80, source: "IOPowerSources/Current Capacity/Max Capacity", collectedAt: now, freshness: .unknown)
        XCTAssertTrue(typed.isCurrentObservation(catalogID: "011", at: now))
        XCTAssertFalse(typed.isCurrentObservation(catalogID: "015", at: now))
        let bare = TelemetryReading<Int>(value: 80, source: "IOPowerSources", collectedAt: now, freshness: .unknown)
        XCTAssertFalse(bare.isCurrentObservation(catalogID: "011", at: now))
        let fixture = TelemetryReading<Int>(value: 80, source: "fixture", collectedAt: now)
        XCTAssertTrue(fixture.isCurrentObservation(catalogID: "011", at: now), "Fresh fixtures stay admitted.")
        XCTAssertFalse(TelemetryReading<Int>(value: 80, source: "fixture", collectedAt: now, freshness: .unknown)
            .isCurrentObservation(catalogID: "011", at: now))
    }
}
