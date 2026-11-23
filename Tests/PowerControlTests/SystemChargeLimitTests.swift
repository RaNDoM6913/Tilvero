// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
@testable import ChargeBackends

final class SystemChargeLimitTests: XCTestCase {
    func testManualLimitIsSeparateFromOptimizedAndTerminatedRequests() throws {
        let value = try SystemChargeLimitParser.parse("""
        Battery level limits:
        (
          { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 85; },
          { Terminated = 0; chargeSocLimitReason = optimizedBatteryCharging; chargeSocLimitSoc = 80; },
          { Terminated = 1; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 90; }
        )
        """)
        XCTAssertEqual(value.manualLimit, 85)
        XCTAssertEqual(value.otherLimits, [80])
        XCTAssertFalse(value.manualLimitIsConflicting)
    }

    func testNoPolicyIsDifferentFromUnavailableOrConflicting() throws {
        XCTAssertNil(try SystemChargeLimitParser.parse("No battery level limits set").manualLimit)
        XCTAssertThrowsError(try SystemChargeLimitParser.parse("Battery level limits:\n({chargeSocLimitSoc = 180;})"))
        XCTAssertThrowsError(try SystemChargeLimitParser.parse("unknown output"))
        let conflict = try SystemChargeLimitParser.parse("""
        Battery level limits:
        ({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;},
         {Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=90;})
        """)
        XCTAssertNil(conflict.manualLimit)
        XCTAssertTrue(conflict.manualLimitIsConflicting)
    }

    func testObservationExpiresAndMissingReadbackNeverBecomesFresh() throws {
        let now = Date()
        let limits = try SystemChargeLimitParser.parse("No battery level limits set")
        XCTAssertTrue(SystemChargeLimitObservation(collectedAt: now, limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now.addingTimeInterval(-66), limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now.addingTimeInterval(10), limits: limits).isFresh(at: now))
        XCTAssertFalse(SystemChargeLimitObservation(collectedAt: now, limits: nil).isFresh(at: now))
    }

    func testUnknownAndMalformedRowsNeverBecomeManualLimit() throws {
        XCTAssertEqual(try SystemChargeLimitParser.parse("Battery level limits:\n({Terminated=0;chargeSocLimitReason=newPolicy;chargeSocLimitSoc=70;})").otherLimits, [70])
        for row in ["{chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;}",
                    "{Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85.5;}",
                    "{Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;} trailing"] {
            XCTAssertThrowsError(try SystemChargeLimitParser.parse("Battery level limits:\n(\(row))"))
        }
    }

    func testObservationReusesTheNativeAnswerOfTheSameCycleAndRunsTheCommandOtherwise() throws {
        let clock = ManualClock(), readings = BatteryLimitReadings(now: { clock.now })
        var runs = 0
        let query = { () throws -> String in runs += 1; return "No battery level limits set" }
        let first = SystemChargeLimitObservation.read(readings: readings, query: query)
        XCTAssertEqual(runs, 1, "Nothing recorded yet: the observation runs the command")
        XCTAssertNotNil(first.limits)
        let nativeReadAt = Date(timeIntervalSince1970: 1_800_000_000)
        readings.record("Battery level limits:\n({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=85;})", collectedAt: nativeReadAt)
        clock.advance(2)
        let shared = SystemChargeLimitObservation.read(readings: readings, query: query)
        XCTAssertEqual(runs, 1, "The native read of the same cycle is reused")
        XCTAssertEqual(shared.limits?.manualLimit, 85)
        XCTAssertEqual(shared.collectedAt, nativeReadAt, "A reused answer keeps its own read time")
        clock.advance(BatteryLimitReadings.reuseWindow)
        _ = SystemChargeLimitObservation.read(readings: readings, query: query)
        XCTAssertEqual(runs, 2, "An answer older than the window is read again")
        _ = SystemChargeLimitObservation.read(readings: readings, maximumAge: 0, query: query)
        XCTAssertEqual(runs, 3, "No reuse when none is allowed")
        let failing = SystemChargeLimitObservation.read(readings: BatteryLimitReadings(now: { clock.now }), query: { throw PolicyError.readbackMismatch })
        XCTAssertNil(failing.limits, "A failed read is unavailable, never a plausible value")
    }

    func testTheNativeReadbackAlwaysRunsTheCommandAndAFailureForgetsTheSharedAnswer() throws {
        let clock = ManualClock(), readings = BatteryLimitReadings(now: { clock.now })
        readings.record("No battery level limits set")
        var runs = 0
        let fresh = PowerUIChargeClient.policyReadback(readings: readings) {
            runs += 1
            return "Battery level limits:\n({Terminated=0;chargeSocLimitReason=manualChargeLimit;chargeSocLimitSoc=90;})"
        }
        XCTAssertEqual(runs, 1, "A recorded answer is never used by the native read")
        XCTAssertEqual(fresh?.manualLimit, 90)
        XCTAssertEqual(try XCTUnwrap(readings.recent(maximumAge: 5)).output.contains("chargeSocLimitSoc=90"), true, "Its answer is shared")
        XCTAssertNil(PowerUIChargeClient.policyReadback(readings: readings) { throw PolicyError.readbackMismatch })
        XCTAssertNil(readings.recent(maximumAge: 5), "A failed run forgets the previous answer")
        readings.record("No battery level limits set")
        _ = SystemChargeLimitObservation.read(readings: readings, maximumAge: 0, query: { throw PolicyError.readbackMismatch })
        XCTAssertNil(readings.recent(maximumAge: 5), "So does a failed observation")
        readings.record("No battery level limits set"); readings.invalidate()
        XCTAssertNil(readings.recent(maximumAge: 5))
    }

    func testBoundedProcessKeepsItsExactAllowList() {
        for (path, arguments) in [("/usr/bin/pmset", ["-b", "lowpowermode", "1"]), ("/usr/bin/pmset", ["-g", "battlimit", "x"]),
                                  ("/usr/bin/pmset", ["schedule", "wake"]), ("/bin/echo", ["-g", "battlimit"])] {
            XCTAssertThrowsError(try BoundedProcess.read(executable: path, arguments: arguments)) { error in
                XCTAssertEqual(error as? PolicyError, .invalidPolicy, "\(path) \(arguments) is refused before anything runs")
            }
        }
    }

    func testBoundedRunWaitsForTheExitAndTheOutputWithoutPolling() throws {
        let echoed = try XCTUnwrap(try BoundedProcess.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5, captureOutput: true))
        XCTAssertEqual(echoed.status, 0)
        XCTAssertEqual(String(data: echoed.output, encoding: .utf8), "hello\n")
        XCTAssertFalse(echoed.overflowed)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroBounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x61, count: 300_000).write(to: file)
        let large = try XCTUnwrap(try BoundedProcess.run(executable: "/bin/cat", arguments: [file.path], timeout: 5, captureOutput: true, outputLimit: 1024))
        XCTAssertEqual(large.status, 0, "A long answer is drained, so the command never blocks on a full pipe")
        XCTAssertEqual(large.output.count, 1024)
        XCTAssertTrue(large.overflowed)
        let failed = try XCTUnwrap(try BoundedProcess.run(executable: "/usr/bin/false", arguments: [], timeout: 5, captureOutput: false))
        XCTAssertNotEqual(failed.status, 0)
    }

    func testBoundedRunStopsACommandThatOutlivesItsTimeout() throws {
        let started = Date()
        XCTAssertNil(try BoundedProcess.run(executable: "/bin/sleep", arguments: ["20"], timeout: 0.3, captureOutput: true))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.advanced(by: .seconds(seconds)) } }
}
