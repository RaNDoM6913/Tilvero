import XCTest
@testable import TilveroApp

@MainActor final class OverviewPreferencesTests: XCTestCase {
    func testPreferencesPersistWithoutMutatingTelemetryOrControl() async throws {
        let suite = "TilveroOverview-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        await model.refresh()
        let telemetry = model.snapshot, control = model.control
        model.overviewPreferences.hidden.insert(.temperature)
        model.overviewPreferences.move(.history, by: -1)
        let reopened = TilveroModel(isDemo: true, preferences: preferences)
        XCTAssertEqual(reopened.overviewPreferences, model.overviewPreferences)
        XCTAssertEqual(model.snapshot.chargePercent, telemetry.chargePercent)
        XCTAssertEqual(model.control?.charge, control?.charge)
        XCTAssertNil(model.nativeCharge.observed)
    }
    func testCorruptOrDuplicateOrderCannotHideOrDuplicateTheWholePanel() throws {
        XCTAssertEqual(OverviewPreferences.load(Data("bad".utf8)), .init())
        var duplicate = OverviewPreferences(); duplicate.order = [.forecast,.forecast]
        XCTAssertEqual(OverviewPreferences.load(try JSONEncoder().encode(duplicate)), .init())
    }
}
