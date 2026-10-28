import XCTest
@testable import TilveroApp
import ChargeBackends

@MainActor final class SystemChargeLimitModelTests: XCTestCase {
    func testReadbackRefreshDoesNotClaimTilveroOwnershipOrPermitWrites() async throws {
        let suite = "TilveroTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "historyEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let limits = try SystemChargeLimitParser.parse("Battery level limits:\n({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;})")
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                systemChargeLimitProvider: { .init(limits: limits) })
        defer { model.stop() }
        await model.refreshSystemChargeLimit()
        XCTAssertEqual(model.systemChargeLimit?.limits?.manualLimit, 85)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.liveControl.hasOwnedSettings)
        model.setSleeping(true)
        XCTAssertNil(model.systemChargeLimit, "Pre-sleep readback cannot remain current after a lifecycle boundary.")
    }

    func testSimulationNeverQueriesSystemLimits() async {
        let suite = "TilveroTests.\(UUID().uuidString)"; let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences, systemChargeLimitProvider: {
            XCTFail("Demo must not query or present physical settings")
            return .init(limits: nil)
        })
        await model.refreshSystemChargeLimit()
        XCTAssertNil(model.systemChargeLimit)
    }
}
