import XCTest
import PowerCore
@testable import PowerPersistence

@MainActor final class PowerChannelHistoryTests: XCTestCase {
    func testNewOperationalChannelsSurviveReopenWithoutBecomingIntegratedBatteryEnergy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let store = try BatteryHistoryStore(url: url)
        let now = Date()
        for index in 0...1 {
            let at = now.addingTimeInterval(Double(index) * 30)
            let fields = ["043","054","103","112"].map { id in
                CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(4.2), source: "fixture", collectedAt: at, freshness: .unknown)
            }
            try store.record(.init(chargePercent: .init(value: 80, source: "fixture"), collectedAt: at, catalog: fields))
        }
        try store.close()
        let reopened = try BatteryHistoryStore(url: url)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.samples().count, 2)
        for sample in try reopened.samples() {
            for id in ["043","054","103","112"] { XCTAssertEqual(sample.readings.first { $0.id == id }?.value?.doubleValue, 4.2) }
            XCTAssertNil(sample.chargedWh)
            XCTAssertNil(sample.dischargedWh)
        }
    }
}
