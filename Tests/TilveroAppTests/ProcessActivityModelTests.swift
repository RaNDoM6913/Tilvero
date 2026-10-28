import XCTest
import PowerTelemetry
import SwiftUI
import AppKit
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
        XCTAssertTrue(model.highCPUApplications.isEmpty)
        let host = NSHostingController(rootView: ProcessActivityPanel(model: model, compact: true))
        XCTAssertLessThan(host.sizeThatFits(in: NSSize(width: 360, height: 1000)).height, 1)
    }
    func testHighLoadFlowsIntoCompactPanelAndSleepClearsIt() async throws {
        let suite = "TilveroHighCPU-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let fixture = HighLoadProcessFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), processActivityProvider: { await fixture.read() })
        let host = NSHostingController(rootView: ProcessActivityPanel(model: model, compact: true))
        for _ in 0..<3 {
            await model.refreshProcessActivity(force: true)
            XCTAssertTrue(model.highCPUApplications.isEmpty)
            XCTAssertLessThan(host.sizeThatFits(in: NSSize(width: 360, height: 1000)).height, 1)
        }
        await model.refreshProcessActivity(force: true)
        XCTAssertEqual(model.highCPUApplications.map(\.name), ["Fixture app"])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(host.sizeThatFits(in: NSSize(width: 360, height: 1000)).height, 20)
        model.setSleeping(true)
        XCTAssertTrue(model.highCPUApplications.isEmpty)
        model.stop()
    }
    func testProcessBaselineAndRatesStayEphemeralAndSleepResetsCoverage() async throws {
        let suite = "TilveroProcess-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let fixture = ProcessModelFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), processActivityProvider: { await fixture.read() })
        await model.refreshProcessActivity(force: true)
        XCTAssertTrue(model.processActivity?.isWarmingUp == true)
        let host = NSHostingController(rootView: ProcessActivityPanel(model: model, compact: true))
        XCTAssertLessThan(host.sizeThatFits(in: NSSize(width: 360, height: 1000)).height, 1)
        await model.refreshProcessActivity(force: true)
        XCTAssertEqual(model.processActivity?.rows.first?.name, "SENSITIVE_PROCESS_FIXTURE")
        XCTAssertTrue(model.highCPUApplications.isEmpty)
        XCTAssertLessThan(host.sizeThatFits(in: NSSize(width: 360, height: 1000)).height, 1)
        XCTAssertFalse(String(describing: prefs.dictionaryRepresentation()).contains("SENSITIVE_PROCESS_FIXTURE"))
        model.setSleeping(true)
        XCTAssertNil(model.processActivity)
        model.stop()
    }
}
private actor HighLoadProcessFixture {
    var time = -10
    func read() -> ProcessResourceCollection {
        time += 10
        let scale = ProcessActivityProvider.timebase
        let ticks = UInt64(Double(time) * 0.6 * 1e9 * Double(scale.denominator) / Double(scale.numerator))
        return .init(collectedAt: Date(), monotonic: Double(time), counters: [.init(pid: 1, start: 1, name: "worker",
            application: .init(key: "app", name: "Fixture app", bundlePath: "/Fixture.app"), cpuTicks: ticks)])
    }
}
private actor ProcessModelFixture {
    var time = 0
    func read() -> ProcessResourceCollection {
        time += 1
        return .init(collectedAt: Date(), monotonic: Double(time), counters: [.init(pid: 1, start: 1, name: "SENSITIVE_PROCESS_FIXTURE", cpuTicks: UInt64(time) * 1_000_000, cpuEnergyNanojoules: UInt64(time) * 1_000_000)])
    }
}
