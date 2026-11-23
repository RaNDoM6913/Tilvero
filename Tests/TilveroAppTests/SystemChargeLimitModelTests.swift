// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp
import ChargeBackends

@MainActor final class SystemChargeLimitModelTests: XCTestCase {
    func testReadbackRefreshDoesNotClaimTilveroOwnershipOrPermitWrites() async throws {
        let suite = TestDefaults.name()
        let preferences = TestDefaults.defaults(suite)
        preferences.set(false, forKey: "historyEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
        let limits = try SystemChargeLimitParser.parse("Battery level limits:\n({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;})")
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                systemChargeLimitProvider: { _ in .init(limits: limits) })
        defer { model.stop() }
        await model.refreshSystemChargeLimit()
        XCTAssertEqual(model.systemChargeLimit?.limits?.manualLimit, 85)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.liveControl.hasOwnedSettings)
        model.setSleeping(true)
        XCTAssertNil(model.systemChargeLimit, "Pre-sleep readback cannot remain current after a lifecycle boundary.")
    }

    func testSimulationNeverQueriesSystemLimits() async {
        let suite = TestDefaults.name(); let preferences = TestDefaults.defaults(suite)
        defer { TestDefaults.remove(suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences, systemChargeLimitProvider: { _ in
            XCTFail("Demo must not query or present physical settings")
            return .init(limits: nil)
        })
        await model.refreshSystemChargeLimit()
        XCTAssertNil(model.systemChargeLimit)
    }

    func testExplicitRefreshNeverReusesARecentAnswerAndPollingDoes() async throws {
        let preferences = makeTestDefaults("LimitRefresh").defaults
        preferences.set(false, forKey: "historyEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ages = AgeLog()
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                 systemChargeLimitProvider: { age in await ages.append(age); return .init(limits: nil) })
        defer { model.stop() }
        await model.refreshSystemChargeLimit()
        await model.refreshSystemChargeLimit(reusingRecent: false)
        let seen = await ages.values
        XCTAssertEqual(seen, [BatteryLimitReadings.reuseWindow, 0])
    }
}

private actor AgeLog {
    private(set) var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
}
