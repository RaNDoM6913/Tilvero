import XCTest
import PowerTelemetry
@testable import TilveroApp

final class ProcessActivityHighlightsTests: XCTestCase {
    func testThresholdUsesOneCPUAndClearsJustBelowFiftyPercent() {
        var fixture = HighlightFixture()
        for (time, cpu) in [(0.0, 0.0), (10, 5), (20, 10)] { _ = fixture.read(time, cpu: cpu) }
        XCTAssertEqual(fixture.read(30, cpu: 15).count, 1)
        XCTAssertTrue(fixture.read(40, cpu: 19.99).isEmpty)
    }

    func testShowsAtMostThreeVerifiedAppsRankedByCPUWithoutRequiringEnergyCounters() {
        var sampler = ProcessActivitySampler(), highlights = SustainedCPUActivity()
        var rows: [ProcessActivityRow] = []
        for time in [0.0, 10, 20, 30] {
            let counters = (1...5).map { index in
                ProcessResourceCounter(pid: Int32(index), start: 1, name: "worker",
                    application: .init(key: "app\(index)", name: "App \(index)", bundlePath: "/App\(index).app"),
                    cpuTicks: UInt64(time * Double(index) * 0.25 * 1e9))
            }
            rows = highlights.accept(sampler.accept(.init(collectedAt: Date(), monotonic: time, counters: counters)), monotonic: time)
        }
        XCTAssertEqual(rows.map(\.name), ["App 5", "App 4", "App 3"])
        XCTAssertEqual(rows.map(\.cpuPercent), [125, 100, 75])
        XCTAssertTrue(rows.allSatisfy { $0.cpuPowerWatts == nil })
    }

    func testLowLoadAndSingleSpikeStayQuietUntilThreeIntervalsAndThirtySeconds() {
        var fixture = HighlightFixture()
        XCTAssertTrue(fixture.read(0, cpu: 0).isEmpty)
        for (time, cpu) in [(5.0, 3.0), (10, 6), (15, 9), (20, 10), (50, 28), (60, 34)] {
            XCTAssertTrue(fixture.read(time, cpu: cpu).isEmpty)
        }
        XCTAssertEqual(fixture.read(70, cpu: 40).map(\.name), ["Fixture app"])
        XCTAssertTrue(fixture.read(80, cpu: 41).isEmpty, "Load below the threshold clears a previously visible app")
    }

    func testPIDReuseCounterResetAndAccessGapRestartConfirmation() {
        var fixture = HighlightFixture()
        _ = fixture.read(0, cpu: 0)
        _ = fixture.read(10, cpu: 6)
        _ = fixture.read(20, cpu: 12)
        XCTAssertTrue(fixture.read(30, cpu: 18, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(40, cpu: 24, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(50, cpu: 30, start: 2).isEmpty)
        XCTAssertEqual(fixture.read(60, cpu: 36, start: 2).count, 1)
        XCTAssertTrue(fixture.read(70, cpu: 1, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(80, cpu: 7, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(90, cpu: 13, start: 2).isEmpty)
        XCTAssertEqual(fixture.read(100, cpu: 19, start: 2).count, 1)
        XCTAssertTrue(fixture.read(110, cpu: nil, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(120, cpu: 25, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(130, cpu: 31, start: 2).isEmpty)
        XCTAssertTrue(fixture.read(140, cpu: 37, start: 2).isEmpty)
        XCTAssertEqual(fixture.read(150, cpu: 43, start: 2).count, 1)
    }

    func testLongGapFailureAndExplicitResetClearSustainedLoad() {
        var fixture = HighlightFixture()
        for (time, cpu) in [(0.0, 0.0), (10, 6), (20, 12)] { _ = fixture.read(time, cpu: cpu) }
        XCTAssertEqual(fixture.read(30, cpu: 18).count, 1)
        XCTAssertTrue(fixture.read(90, cpu: 54).isEmpty, "A collection gap cannot extend confirmation")
        _ = fixture.read(100, cpu: 60)
        _ = fixture.read(110, cpu: 66)
        XCTAssertEqual(fixture.read(120, cpu: 72).count, 1)
        XCTAssertTrue(fixture.read(130, cpu: 78, error: "Unavailable").isEmpty)
        for (time, cpu) in [(140.0, 84.0), (150, 90), (160, 96)] { XCTAssertTrue(fixture.read(time, cpu: cpu).isEmpty) }
        XCTAssertEqual(fixture.read(170, cpu: 102).count, 1)
        fixture.highlights.reset()
        XCTAssertTrue(fixture.read(180, cpu: 108).isEmpty)
    }

    func testUnverifiedProcessAndNewAppMemberDoNotBecomeConfirmedApps() {
        var fixture = HighlightFixture()
        for time in [0.0, 10, 20, 30, 40] {
            XCTAssertTrue(fixture.read(time, cpu: time * 0.8, verifiedApp: false).isEmpty)
        }
        var sampler = ProcessActivitySampler(), highlights = SustainedCPUActivity()
        let app = ProcessApplicationIdentity(key: "app", name: "Fixture app", bundlePath: "/Fixture.app")
        for time in [0.0, 10, 20, 30] {
            var counters = [ProcessResourceCounter(pid: 1, start: 1, name: "worker", application: app, cpuTicks: UInt64(time * 0.6 * 1e9))]
            if time == 30 { counters.append(.init(pid: 2, start: 2, name: "new", application: app, cpuTicks: 1)) }
            let snapshot = sampler.accept(.init(collectedAt: Date(), monotonic: time, counters: counters))
            XCTAssertTrue(highlights.accept(snapshot, monotonic: time).isEmpty)
        }
    }
}

private struct HighlightFixture {
    var sampler = ProcessActivitySampler()
    var highlights = SustainedCPUActivity()
    mutating func read(_ time: Double, cpu: Double?, start: UInt64 = 1, verifiedApp: Bool = true, error: String? = nil) -> [ProcessActivityRow] {
        let app = verifiedApp ? ProcessApplicationIdentity(key: "app", name: "Fixture app", bundlePath: "/Fixture.app") : nil
        let counters = cpu.map { [ProcessResourceCounter(pid: 1, start: start, name: "worker", application: app, cpuTicks: UInt64($0 * 1e9))] } ?? []
        let snapshot = sampler.accept(.init(collectedAt: Date(), monotonic: time, counters: counters, deniedCount: cpu == nil ? 1 : 0, collectionError: error))
        return highlights.accept(snapshot, monotonic: time)
    }
}
