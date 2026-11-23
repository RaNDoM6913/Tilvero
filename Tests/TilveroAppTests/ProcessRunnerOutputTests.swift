// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

/// The shared runner reads output while the process runs: more than a pipe holds (64 KB) never stalls until the timeout,
/// and what is kept stays bounded. Runs only harmless shell commands.
final class ProcessRunnerOutputTests: XCTestCase {
    func testOutputLargerThanAPipeArrivesWithoutWaitingForTheTimeout() async {
        let started = ContinuousClock.now
        let result = await ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\000' a"], timeout: 20)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 200_000)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "Finished on exit, not on the timeout.")
    }

    func testTheKeptOutputIsCappedWhileTheRestIsDrained() async {
        let result = await ProcessRunner.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\000' b; exit 7"], timeout: 20)
        XCTAssertEqual(result.status, 7, "The process ran to its own exit.")
        XCTAssertEqual(result.output.utf8.count, ProcessRunner.outputLimit)
    }

    func testShortOutputAndStatusAreUnchanged() async {
        let result = await ProcessRunner.run("/bin/sh", ["-c", "printf 'SleepDisabled\\t\\t0\\n'; exit 0"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "SleepDisabled\t\t0\n")
    }
}
