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

/// Holds the snapshot reading open until the test lets it finish.
private actor ReadingGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    var isWaiting: Bool { waiting != nil }
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { open = true; waiting?.resume(); waiting = nil }
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
        model.isDetailVisible = true   // the Activity page appeared: one scan now, and the charge limit is read again
        XCTAssertEqual(model.ownedTaskCount, 2)
        for _ in 0..<100 where model.ownedTaskCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.ownedTaskCount, 0)
        XCTAssertEqual(processes.value, 1)
    }

    /// A refresh still awaiting its reading when the model stops must not schedule the queued wake refresh afterwards.
    func testARefreshInFlightAtStopSchedulesNothingAfterwards() async throws {
        let reads = ReadCounter(), gate = ReadingGate()
        let prefs = makeTestDefaults("TaskHygiene").defaults
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs,
                                 snapshotProvider: {
                                     reads.next(); await gate.wait()
                                     return BatterySnapshot(chargePercent: .init(value: 70, source: "fixture"), isExternalPower: .init(value: true, source: "fixture"))
                                 })
        let inFlight = Task { await model.refresh() }
        for _ in 0..<100 { if await gate.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        model.setSleeping(true); model.setSleeping(false)   // a wake while the reading is open queues another refresh
        model.stop()
        await gate.release()
        await inFlight.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.value, 1, "Only the reading that was already in flight")
        XCTAssertEqual(model.ownedTaskCount, 0)
        await model.refresh()
        XCTAssertEqual(reads.value, 1, "A stopped model does not refresh")
    }
}
