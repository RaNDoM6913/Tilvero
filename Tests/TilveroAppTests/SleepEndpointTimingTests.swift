import XCTest
@testable import TilveroApp
import PowerCore

final class SleepEndpointTimingTests: XCTestCase {
    func testShowsReadingOffsetsRatherThanHidingSixtySecondWindow() throws {
        let run = UUID(), origin = Date()
        func stamp(_ seconds: Double, runID: UUID? = nil) -> SleepObservationStamp {
            .init(wallDate: origin.addingTimeInterval(seconds), continuousSeconds: 100 + seconds, runID: runID ?? run)
        }
        func endpoint(_ seconds: Double) throws -> SleepBatteryEndpoint {
            let at = origin.addingTimeInterval(seconds)
            return try XCTUnwrap(.init(snapshot: BatterySnapshot(chargePercent: .init(value: 80, source: "fixture", collectedAt: at), collectedAt: at), stamp: stamp(seconds)))
        }
        XCTAssertEqual(SleepEndpointTiming.seconds(try endpoint(0), boundary: stamp(10), before: true), 10)
        XCTAssertEqual(SleepEndpointTiming.seconds(try endpoint(20), boundary: stamp(15), before: false), 5)
        XCTAssertNil(SleepEndpointTiming.seconds(try endpoint(0), boundary: stamp(100), before: true))
        XCTAssertNil(SleepEndpointTiming.seconds(try endpoint(0), boundary: stamp(10, runID: UUID()), before: true))
    }
}
