// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

/// The model-level contract of the native charge limit, against the real service over a fixture transport (never the live
/// PowerUI client): quit, logout and update never write the limit or refuse because of it; charge-by and charge-once keep
/// the user's previous limit and never overwrite a value changed elsewhere. Every case asserts the writes.
@MainActor final class NativeChargeModelIntegrationTests: XCTestCase {
    // MARK: Quit, logout, update (A3)

    func testLeftoverSessionsNeverMakeQuitWriteOrRefuse() async throws {
        let cases: [(String, String, (ScopeFixture) throws -> Void)] = [
            ("user", "", { try $0.writeSessionJournal(phase: .indeterminate, qualification: false) }),
            ("validation", "", { try $0.writeSessionJournal(phase: .indeterminate, qualification: true) }),
            ("pre-0.8.2", "", { try $0.writeSessionJournal(phase: .indeterminate, qualification: nil) }),
            ("owned", "", { try $0.writeSessionJournal(phase: .owned, qualification: false, expected: nil, lastVerified: 85) }),
            ("restorationPending", "", { try $0.writeSessionJournal(phase: .restorationPending, qualification: false, expected: nil, lastVerified: 85) }),
            ("unreadable", "", { f in
                try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: f.journal)
            }),
            ("AC conflict", "conflict", { try $0.writeSessionJournal(phase: .indeterminate, qualification: false, age: 120) }),
        ]
        for (label, mode, arrange) in cases {
            let f = ScopeFixture(mode: mode); defer { f.cleanup() }
            try arrange(f)
            let bytes = try Data(contentsOf: f.journal)
            let service = f.makeService(implicit: true)
            let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
            defer { model.stop(); TestDefaults.remove(suite) }
            await service.refresh()
            XCTAssertTrue(service.hasUnresolvedSession, label)
            let quit = await model.prepareForTermination()
            XCTAssertTrue(quit, "\(label): a normal quit never refuses")
            let logout = await model.prepareForTermination(systemInitiated: true)
            XCTAssertTrue(logout, "\(label): logout and shutdown never refuse")
            let update = await model.prepareForUpdateInstallation()
            _ = update   // this profile defers updates; whatever it says, it writes nothing
            XCTAssertNil(model.terminationRecoveryMessage, label)
            XCTAssertEqual(try Data(contentsOf: f.journal), bytes, "\(label): the session file stays for the next launch")
            await f.assertWrites([], label)
        }
    }

    func testQuitDuringAWriteWaitsForItOnlyWhenItCan() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        await f.client.holdWrites()
        model.setDraft(85)
        XCTAssertTrue(model.canApply)
        model.applyDraftTarget()
        for _ in 0..<500 where !(await f.client.isHoldingWrite) { await Task.yield() }
        let holding = await f.client.isHoldingWrite
        XCTAssertTrue(holding)
        XCTAssertTrue(model.nativeActionInFlight)
        // Logout and shutdown cannot wait: the write is journaled before dispatch and resolves at the next launch.
        let logout = await model.prepareForTermination(systemInitiated: true)
        XCTAssertTrue(logout)
        XCTAssertTrue(service.isBusy, "the write is still running")
        XCTAssertTrue(f.journalExists, "write-ahead journal on disk")
        // An ordinary quit waits for the write to read back, then goes ahead.
        let quit = Task { await model.prepareForTermination() }
        for _ in 0..<20 { await Task.yield() }
        await f.client.releaseWrite()
        let quitResult = await quit.value
        XCTAssertTrue(quitResult)
        XCTAssertFalse(service.isBusy)
        XCTAssertFalse(f.journalExists, "the confirmed write is the user's own setting")
        XCTAssertEqual(service.reportedLimit, 85)
        await f.assertWrites(["limit85"])
    }
}

