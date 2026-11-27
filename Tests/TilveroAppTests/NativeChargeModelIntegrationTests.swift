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
            let service = f.makeService()
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
        let service = f.makeService()
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
        let service = f.makeService()
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
        let service = f.makeService()
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
        let service = f.makeService()
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
        let service = f.makeService()
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

// MARK: Surfaces show what macOS reports (A5)

extension NativeChargeModelIntegrationTests {
    func testTheEditorShowsWhatMacOSReportsNeverTheDraft() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        model.setDraft(95)
        XCTAssertEqual(ChargeLimitKit.shown(chosen: nil, model: model), 90, "macOS's value, not the lingering draft")
        XCTAssertEqual(ChargeLimitKit.shown(chosen: 85, model: model), 85, "the slider's own choice while it is applied")
        // An unresolved session never makes the readout show the journal's value.
        await f.client.setMode("conflict")
        do { try await service.apply(85); XCTFail("unconfirmed") } catch {}
        await f.client.setMode("")
        await f.client.external(target: 95)   // System Settings
        await model.refreshNativeCharge()
        XCTAssertEqual(model.draftTarget, 95)
        XCTAssertEqual(ChargeLimitKit.shown(chosen: nil, model: model), 95)
        await f.assertWrites(["limit85"])
    }

    func testARefusedReleaseResetsTheDraftAndSaysWhyWithoutAWrite() async throws {
        let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        await f.client.setMode("disabled")   // macOS's temporary "charge to full": disabled with a target
        await model.refreshNativeCharge()
        XCTAssertEqual(ChargeLimitKit.shown(chosen: nil, model: model), 100, "disabled+80 shows 100")
        XCTAssertEqual(model.draftTarget, 100)
        model.releaseChargeLimit(at: 85)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.draftTarget, 100, "the thumb returns to what macOS reports")
        XCTAssertEqual(model.notice, L10n.text("Use System Settings › Battery to change this limit."))
        await f.assertWrites([])
    }

    func testAReleaseThatCanApplyWritesOnce() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        model.releaseChargeLimit(at: 85)
        try await settle(model)
        XCTAssertEqual(service.reportedLimit, 85)
        XCTAssertEqual(model.draftTarget, 85)
        await f.assertWrites(["limit85"])
    }

    func testTheRegistryIsEvidenceOfTheLimitOnlyOnAC() throws {
        func decode(_ json: String) throws -> SystemChargeLimits { try JSONDecoder().decode(SystemChargeLimits.self, from: Data(json.utf8)) }
        let limits = try decode(#"{"manualLimit":85,"otherLimits":[],"manualLimitIsConflicting":false}"#)
        XCTAssertEqual(SystemChargeLimitObservation(limits: limits, readOnExternalPower: true).evidentManualLimit(), 85)
        XCTAssertNil(SystemChargeLimitObservation(limits: limits, readOnExternalPower: false).evidentManualLimit(), "battery: stale rows")
        XCTAssertNil(SystemChargeLimitObservation(limits: limits).evidentManualLimit(), "unknown power state")
        XCTAssertNil(SystemChargeLimitObservation(collectedAt: Date().addingTimeInterval(-100), limits: limits, readOnExternalPower: true).evidentManualLimit(), "stale")
        let conflict = try decode(#"{"otherLimits":[],"manualLimitIsConflicting":true}"#)
        XCTAssertNil(SystemChargeLimitObservation(limits: conflict, readOnExternalPower: true).evidentManualLimit())
        let old = Data(#"{"collectedAt":0,"limits":{"manualLimit":80,"otherLimits":[],"manualLimitIsConflicting":false}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SystemChargeLimitObservation.self, from: old).readOnExternalPower, "older encodings decode")
    }
}

// MARK: Review fixes: unresolved lifts, read-only states, failed starts

extension NativeChargeModelIntegrationTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 where !(await condition()) { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// The setter hangs past the gate deadline: the stored setting is unknown (not the pre-write 80), nothing is decided
    /// while the call is pending, and once it lands (100) the previous limit returns on unplug.
    func testAChargeOnceLiftWhoseSetterTimesOutKeepsItsIntentAndIsUndoneAfterItLands() async throws {
        let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService(operationTimeout: .milliseconds(150))
        let source = SnapshotSource(percent: 60, charging: true, externalPower: true)
        let (model, suite) = f.makeModel(service, snapshot: { source.read() })
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        XCTAssertTrue(model.canStartChargeOnce)
        await f.client.holdWrites()
        model.startChargeOnce()
        try await waitUntil { await f.client.isHoldingWrite }
        try await settle(model)   // the gate deadline passed: the action returned with the call still pending
        XCTAssertTrue(service.operationPending)
        XCTAssertTrue(service.hasUnresolvedSession)
        XCTAssertNil(service.reportedLimit, "the outcome is unknown: never the pre-write 80")
        XCTAssertNil(model.chargeByObservation.observedLimit)
        XCTAssertEqual(model.chargeOnce.previousTarget, 80)
        await model.refresh()
        XCTAssertEqual(model.chargeOnce.previousTarget, 80, "nothing is decided while the setter has not returned")
        await f.client.releaseWrite()   // the write lands late: macOS stores 100
        try await waitUntil { !service.operationPending }
        XCTAssertEqual(service.message, NativeChargeService.lateAnswerMessage)
        await model.refreshNativeCharge()
        XCTAssertEqual(service.reportedLimit, 100)
        XCTAssertNil(service.message, "a successful read clears the late-answer line")
        await model.refresh()
        XCTAssertEqual(model.chargeOnce.previousTarget, 80, "still charging: kept")
        source.set(percent: 70, charging: false, externalPower: false)
        await model.refresh()
        try await settle(model)
        XCTAssertNil(model.chargeOnce.previousTarget)
        XCTAssertEqual(service.reportedLimit, 80)
        await f.assertWrites(["limit100", "limit80"])
    }

    /// The setter returned but macOS still reads the old 80 for a while: the session is unresolved, so a reading of 80 does
    /// not drop the intent; once macOS shows 100 and the session closes, the previous limit returns on unplug.
    func testAChargeOnceLiftThatStillReadsTheOldValueKeepsItsIntentUntilTheSessionResolves() async throws {
        let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService()
        let source = SnapshotSource(percent: 60, charging: true, externalPower: true)
        let (model, suite) = f.makeModel(service, snapshot: { source.read() })
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        await f.client.lagNextWrite(reads: 2)   // the readback and the refresh after it still read 80
        model.startChargeOnce()
        try await settle(model)
        XCTAssertTrue(service.hasUnresolvedSession)
        XCTAssertEqual(service.reportedLimit, 80, "macOS still reports the old value")
        XCTAssertEqual(model.chargeOnce.previousTarget, 80, "a write of its own is on disk: kept")
        await model.refresh()
        XCTAssertEqual(model.chargeOnce.previousTarget, 80, "a reading of 80 while the session is unresolved drops nothing")
        await model.refreshNativeCharge()   // the write has landed
        XCTAssertEqual(service.reportedLimit, 100)
        try f.settle()
        await model.refreshNativeCharge()   // a settled clear read closes the session
        XCTAssertFalse(service.hasUnresolvedSession)
        await model.refresh()
        XCTAssertEqual(model.chargeOnce.previousTarget, 80)
        source.set(percent: 70, charging: false, externalPower: false)
        await model.refresh()
        try await settle(model)
        XCTAssertNil(model.chargeOnce.previousTarget)
        XCTAssertEqual(service.reportedLimit, 80)
        await f.assertWrites(["limit100", "limit80"])
    }

    /// A start that fails before anything is dispatched lifted nothing: the pill returns at once (no "Charging to 100%"
    /// until the next poll), also when an older session is still on disk.
    func testAChargeOnceStartThatFailsBeforeAnyWriteClearsItsIntentAtOnce() async throws {
        for leftover in [false, true] {
            let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
            if leftover { try f.writeSessionJournal(phase: .indeterminate) }
            let service = f.makeService()
            let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
            defer { model.stop(); TestDefaults.remove(suite) }
            await model.refreshNativeCharge()
            XCTAssertTrue(model.canStartChargeOnce, "\(leftover)")
            XCTAssertEqual(service.hasUnresolvedSession, leftover)
            await f.client.setMode("unknown")   // the start's own read fails: nothing can be written
            model.startChargeOnce()
            try await settle(model)
            XCTAssertNil(model.chargeOnce.previousTarget, "\(leftover): nothing was lifted")
            XCTAssertFalse(model.isChargeOnceRunning)
            XCTAssertNotNil(model.notice, "the failure is said once")
            XCTAssertEqual(service.hasUnresolvedSession, leftover, "an older session is not this tap's write")
            await f.assertWrites([], "\(leftover)")
        }
    }

    /// macOS's temporary charge to full (disabled with a target) while the AC registry still lists the row: shown read-only
    /// (no live-looking slider, no dead charge-once or charge-by), and a refusal names the real reason; the slider returns
    /// with a valid state.
    func testATemporaryChargeToFullStateIsReadOnlyAndRecovers() async throws {
        let f = ScopeFixture(initialTarget: 80); defer { f.cleanup() }
        let service = f.makeService()
        let (model, suite) = f.makeModel(service, percent: 60, charging: true, externalPower: true)
        defer { model.stop(); TestDefaults.remove(suite) }
        await model.refreshNativeCharge()
        let targets = ChargeLimitKit.targets(model)
        XCTAssertEqual(ChargeLimitKit.mode(model), .slider)
        XCTAssertTrue(ChargeLimitKit.sliderLook(model, targets: targets).offered)
        XCTAssertTrue(ChargeLimitKit.showsChargeOnce(model))
        await f.client.setMode("disabledListed")
        await model.refreshNativeCharge()
        XCTAssertTrue(service.admitted)
        XCTAssertEqual(service.message, NativeChargeService.policyUnconfirmedMessage)
        XCTAssertEqual(ChargeLimitKit.mode(model), .unavailable)
        XCTAssertEqual(ChargeLimitKit.reported(model), 100)
        XCTAssertEqual(ChargeLimitKit.shown(chosen: nil, model: model), 100)
        XCTAssertFalse(ChargeLimitKit.sliderLook(model, targets: targets).offered)
        XCTAssertFalse(ChargeLimitKit.showsChargeOnce(model))
        XCTAssertFalse(ChargeLimitKit.showsChargeBy(model, armed: false))
        XCTAssertEqual(model.chargeLimitRefusal, "Use System Settings › Battery to change this limit.")
        model.releaseChargeLimit(at: 85)
        XCTAssertEqual(model.notice, L10n.text("Use System Settings › Battery to change this limit."),
                       "the real reason, not the registry line the quick panel filters out")
        await f.client.setMode("")
        await model.refreshNativeCharge()
        XCTAssertEqual(ChargeLimitKit.mode(model), .slider)
        XCTAssertTrue(ChargeLimitKit.sliderLook(model, targets: targets).offered)
        await f.assertWrites([])
    }

    /// The pmset fallback panel builds its headline as the window's read-only row: a row read on battery power is never the
    /// limit (only a secondary caption), a row read on AC is, and the native setting wins over both.
    func testTheFallbackPanelNeverShowsABatteryRowAsTheLimit() throws {
        let limits = try JSONDecoder().decode(SystemChargeLimits.self, from: Data(#"{"manualLimit":80,"otherLimits":[],"manualLimitIsConflicting":false}"#.utf8))
        let battery = SystemChargeLimitObservation(limits: limits, readOnExternalPower: false)
        XCTAssertEqual(SystemChargeLimitPanel.headline(native: nil, observation: battery, language: "en"), "—")
        XCTAssertEqual(SystemChargeLimitPanel.unconfirmedRow(battery), 80)
        let unknown = SystemChargeLimitObservation(limits: limits)
        XCTAssertEqual(SystemChargeLimitPanel.headline(native: nil, observation: unknown, language: "en"), "—")
        XCTAssertEqual(SystemChargeLimitPanel.unconfirmedRow(unknown), 80)
        let ac = SystemChargeLimitObservation(limits: limits, readOnExternalPower: true)
        XCTAssertEqual(SystemChargeLimitPanel.headline(native: nil, observation: ac, language: "en"), "80%")
        XCTAssertNil(SystemChargeLimitPanel.unconfirmedRow(ac))
        let native = NativeChargeConfiguration(enabled: false, target: 100, optimizedCharging: true)
        XCTAssertEqual(SystemChargeLimitPanel.headline(native: native, observation: battery, language: "en"), "100%")
    }
}
