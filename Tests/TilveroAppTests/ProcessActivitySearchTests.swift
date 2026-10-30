import XCTest
import PowerTelemetry
@testable import TilveroApp

final class ProcessActivitySearchTests: XCTestCase {
    func testWhitespaceReturnsRowsInOriginalOrderWithoutHidingUnknownCPU() {
        let rows = sampledRows(["Safari", "Finder", "Процесс"], unknownCPU: true)
        XCTAssertEqual(rows.count, 3)
        let result = ProcessActivitySearch.result(rows, query: " \n\t ")
        XCTAssertEqual(result.rows.map(\.id), rows.map(\.id))
        XCTAssertEqual(result.matchingCount, rows.count)
        XCTAssertFalse(result.isFiltering)
        XCTAssertTrue(result.rows.allSatisfy { $0.cpuPercent == nil })
    }

    func testCaseInsensitiveTrimmedNameSearchPreservesMeasurementsAndOrder() {
        let rows = sampledRows(["Safari", "Safari Web Content", "Finder", "Процесс"])
        let result = ProcessActivitySearch.result(rows, query: "  sAfArI\n")
        let expected = rows.filter { $0.name.hasPrefix("Safari") }
        XCTAssertEqual(result.rows.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.rows.map(\.cpuPercent), expected.map(\.cpuPercent))
        XCTAssertEqual(result.matchingCount, 2)
        XCTAssertTrue(result.isFiltering)
        XCTAssertEqual(ProcessActivitySearch.result(rows, query: "ПРОЦЕСС").rows.map(\.name), ["Процесс"])
    }

    func testNoMatchDoesNotBecomeUnavailableOrMutateOriginalRows() {
        let rows = sampledRows(["Safari", "Finder"])
        let ids = rows.map(\.id)
        let result = ProcessActivitySearch.result(rows, query: "Xcode")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.matchingCount, 0)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertTrue(result.isFiltering)
        XCTAssertEqual(rows.map(\.id), ids)
    }

    func testSearchFindsAProcessBeyondUnfilteredDisplayLimit() {
        let names = ["Unique target"] + (1...129).map { "Worker \($0)" }
        let rows = sampledRows(names)
        XCTAssertFalse(rows.prefix(100).contains { $0.name == "Unique target" })
        let result = ProcessActivitySearch.result(rows, query: "unique target")
        XCTAssertEqual(result.rows.map(\.name), ["Unique target"])
        XCTAssertEqual(result.matchingCount, 1)
        XCTAssertEqual(result.totalCount, 130)
    }

    func testDisplayLimitDoesNotMisreportTotalMatches() {
        let rows = sampledRows((1...130).map { "Worker \($0)" })
        let result = ProcessActivitySearch.result(rows, query: "worker")
        XCTAssertEqual(result.rows.count, 100)
        XCTAssertEqual(result.matchingCount, 130)
        XCTAssertEqual(result.totalCount, 130)
        XCTAssertEqual(result.rows.map(\.id), Array(rows.prefix(100)).map(\.id))
    }

    private func sampledRows(_ names: [String], unknownCPU: Bool = false) -> [ProcessActivityRow] {
        var sampler = ProcessActivitySampler()
        let time = Date(timeIntervalSince1970: 1_720_000_000)
        let before = names.enumerated().map { index, name in
            ProcessResourceCounter(pid: Int32(index + 1), start: 1, name: name, cpuTicks: unknownCPU ? 2_000_000 : 0)
        }
        _ = sampler.accept(.init(collectedAt: time, monotonic: 0, counters: before))
        let after = names.enumerated().map { index, name in
            ProcessResourceCounter(pid: Int32(index + 1), start: 1, name: name,
                                   cpuTicks: unknownCPU ? 1_000_000 : UInt64(index + 1) * 1_000_000)
        }
        return sampler.accept(.init(collectedAt: time.addingTimeInterval(1), monotonic: 1, counters: after)).rows
    }
}
