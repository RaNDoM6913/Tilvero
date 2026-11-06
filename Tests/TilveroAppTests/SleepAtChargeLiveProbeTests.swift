import XCTest
import PowerCore
@testable import TilveroApp

/// Live IOKit readings carry freshness `.unknown`; the pills were dead on a real Mac because only `.fresh` counted.
@MainActor final class SleepAtChargeLiveProbeTests: XCTestCase {
    private func model(freshness: TelemetryFreshness, percent: Int = 64) throws -> (TilveroModel, () -> Void) {
        let suite = "LiveProbe-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: {
            BatterySnapshot(chargePercent: .init(value: percent, source: "fixture", freshness: freshness),
                            isExternalPower: .init(value: false, source: "fixture", freshness: freshness))
        })
        return (model, { model.stop(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) })
    }

    func testReadingsWithUnknownFreshnessEnableTheLevelsBelowTheCharge() async throws {
        let (model, cleanUp) = try model(freshness: .unknown)
        defer { cleanUp() }
        await model.refresh()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.sleepAtCharge.currentPercent, 64)
        XCTAssertEqual(SleepAtChargeService.targets.map { model.sleepAtCharge.canArm(target: $0) }, [true, true, true, true, true])
        try model.sleepAtCharge.arm(target: 20)
        XCTAssertEqual(model.sleepAtCharge.target, 20)
    }

    func testOnlyLevelsBelowTheChargeAreOfferedAndStaleReadingsAreIgnored() async throws {
        let (low, cleanUpLow) = try model(freshness: .unknown, percent: 19)
        defer { cleanUpLow() }
        await low.refresh(); try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(SleepAtChargeService.targets.map { low.sleepAtCharge.canArm(target: $0) }, [false, false, false, true, true])
        let (stale, cleanUpStale) = try model(freshness: .stale)
        defer { cleanUpStale() }
        await stale.refresh(); try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(stale.sleepAtCharge.currentPercent, "A stale reading cannot arm or fire.")
    }
}
