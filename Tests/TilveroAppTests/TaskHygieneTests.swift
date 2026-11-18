// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import PowerTelemetry
@testable import TilveroApp

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// `stop()` cancels the follow-up work the model starts on its own; a stopped model never runs a queued refresh or the
/// post-wake re-read afterwards.
@MainActor final class TaskHygieneTests: XCTestCase {
    private func make(reads: ReadCounter, processes: ReadCounter = ReadCounter()) -> TilveroModel {
        let prefs = makeTestDefaults("TaskHygiene").defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                            postWakeSettleSeconds: 0.05,
                            snapshotProvider: {
                                reads.next()
                                return BatterySnapshot(chargePercent: .init(value: 70, source: "fixture"), isExternalPower: .init(value: true, source: "fixture"))
                            },
                            processActivityProvider: {
                                processes.next()
                                return .init(collectedAt: Date(), monotonic: Double(processes.value), counters: [])
                            })
    }

    func testStopCancelsTheWakeRefreshAndTheReReadAfterTheSettleWindow() async throws {
        let reads = ReadCounter()
        let model = make(reads: reads)
        model.setSleeping(true)
        model.setSleeping(false)
        XCTAssertGreaterThanOrEqual(model.ownedTaskCount, 2, "The wake refresh and the settle re-read are owned by the model")
        model.stop()
        XCTAssertEqual(model.ownedTaskCount, 0)
        try await Task.sleep(for: .milliseconds(3300))   // past the settle window (0.05 s) plus the 3 s margin
        XCTAssertEqual(reads.value, 0, "A stopped model reads nothing more")
    }

    func testAnOwnedTaskForgetsItselfWhenItIsDone() async throws {
        let processes = ReadCounter()
        let model = make(reads: ReadCounter(), processes: processes)
        defer { model.stop() }
        model.selectedSection = .activity
        model.isDetailVisible = true   // the Activity page appeared: one scan now
        XCTAssertEqual(model.ownedTaskCount, 1)
        for _ in 0..<100 where model.ownedTaskCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.ownedTaskCount, 0)
        XCTAssertEqual(processes.value, 1)
    }
}
