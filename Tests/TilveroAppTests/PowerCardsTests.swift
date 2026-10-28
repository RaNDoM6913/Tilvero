import XCTest
import PowerCore
import PowerPersistence
import PowerTelemetry
@testable import TilveroApp

@MainActor final class PowerCardsTests: XCTestCase {
    func testNewPowerCardsAppendHiddenWithoutReplacingSavedComposition() {
        let saved = OverviewPreferences.load(Data(#"{"order":["history","power","temperature","forecast","chargeLimit","keepAwake"],"hidden":["temperature"]}"#.utf8))
        XCTAssertEqual(Array(saved.order.prefix(6)).map(\.rawValue), ["history","power","temperature","forecast","chargeLimit","keepAwake"])
        XCTAssertEqual(Array(saved.order.suffix(4)).map(\.rawValue), ["systemPower","adapter","batteryHealth","applications"])
        XCTAssertEqual(saved.hidden.map(\.rawValue).sorted(), ["adapter","applications","batteryHealth","systemPower","temperature"])
    }
    func testMetricGraphBreaksAtStaleMissingSourceAndPowerTransitions() throws {
        let now = Date()
        let snapshots = [sample(0, now, value: 3), sample(1, now, value: nil), sample(2, now, value: 5),
                      sample(3, now, value: 6, freshness: .stale), sample(4, now, value: 7),
                      sample(5, now, value: 8, source: "changed"), sample(6, now, value: 9, source: "changed", ac: false)]
        let store = try BatteryHistoryStore(url: nil)
        defer { try? store.close() }
        for snapshot in snapshots { try store.record(snapshot) }
        let values = try store.samples()
        let points = PowerMetricHistory.points(values, id: "054", since: now.addingTimeInterval(-1))
        XCTAssertEqual(points.map(\.value), [3,5,7,8,9])
        XCTAssertEqual(Set(points.map(\.series)).count, 5)
        let summary = try XCTUnwrap(PowerMetricHistory.summary(points))
        XCTAssertEqual(summary.count, 1, "Summary covers only the latest comparable continuous series")
        XCTAssertEqual(summary.mean, 9)
        XCTAssertEqual(PowerMetricHistory.points(values, id: "050", since: now).count, 0, "Adapter rating cannot stand in for input history")
    }
    func testPersistedSameProviderPathAndDerivedInputsBreakGraphAfterReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite"), date = Date()
        let provider = MacBatteryProvider(qualification: .appleSilicon)
        let store = try BatteryHistoryStore(url: url)
        for index in 0..<4 {
            let at = date.addingTimeInterval(Double(index))
            var registry: [String: Any] = ["DesignCapacity":5000,"UpdateTime":at.timeIntervalSince1970]
            if index < 2 { registry["Temperature"] = 3000; registry["AppleRawMaxCapacity"] = 4900 }
            else { registry["BatteryData"] = ["Temperature":3100]; registry["NominalChargeCapacity"] = 4800 }
            try store.record(provider.normalize(powerSource:["Current Capacity":80,"Max Capacity":100,"Power Source State":"AC Power"], registry:registry, at:at, uptime:Double(index + 100)))
        }
        try store.close()
        let reopened = try BatteryHistoryStore(url: url)
        defer { try? reopened.close() }
        for id in ["039","026"] {
            let points = PowerMetricHistory.points(try reopened.samples(),id:id,since:date)
            XCTAssertEqual(points.count,4)
            XCTAssertEqual(Set(points.map(\.series)).count,2)
            XCTAssertEqual(PowerMetricHistory.summary(points)?.count,2)
        }
    }
    private func sample(_ index: Int, _ date: Date, value: Double?, freshness: TelemetryFreshness = .unknown, source: String = "fixture", ac: Bool = true) -> BatterySnapshot {
        let at = date.addingTimeInterval(Double(index))
        return .init(chargePercent: .init(value: 80, source: "fixture"), isExternalPower: .init(value: ac, source: "fixture"), collectedAt: at,
            catalog: [.init(definition: BatteryCatalog.definition("054"), value: value.map(CatalogValue.decimal), source: source, keyPath: "input", collectedAt: at, freshness: freshness)])
    }
}