/// The battery reading a model test changes between refreshes (plugged in, unplugged, full).
final class SnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BatterySnapshot
    init(percent: Int?, charging: Bool?, externalPower: Bool?) {
        value = ScopeFixture.snapshot(percent: percent, charging: charging, externalPower: externalPower)
    }
    func set(percent: Int?, charging: Bool?, externalPower: Bool?) {
        let next = ScopeFixture.snapshot(percent: percent, charging: charging, externalPower: externalPower)
        lock.lock(); value = next; lock.unlock()
    }
    func read() -> BatterySnapshot { lock.lock(); defer { lock.unlock() }; return value }
}

extension NativeChargeModelIntegrationTests {
    private func settle(_ model: TilveroModel) async throws {
        for _ in 0..<400 where model.isApplying || model.nativeCharge.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isApplying)
    }

    // MARK: Charge-once and charge-by keep the user's previous limit (A4)

    func testAChargeOnceLiftThatReadsBackLateStillRestoresThePreviousLimitOnUnplug() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        let source = SnapshotSource(percent: 60, charging: true, externalPower: true)
        let (model, suite) = f.makeModel(service, snapshot: { source.read() })
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        XCTAssertTrue(model.canStartChargeOnce)
        await f.client.failReadsAfterNextWrite()
        model.startChargeOnce()
        try await settle(model)
        XCTAssertEqual(model.chargeOnce.previousTarget, 90, "the intent was recorded before the write")
        await f.client.clearReadFailure()
        await model.refreshNativeCharge()   // the lift landed: macOS reads 100
        XCTAssertEqual(model.nativeCharge.reportedLimit, 100)
        await model.refresh()
        XCTAssertEqual(model.chargeOnce.previousTarget, 90, "still charging: kept")
        source.set(percent: 70, charging: false, externalPower: false)
        await model.refresh()
        try await settle(model)
        XCTAssertNil(model.chargeOnce.previousTarget)
        XCTAssertEqual(model.nativeCharge.reportedLimit, 90)
        await f.assertWrites(["limit100", "limit90"])
    }

    func testALimitSetInSystemSettingsDuringChargeOnceIsKept() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        let source = SnapshotSource(percent: 60, charging: true, externalPower: true)
        let (model, suite) = f.makeModel(service, snapshot: { source.read() })
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        model.startChargeOnce()
        try await settle(model)
        XCTAssertEqual(model.chargeOnce.previousTarget, 85)
        await f.client.external(target: 90)   // System Settings
        await model.refreshNativeCharge()
        source.set(percent: 70, charging: false, externalPower: false)
        await model.refresh()
        try await settle(model)
        XCTAssertNil(model.chargeOnce.previousTarget, "dropped: the user's own value wins")
        await f.assertWrites(["limit100"])
    }

    func testASavedChargeOnceIntentDecidesNothingBeforeTheFirstRead() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        let (model, suite) = f.makeModel(service, configure: { $0.set(85, forKey: "chargeOncePreviousTarget") },
                                         snapshot: { ScopeFixture.snapshot(percent: 70, charging: false, externalPower: false) })
        defer { model.stop(); TestDefaults.remove(suite) }
        XCTAssertEqual(model.chargeOnce.previousTarget, 85)
        await model.refresh()
        try await settle(model)
        XCTAssertEqual(model.chargeOnce.previousTarget, 85, "no decision before macOS reported the limit")
        XCTAssertNil(model.notice)
        await f.assertWrites([])
    }

    func testChargeByWritesNothingOverALimitChangedElsewhere() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let environment = ModelChargeByEnvironment(model: model)
        XCTAssertEqual(environment.observation().observedLimit, 90)
        let stale = await environment.apply(limit: 100, expected: 80)
        XCTAssertEqual(stale, .changedElsewhere)
        await f.assertWrites([])
        let lifted = await environment.apply(limit: 100, expected: 90)
        XCTAssertEqual(lifted, .confirmed)
        await f.assertWrites(["limit100"])
    }
}
