import XCTest
import PowerTelemetry
@testable import TilveroApp

@MainActor final class ProcessActivityModelTests: XCTestCase {
    func testSimulationNeverCollectsProcesses() async {
        let suite = "TilveroProcess-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: prefs, processActivityProvider: {
            XCTFail("Simulation must never read physical processes")
            return .init(collectedAt: Date(), monotonic: 1, counters: [])
        })
        await model.refreshProcessActivity()
        XCTAssertNil(model.processActivity)
    }
    func testProcessBaselineAndRatesStayEphemeralAndSleepResetsCoverage() async throws {
        let suite = "TilveroProcess-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let fixture = ProcessModelFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), processActivityProvider: { await fixture.read() })
        await model.refreshProcessActivity(force: true)
        XCTAssertTrue(model.processActivity?.isWarmingUp == true)
        await model.refreshProcessActivity(force: true)
        XCTAssertEqual(model.processActivity?.rows.first?.name, "SENSITIVE_PROCESS_FIXTURE")
        XCTAssertFalse(String(describing: prefs.dictionaryRepresentation()).contains("SENSITIVE_PROCESS_FIXTURE"))
        model.setSleeping(true)
        XCTAssertNil(model.processActivity)
        model.stop()
    }
}
private actor ProcessModelFixture {
    var time = 0
    func read() -> ProcessResourceCollection {
        time += 1
        return .init(collectedAt: Date(), monotonic: Double(time), counters: [.init(pid: 1, start: 1, name: "SENSITIVE_PROCESS_FIXTURE", cpuTicks: UInt64(time) * 1_000_000, cpuEnergyNanojoules: UInt64(time) * 1_000_000)])
    }
}
