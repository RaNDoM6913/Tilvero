import XCTest
import PowerTelemetry
@testable import TilveroApp

final class ProcessActivityFilteringTests: XCTestCase {
    func testTopThreeRanksAllRowsByPowerBeforeTruncating() {
        let values = (0..<130).map { index in
            Spec("Process \(index)", cpu: Double(130 - index), watts: Double(index))
        }
        let rows = makeRows(values)
        let result = ProcessActivitySearch.result(rows, query: "", sort: .cpuPower, scope: .topThree)
        XCTAssertEqual(result.rows.map(\.name), ["Process 129", "Process 128", "Process 127"])
        XCTAssertEqual(result.matchingCount, 130)
        XCTAssertEqual(rows.map(\.name), values.map(\.name), "Presentation cannot reorder the collected input.")
    }

    func testUnknownPowerDoesNotFillOrInventATopThree() {
        let rows = makeRows([.init("Unknown", cpu: 100, watts: nil), .init("Zero", cpu: 0, watts: 0), .init("Known", cpu: 1, watts: 2)])
        let top = ProcessActivitySearch.result(rows, query: "", sort: .cpuPower, scope: .topThree)
        XCTAssertEqual(top.rows.map(\.name), ["Known", "Zero"])
        XCTAssertEqual(top.matchingCount, 3)
        let all = ProcessActivitySearch.result(rows, query: "", sort: .cpuPower, scope: .all)
        XCTAssertEqual(all.rows.map(\.name), ["Known", "Zero", "Unknown"])
        XCTAssertNil(all.rows.last?.cpuPowerWatts)
    }

    func testCPUSortKeepsUnknownAfterMeasuredZero() {
        let rows = makeRows([.init("Unknown", cpu: nil, watts: 9), .init("Zero", cpu: 0, watts: 8), .init("Busy", cpu: 150, watts: 1)])
        let result = ProcessActivitySearch.result(rows, query: "", sort: .cpuUsage, scope: .all)
        XCTAssertEqual(result.rows.map(\.name), ["Busy", "Zero", "Unknown"])
        XCTAssertNil(result.rows.last?.cpuPercent)
    }

    func testLoadBandsDoNotOverlapAndUnknownIsNotLowLoad() {
        let rows = makeRows([.init("Zero", cpu: 0), .init("Below ten", cpu: 9.999), .init("Ten", cpu: 10),
                             .init("Below fifty", cpu: 49.999), .init("Fifty", cpu: 50), .init("Multi core", cpu: 250),
                             .init("Unknown", cpu: nil)])
        func names(_ filter: ProcessActivityLoadFilter) -> [String] {
            ProcessActivitySearch.result(rows, query: "", filter: filter).rows.map(\.name)
        }
        XCTAssertEqual(names(.low), ["Zero", "Below ten"])
        XCTAssertEqual(names(.moderate), ["Ten", "Below fifty"])
        XCTAssertEqual(names(.high), ["Fifty", "Multi core"])
        XCTAssertEqual(names(.unknown), ["Unknown"])
        XCTAssertEqual(names(.all).count, 7)
    }

    func testInvalidNumbersAreNotRankedOrClassifiedAsLoad() {
        let rows = makeRows([.init("NaN", cpu: .nan, watts: .nan), .init("Infinity", cpu: .infinity, watts: .infinity),
                             .init("Negative", cpu: -1, watts: -1), .init("Measured", cpu: 5, watts: 0)])
        XCTAssertEqual(ProcessActivitySearch.result(rows, query: "", filter: .unknown).rows.map(\.name), ["NaN", "Infinity", "Negative"])
        XCTAssertEqual(ProcessActivitySearch.result(rows, query: "", sort: .cpuPower, scope: .topThree).rows.map(\.name), ["Measured"])
    }

    func testSearchAndLoadFilterApplyBeforePowerRankingAndLimit() {
        let rows = makeRows([.init("Other", cpu: 90, watts: 99), .init("Safari low", cpu: 2, watts: 9),
                             .init("Safari one", cpu: 60, watts: 3), .init("Safari two", cpu: 70, watts: 4),
                             .init("Safari three", cpu: 80, watts: 2), .init("Safari four", cpu: 90, watts: 1)])
        let result = ProcessActivitySearch.result(rows, query: "  sAfArI\n", filter: .high, sort: .cpuPower, scope: .topThree)
        XCTAssertEqual(result.rows.map(\.name), ["Safari two", "Safari one", "Safari three"])
        XCTAssertEqual(result.matchingCount, 4)
        XCTAssertEqual(result.totalCount, 6)
        XCTAssertTrue(result.isFiltering)
    }

    func testEqualMetricsRetainObservedOrderAndAllKeepsDisplayCountHonest() {
        let rows = makeRows((0..<130).map { Spec("Item \($0)", cpu: 50, watts: 1) })
        let result = ProcessActivitySearch.result(rows, query: "", filter: .high, sort: .cpuPower, scope: .all)
        XCTAssertEqual(result.rows.map(\.id), Array(rows.prefix(100)).map(\.id))
        XCTAssertEqual(result.matchingCount, 130)
        XCTAssertTrue(result.isFiltering)
    }

    func testExplicitAllCanExposeEveryCollectedRowBeyondLegacyLimit() {
        let rows = makeRows((0..<278).map { Spec("Item \($0)", cpu: Double($0), watts: Double($0)) })
        let result = ProcessActivitySearch.result(rows, query: "", sort: .cpuPower, scope: .all, displayLimit: nil)
        XCTAssertEqual(result.rows.count, 278)
        XCTAssertEqual(result.matchingCount, 278)
        XCTAssertEqual(result.rows.first?.name, "Item 277")
        XCTAssertEqual(result.rows.last?.name, "Item 0")
    }

    private struct Spec {
        let name: String
        var cpu: Double?
        var watts: Double? = 1
        init(_ name: String, cpu: Double?, watts: Double? = 1) { self.name = name; self.cpu = cpu; self.watts = watts }
    }
    private func makeRows(_ specs: [Spec]) -> [ProcessActivityRow] {
        var sampler = ProcessActivitySampler()
        let before = specs.enumerated().map { index, value in
            ProcessResourceCounter(pid: Int32(index + 1), start: 1, name: value.name, cpuTicks: 0, cpuEnergyNanojoules: 1)
        }
        _ = sampler.accept(.init(collectedAt: Date(), monotonic: 1, counters: before))
        let after = specs.enumerated().map { index, value in
            ProcessResourceCounter(pid: Int32(index + 1), start: 1, name: value.name, cpuTicks: 1_000_000, cpuEnergyNanojoules: 2)
        }
        let rows = sampler.accept(.init(collectedAt: Date(), monotonic: 2, counters: after)).rows
        return specs.map { spec in
            var row = rows.first { $0.name == spec.name }!
            row.cpuPercent = spec.cpu; row.cpuPowerWatts = spec.watts
            return row
        }
    }
}
