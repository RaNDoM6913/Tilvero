// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

@MainActor final class NativeChargeScopeTests: XCTestCase {
    func testModePreviewOffersOnlyThePersistentLevels() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        await f.service.refresh()
        let (model, suite) = f.makeModel(f.service)
        defer { model.stop(); TestDefaults.remove(suite) }
        for target in [80, 85, 95, 100] {
            let allowed = ModePlan(mode: .economy, chargeTarget: target, lowPower: false, displayIdleMinutes: nil, brightnessPercent: nil)
            XCTAssertEqual(model.modePreview(allowed).first { $0.action == .charge }?.status, .available, "\(target)")
        }
        let odd = ModePlan(mode: .economy, chargeTarget: 83, lowPower: false, displayIdleMinutes: nil, brightnessPercent: nil)
        XCTAssertEqual(model.modePreview(odd).first { $0.action == .charge }?.status, .excluded)
        await f.assertWrites([])
    }

    func testConstructionAndReadsNeverCreateFiles() async throws {
        let f = ScopeFixture(mode: "battery89"); defer { f.cleanup() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        await f.service.refresh()
        XCTAssertTrue(f.service.admitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path), "a read writes no journal, no proof, nothing")
        await f.assertWrites([])
    }

    /// The live interface grants the limit only for a state it recognises: an unrecognised, disabled-with-a-target or
    /// inconsistent state, a missing persistent level or a stale read grants nothing and writes nothing.
    func testTheLiveInterfaceGrantsNothingForAStateItDoesNotRecognise() async throws {
        for mode in ["unknown", "disabled", "baseline100", "offered", "stale"] {
            let f = ScopeFixture(mode: mode); defer { f.cleanup() }
            await f.service.refresh()
            XCTAssertFalse(f.service.admitted, mode)
            XCTAssertTrue(f.service.authorizedPersistentTargets.isEmpty, mode)
            do { try await f.service.apply(85); XCTFail("Must refuse \(mode)") } catch {}
            await f.assertWrites([], mode)
            XCTAssertFalse(f.journalExists, mode)
        }
    }

    /// A leftover session never closes, and nothing is written, while macOS reports a state Tilvero does not recognise.
    func testALeftoverStaysAndWritesNothingWhileMacOSReportsAStateItDoesNotRecognise() async throws {
        for mode in ["disabled", "baseline100", "unknown"] {
            let f = ScopeFixture(mode: mode); defer { f.cleanup() }
            let bytes = try f.writeSessionJournal(phase: .indeterminate, age: 120)
            let reopened = f.makeService()
            await reopened.refresh()
            XCTAssertTrue(reopened.hasUnresolvedSession, mode)
            await f.assertWrites([], mode)
            XCTAssertEqual(try Data(contentsOf: f.journal), bytes, mode)
        }
    }

    /// Optimized Battery Charging is its own macOS setting: flipping it (System Settings or Tilvero's own switch) never
    /// locks the limit slider or keeps a session open.
    func testFlippedOptimizedChargingKeepsTheLimitWorking() async throws {
        let f = ScopeFixture(mode: "obc"); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.canApplyTarget(95))
        try await f.service.apply(95)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 95, optimizedCharging: false))
        await f.client.setMode("")   // OBC flipped back while the limit stays
        await f.service.refresh()
        XCTAssertTrue(f.service.canApplyTarget(90))
        await f.assertWrites(["limit95"])

        let g = ScopeFixture(mode: "obc"); defer { g.cleanup() }
        try g.writeSessionJournal(phase: .indeterminate, age: 120)
        let reopened = g.makeService()
        await reopened.refresh()   // a flipped OBC is no obstacle: the clear read closes the session
        XCTAssertFalse(g.journalExists)
        await g.assertWrites([])
    }

    /// Owner decision 2026-11-06: the limit is the system's own setting. A confirmed slider choice stays after the app
    /// quits; quitting neither rewrites the previous value nor refuses to quit.
    func testAConfirmedLimitIsTheUsersOwnAndSurvivesQuitWithoutAnyWrite() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(85)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        XCTAssertFalse(f.journalExists, "No journal outlives the confirmed apply")
        let (model, suite) = f.makeModel(f.service)
        defer { model.stop(); TestDefaults.remove(suite) }
        let quit = await model.prepareForTermination()
        XCTAssertTrue(quit)
        XCTAssertEqual(f.service.observed?.configuration.target, 85)
        await f.assertWrites(["limit85"])
        let reopened = f.makeService()
        XCTAssertFalse(reopened.hasUnresolvedSession, "The next launch has nothing to review")
        await reopened.refresh()
        XCTAssertEqual(reopened.observed?.configuration.target, 85)
        XCTAssertTrue(reopened.needsApply(target: 90), "The slider keeps working from the adopted setting")
    }

    /// Owner decision 2026-11-26: the slider does what System Settings does: a level below (or equal to) the charge is
    /// written at once, and no battery reading is needed at all.
    func testALimitBelowTheChargeIsWrittenAtOnceLikeSystemSettings() async throws {
        let f = ScopeFixture(mode: "battery91"); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.apply(85)
        XCTAssertEqual(f.service.observed?.configuration.target, 85)
        XCTAssertFalse(f.journalExists, "a confirmed limit is the user's macOS setting")
        try await f.service.apply(80)
        XCTAssertEqual(f.service.reportedLimit, 80)
        await f.assertWrites(["limit85", "limit80"])
    }

    /// Owner report 2026-11-13: a waiting target (nothing written) left by an earlier build is no review state.
    func testAWaitingTargetWithNothingWrittenIsDroppedAtLaunch() async throws {
        for environment in ["scope-fixture", "an older macOS"] {
            let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
            try f.writeWaitingJournal(environment: environment)
            let reopened = f.makeService()
            XCTAssertFalse(reopened.hasUnresolvedSession, environment)
            XCTAssertFalse(f.journalExists, "\(environment): nothing was written, so there is nothing to review")
            await reopened.refresh()
            XCTAssertTrue(reopened.canApplyTarget(90), "\(environment): new limits are accepted")
            await f.assertWrites([], environment)
        }
    }

    func testApplyToLimitOffAndBackKeepsEachConfirmedChoice() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.needsApply(target: 100))
        try await f.service.apply(100)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: false, target: 100, optimizedCharging: true), "100 is stored as limit off")
        XCTAssertFalse(f.service.needsApply(target: 100), "Already off: nothing to write")
        try await f.service.apply(85)   // re-enables through the limit write itself
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        try await f.service.apply(100)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: false, target: 100, optimizedCharging: true))
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit100", "limit85", "limit100"])
    }

    func testOnBatteryPowerTheStoredSettingIsTheEvidence() async throws {
        let f = ScopeFixture(mode: "battery"); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.isAvailable, "Policy matches: no registry entry is expected on battery power")
        XCTAssertTrue(f.service.canApplyTarget(85))
        try await f.service.apply(85)
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        XCTAssertFalse(f.journalExists, "On battery power too, the confirmed limit is the user's own setting")
        await f.assertWrites(["limit85"])
    }

    /// Seen on macOS 27.2.1 (2026-11-25): a write's readback never agreed, the journal stayed unresolved and every later
    /// launch showed "unconfirmed outcome" forever. Now it is a status line, and the first settled clear read closes it,
    /// whatever it reads (the requested value, the original one, or a third), with no write.
    func testAnUnresolvedApplyJournalClosesWithoutWriteOnceAClearLimitReadsBack() async throws {
        for (label, settled) in [("requested 85", 85), ("original 90", 90), ("System Settings 95", 95)] {
            let f = ScopeFixture(); defer { f.cleanup() }
            await f.service.refresh()
            await f.client.failReadsAfterNextWrite()
            do { try await f.service.apply(85); XCTFail("\(label): unknown readback must stop") } catch {}
            XCTAssertEqual(f.service.presentation().attention, .mutationUnresolved, label)
            XCTAssertFalse(f.service.presentation().requiresGlobalAttention, "\(label): a status line, not a banner")
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
            XCTAssertEqual(saved.phase, .indeterminate, label)
            XCTAssertEqual(saved.expectedMutation?.target, 85, label)
            await f.client.clearReadFailure()
            await f.client.external(target: settled)
            let young = f.makeService()
            await young.refresh()
            XCTAssertTrue(f.journalExists, "\(label): a just-written journal is not closed at once")
            XCTAssertTrue(young.canApplyTarget(80), "\(label): it never blocks the slider")
            try f.settle()
            let reopened = f.makeService()
            await reopened.refresh()
            XCTAssertFalse(f.journalExists, label)
            XCTAssertFalse(reopened.hasUnresolvedSession, label)
            XCTAssertEqual(reopened.observed?.configuration.target, settled, label)
            await f.assertWrites(["limit85"], label)
        }
    }

    /// The one close rule (D1): a settled (60 s), clear read closes any session journal without a write, whatever it holds.
    func testSessionClosesOnTheFirstSettledClearRead() throws {
        func read(_ target: Int, enabled: Bool? = nil, registered: Int?? = .none, available: Bool = true, ac: Bool = true,
                  conflict: Bool = false, collected: Date = Date()) -> NativeChargeSnapshot {
            let on = enabled ?? (target != 100)
            let row: Int? = registered ?? (on ? target : nil)
            return .init(configuration: .init(enabled: on, target: target, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100],
                         registeredManualLimit: row, policyReadbackAvailable: available, collectedAt: collected,
                         registrationExpected: ac, registryConflict: conflict)
        }
        for target in [80, 85, 90, 100] {
            XCTAssertTrue(NativeChargeService.closesSession(value: read(target), age: 120), "AC agree at \(target)")
        }
        XCTAssertFalse(NativeChargeService.closesSession(value: read(85), age: 10), "a young journal waits")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(85), age: nil), "no file age, no close")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(90, registered: .some(nil), available: false, conflict: true), age: 120), "AC conflict")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(90, registered: .some(80), ac: false, conflict: true), age: 120), "battery conflict")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(90, available: false), age: 120), "AC without a policy readback")
        XCTAssertTrue(NativeChargeService.closesSession(value: read(85, registered: .some(nil), ac: false), age: 120), "battery: no row")
        XCTAssertTrue(NativeChargeService.closesSession(value: read(85, registered: .some(90), ac: false), age: 120), "battery: a stale 90 row")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(85, collected: Date().addingTimeInterval(-100)), age: 120), "stale read")
        XCTAssertFalse(NativeChargeService.closesSession(value: read(80, enabled: false, registered: .some(nil)), age: 120), "disabled+80 is not a valid state")
        let old = Data(#"{"configuration":{"enabled":true,"target":90,"optimizedCharging":true},"supportedTargets":[90],"registeredManualLimit":90,"policyReadbackAvailable":true,"collectedAt":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NativeChargeSnapshot.self, from: old).registryConflict, false)
    }

    /// A conflict keeps the session (status line only) and the slider; a third value set in System Settings closes it.
    func testUnresolvedJournalStaysWhileTheRegistryConflicts() async throws {
        let f = ScopeFixture(mode: "conflict"); defer { f.cleanup() }
        try f.writeSessionJournal(phase: .indeterminate, qualification: true, expected: 80, age: 120)
        let conflicted = f.makeService()
        await conflicted.refresh()
        XCTAssertTrue(f.journalExists)
        XCTAssertEqual(conflicted.presentation().attention, .mutationUnresolved)
        XCTAssertTrue(conflicted.canApplyTarget(85), "an unresolved session never blocks the slider")
        XCTAssertEqual(conflicted.nativeSetting?.registryConflict, true)
        XCTAssertEqual(conflicted.message, NativeChargeService.registryConflictMessage)
        XCTAssertEqual(NativeChargeStatusText.text(conflicted.presentation(), NativeChargeStatusText.inputs(conflicted)),
                       NativeChargeService.registryConflictMessage)
        await f.client.setMode("")
        await f.client.external(target: 85)   // neither before, confirmed nor requested: still the user's own clear setting
        await conflicted.refresh()
        XCTAssertFalse(f.journalExists)
        XCTAssertFalse(conflicted.hasUnresolvedSession)
        XCTAssertEqual(conflicted.presentation().attention, .none)
        await f.assertWrites([])
    }

    /// Leftovers of every phase and origin earlier builds wrote load without blocking anything and close at the first
    /// settled clear read with no write; a journal that never dispatched a write is deleted at launch.
    func testLeftoverSessionsOfEveryPhaseAndOriginCloseWithoutAWrite() async throws {
        let phases: [(NativeChargeJournal.Phase, Int?)] = [(.owned, nil), (.preparing, 85), (.restorationPending, nil), (.restoring, 90),
                                                            (.indeterminate, 85), (.pendingTarget, 80)]
        for (phase, expected) in phases {
            for qualification in [true, false, nil] as [Bool?] {
                let label = "\(phase) \(String(describing: qualification))"
                let f = ScopeFixture(); defer { f.cleanup() }
                try f.writeSessionJournal(phase: phase, qualification: qualification, expected: expected)
                let reopened = f.makeService()
                XCTAssertTrue(reopened.hasUnresolvedSession, label)
                XCTAssertEqual(reopened.presentation().attention, .mutationUnresolved, label)
                await reopened.refresh()
                XCTAssertTrue(f.journalExists, "\(label): young")
                XCTAssertTrue(reopened.offersTarget(85), label)
                XCTAssertTrue(reopened.canApplyTarget(85), label)
                try f.settle()
                await reopened.refresh()
                XCTAssertFalse(f.journalExists, label)
                XCTAssertFalse(reopened.hasUnresolvedSession, label)
                await f.assertWrites([], label)

                let g = ScopeFixture(); defer { g.cleanup() }
                try g.writeSessionJournal(phase: phase, hasWritten: false, qualification: qualification, expected: expected)
                let fresh = g.makeService()
                XCTAssertFalse(g.journalExists, "\(label): nothing was dispatched, nothing to review")
                XCTAssertFalse(fresh.hasUnresolvedSession, label)
            }
        }
    }

    func testOnBatteryALeftoverClosesButConflictingRowsWait() async throws {
        let f = ScopeFixture(mode: "battery"); defer { f.cleanup() }
        try f.writeSessionJournal(phase: .indeterminate, age: 120)
        let unplugged = f.makeService()
        await unplugged.refresh()
        XCTAssertFalse(f.journalExists, "the stored setting is the evidence on battery power")
        let g = ScopeFixture(mode: "batteryConflict"); defer { g.cleanup() }
        try g.writeSessionJournal(phase: .indeterminate, age: 120)
        let conflicted = g.makeService()
        await conflicted.refresh()
        XCTAssertTrue(g.journalExists, "two different rows wait until they age out")
        XCTAssertTrue(conflicted.canApplyTarget(85))
        await f.assertWrites([]); await g.assertWrites([])
    }

    /// A macOS update that changes the offered list is no reason to keep a session: it closes, and the slider writes.
    func testAChangedOfferedListClosesTheSessionAndTheSliderKeepsWorking() async throws {
        let f = ScopeFixture(mode: "offeredAll"); defer { f.cleanup() }
        try f.writeSessionJournal(phase: .indeterminate, age: 120)
        let service = f.makeService()
        await service.refresh()
        XCTAssertFalse(f.journalExists)
        await f.client.external(target: 85)
        await service.refresh()
        try await service.apply(90)
        XCTAssertEqual(service.reportedLimit, 90)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit90"])
    }

    /// Owner decision 2026-11-26: the limit works at once, at any charge, after every macOS update: the live interface
    /// grants it (no validation run, no proof file), and every write is still read back.
    func testLiveInterfaceGrantsTheLimitWithoutValidationAtAnyCharge() async throws {
        let f = ScopeFixture(mode: "battery89"); defer { f.cleanup() }
        let service = f.makeService()
        XCTAssertTrue(service.notReadYet, "nothing flashes before the first read")
        XCTAssertFalse(service.admitted)
        await service.refresh()
        XCTAssertTrue(service.admitted)
        XCTAssertFalse(service.notReadYet)
        XCTAssertEqual(service.authorizedPersistentTargets, NativeChargeAdmission.persistentTargets)
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95)    // above the charge: written and read back
        XCTAssertEqual(service.observed?.configuration.target, 95)
        try await service.apply(100)   // limit off
        XCTAssertEqual(service.observed?.configuration.enabled, false)
        try await service.apply(85)    // below the charge: written at once, as System Settings does
        XCTAssertEqual(service.observed?.configuration.target, 85)
        await f.assertWrites(["limit95", "limit100", "limit85"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("admission.json").path), "no proof file is invented")
    }

    func testOnBatteryJustAfterUnpluggingTheStaleRegistryRowsDoNotBlockAWrite() async throws {
        let f = ScopeFixture(mode: "batteryStaleRows"); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95)
        XCTAssertEqual(service.observed?.configuration.target, 95)
        XCTAssertFalse(f.journalExists, "the stored setting is the evidence on battery power, not the stale rows")
        try await service.apply(100)
        XCTAssertEqual(service.observed?.configuration.enabled, false)
        await f.assertWrites(["limit95", "limit100"])
    }

    func testOnBatteryConflictingStaleRowsAreNotEvidenceAndOnACTheSliderStillWrites() async throws {
        let f = ScopeFixture(mode: "batteryConflict"); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95)
        XCTAssertEqual(service.observed?.configuration.target, 95)
        XCTAssertFalse(f.journalExists)
        await f.client.setMode("conflict")   // on AC two different rows: the hint shows, the slider still writes
        await service.refresh()
        XCTAssertEqual(service.message, NativeChargeService.registryConflictMessage)
        XCTAssertTrue(service.canApplyTarget(90), "the write is what clears a two-row conflict; the readback decides")
        XCTAssertEqual(service.reportedLimit, 95, "what macOS stores is shown")
        do { try await service.apply(90); XCTFail("a conflict that stays is not confirmed") } catch {}
        XCTAssertTrue(f.journalExists, "an unconfirmed write leaves a session that closes itself")
        XCTAssertTrue(service.canApplyTarget(85))
        await f.assertWrites(["limit95", "limit90"])
    }

    /// A macOS update changes only the middle of "model / OS / contract": a session journal stays readable.
    func testSessionJournalSurvivesAMacOSUpdateButNotAnotherMac() async throws {
        let contract = NativeChargeAdmission.semanticContract
        let before = "Mac17,3 / Version 27.2 (Build 26B123) / \(contract)", after = "Mac17,3 / Version 27.2.1 (Build 26B131) / \(contract)"
        XCTAssertTrue(NativeChargeAdmission.sameMachine(before, after))
        XCTAssertFalse(NativeChargeAdmission.sameMachine(before, "Mac16,1 / Version 27.2.1 (Build 26B131) / \(contract)"))
        XCTAssertFalse(NativeChargeAdmission.sameMachine(before, "Mac17,3 / Version 27.2.1 (Build 26B131) / PowerUI-v3"))
        XCTAssertFalse(NativeChargeAdmission.sameMachine("scope-fixture", "other-fixture"))
        let f = ScopeFixture(); defer { f.cleanup() }
        let bytes = try f.writeSessionJournal(phase: .indeterminate, environment: before)
        let moved = try JSONDecoder().decode(NativeChargeJournal.self, from: bytes)
        XCTAssertTrue(moved.hasPersistentScope(environment: after))
        XCTAssertFalse(moved.hasPersistentScope(environment: "Mac16,1 / Version 27.2.1 (Build 26B131) / \(contract)"))
    }

    /// An earlier build still decodes a journal this build writes (its decoder requires the one-shot key).
    func testAJournalThisBuildWritesKeepsTheKeysEarlierBuildsRequire() async throws {
        let f = ScopeFixture(mode: "conflict"); defer { f.cleanup() }
        await f.service.refresh()
        do { try await f.service.apply(85); XCTFail("unconfirmed") } catch {}
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        for key in ["version", "sessionID", "environment", "baseline", "lastVerified", "phase", "hasWritten", "oneShot"] {
            XCTAssertNotNil(json[key], key)
        }
        XCTAssertEqual(json["oneShot"] as? Bool, false)
        XCTAssertEqual(json["version"] as? Int, 2)
        await f.assertWrites(["limit85"])
    }

    func testLiveInterfaceGrantsNothingWhenATargetIsMissingOrMonitoringOnly() async throws {
        let f = ScopeFixture(mode: "offered"); defer { f.cleanup() }   // macOS offers no 95
        let partial = f.makeService()
        await partial.refresh()
        XCTAssertFalse(partial.admitted)
        XCTAssertFalse(partial.canApplyTarget(90))
        let g = ScopeFixture(); defer { g.cleanup() }
        let monitor = g.makeService(monitoringOnly: true)
        await monitor.refresh()
        XCTAssertFalse(monitor.admitted)
        XCTAssertFalse(monitor.notReadYet, "monitoring still reads and shows the setting")
        await f.assertWrites([]); await g.assertWrites([])
    }

    /// An unusable session file (v1, garbage, another contract, another Mac) is never acted on and never blocks: it stays
    /// in place until a settled clear read, then is set aside under a new name with its bytes and 0600 mode.
    func testProductionScopeSetsAsideUnreadableJournal() async throws {
        let legacy = NativeChargeJournal(sessionID: UUID(), environment: "scope-fixture", baseline: .init(enabled: true, target: 80, optimizedCharging: true), lastVerified: .init(enabled: true, target: 95, optimizedCharging: true), plannedTarget: nil, phase: .owned, hasWritten: true)
        for label in ["v1", "garbage", "contract", "otherMac"] {
            let f = ScopeFixture(); defer { f.cleanup() }
            let bytes: Data
            switch label {
            case "v1": try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true); bytes = try JSONEncoder().encode(legacy); try bytes.write(to: f.journal)
            case "garbage": try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true); bytes = Data("x".utf8); try bytes.write(to: f.journal)
            case "contract": bytes = try f.writeSessionJournal(phase: .indeterminate, contract: "PowerUI-v3-old")
            default: bytes = try f.writeSessionJournal(phase: .indeterminate, environment: "another-mac")
            }
            let service = f.makeService()
            XCTAssertTrue(service.unreadableJournal, label)
            XCTAssertTrue(service.hasUnresolvedSession, label)
            await service.refresh()
            XCTAssertEqual(try Data(contentsOf: f.journal), bytes, "\(label): untouched before a settled clear read")
            XCTAssertTrue(service.canApplyTarget(85), "\(label): never blocks")
            try f.settle()
            await service.refresh()
            XCTAssertFalse(f.journalExists, label)
            XCTAssertFalse(service.unreadableJournal, label)
            let aside = try f.setAside()
            XCTAssertEqual(aside.count, 1, label)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(aside.first)), bytes, label)
            let mode = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(aside.first).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, label)
            XCTAssertTrue(service.canApplyTarget(85), label)
            await f.assertWrites([], label)
        }
    }

    /// The next apply supersedes an unusable file too: it is set aside (never deleted) and the write goes ahead.
    func testApplySetsAsideAnUnreadableJournalAndWrites() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.journal)
        let service = f.makeService()
        await service.refresh()   // young: stays
        XCTAssertTrue(service.unreadableJournal)
        try await service.apply(85)
        XCTAssertFalse(service.unreadableJournal)
        XCTAssertEqual(try f.setAside().count, 1)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit85"])
    }

    // MARK: The one apply path

    func testAFailedFirstReadAfterTheWriteIsRetriedAndTheNextConfirms() async throws {
        let f = ScopeFixture(mode: "failFirstReadAfterWrite"); defer { f.cleanup() }
        let service = f.makeService(verificationAttempts: 2)
        await service.refresh()
        try await service.apply(85)
        XCTAssertEqual(service.reportedLimit, 85)
        XCTAssertFalse(f.journalExists, "confirmed: the user's own setting, no journal left")
        XCTAssertFalse(service.hasUnresolvedSession)
        await f.assertWrites(["limit85"])
    }

    func testAnACRegistryConflictWritesOnceAndTheReadbackDecides() async throws {
        // The write rewrites both rows: confirmed, nothing left.
        let f = ScopeFixture(mode: "conflictUntilWrite"); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        XCTAssertNil(service.presentation().activePolicy, "a conflict is not a confirmed policy")
        XCTAssertEqual(service.reportedLimit, 90, "but what macOS stores is shown")
        XCTAssertTrue(service.canApplyTarget(85))
        try await service.apply(85)
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(service.presentation().activePolicy?.target, 85)
        await f.assertWrites(["limit85"])

        // The conflict stays: an indeterminate session that blocks nothing and closes itself later with no extra write.
        let g = ScopeFixture(mode: "conflict"); defer { g.cleanup() }
        let stuck = g.makeService()
        await stuck.refresh()
        do { try await stuck.apply(85); XCTFail("not confirmed while two rows differ") }
        catch NativeChargeServiceError.readbackMismatch {} catch { XCTFail("Wrong error: \(error)") }
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: g.journal))
        XCTAssertEqual(saved.phase, .indeterminate)
        XCTAssertTrue(stuck.canApplyTarget(90))
        await g.client.setMode("")
        try g.settle()
        await stuck.refresh()
        XCTAssertFalse(g.journalExists)
        await g.assertWrites(["limit85"])
    }

    func testASingleStaleACRowDoesNotStopAWrite() async throws {
        let f = ScopeFixture(mode: "staleRow"); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95)
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(service.presentation().activePolicy?.target, 95)
        await f.assertWrites(["limit95"])
    }

    func testAnInSessionLeftoverAndAnExternalChangeNeverFailTheNextApply() async throws {
        let f = ScopeFixture(mode: "conflict"); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        do { try await service.apply(85); XCTFail("unconfirmed") } catch {}
        XCTAssertTrue(service.hasUnresolvedSession)
        await f.client.setMode("")
        await f.client.external(target: 80)   // System Settings
        try await service.apply(95)
        XCTAssertEqual(service.reportedLimit, 95)
        XCTAssertFalse(f.journalExists)
        XCTAssertFalse(service.hasUnresolvedSession)
        await f.assertWrites(["limit85", "limit95"])
    }

    func testAnExpectedCurrentMismatchWritesNothing() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        do { try await service.apply(100, expectedCurrent: 80); XCTFail("changed elsewhere") }
        catch NativeChargeServiceError.changedElsewhere {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(NativeChargeServiceError.changedElsewhere.localizedDescription, "The charge limit was changed in System Settings. Nothing was written.")
        try await service.apply(100, expectedCurrent: 90)
        await f.assertWrites(["limit100"])
    }

    func testMonitoringOnlyNeverWrites() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let monitor = f.makeService(monitoringOnly: true)
        await monitor.refresh()
        do { try await monitor.apply(85); XCTFail("monitoring never writes") } catch {}
        XCTAssertFalse(monitor.canApply)
        await f.assertWrites([])
    }

    /// A journal save failure before the dispatch writes nothing and leaves nothing behind (no review, slider usable).
    func testAWriteAheadFailureBeforeDispatchLeavesNothingBehind() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService()
        await service.refresh()
        try FileManager.default.createDirectory(at: f.journal, withIntermediateDirectories: true)   // the journal path is blocked
        do { try await service.apply(85); XCTFail("the journal must be saved first") } catch {}
        await f.assertWrites([])
        XCTAssertNotEqual(service.presentation().attention, .journalIntegrity)
        XCTAssertFalse(f.journalExists, "nothing is left on disk")
        try? FileManager.default.removeItem(at: f.journal)
        await service.refresh()
        try await service.apply(85)
        await f.assertWrites(["limit85"])
    }
}

@MainActor struct ScopeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroScope-\(UUID())")
    let client: ScopeTransport
    let service: NativeChargeService
    var journal: URL { root.appendingPathComponent("session.json") }
    init(mode: String = "", initialTarget: Int = 90) {
        let transport = ScopeTransport(mode: mode, initialTarget: initialTarget); client = transport
        service = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("session.json"), verificationAttempts: 1,
                                      environment: "scope-fixture")
    }
    func makeService(monitoringOnly: Bool = false, verificationAttempts: Int = 1, operationTimeout: Duration = .seconds(15)) -> NativeChargeService {
        NativeChargeService(client: client, journalURL: journal, monitoringOnly: monitoringOnly,
                            verificationAttempts: verificationAttempts, environment: "scope-fixture", operationTimeout: operationTimeout)
    }
    /// A session (v2) journal as `makeScopedJournal` writes it: baseline 90, requested 85.
    @discardableResult
    func writeSessionJournal(phase: NativeChargeJournal.Phase, hasWritten: Bool = true, qualification: Bool? = false,
                             expected: Int? = 85, lastVerified: Int = 90, environment: String = "scope-fixture",
                             contract: String = NativeChargeAdmission.semanticContract, age: TimeInterval = 0) throws -> Data {
        let baseline = NativeChargeConfiguration(enabled: true, target: 90, optimizedCharging: true)
        var saved = NativeChargeJournal(sessionID: UUID(), environment: environment, baseline: baseline,
            lastVerified: .init(enabled: lastVerified != 100, target: lastVerified, optimizedCharging: true), plannedTarget: expected, phase: phase)
        saved.version = 2; saved.semanticContract = contract; saved.persistentTargets = NativeChargeAdmission.persistentTargets
        saved.baselineSnapshot = .init(configuration: baseline, supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 90)
        saved.hasWritten = hasWritten; saved.qualification = qualification
        saved.expectedMutation = expected.map { .init(enabled: $0 != 100, target: $0, optimizedCharging: true) }
        let bytes = try JSONEncoder().encode(saved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        if age != 0 { try settle(age) }
        return bytes
    }
    /// Ages the session file (the close rule waits until it is at least 60 s old).
    func settle(_ age: TimeInterval = 120) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: journal.path)
    }
    var journalExists: Bool { FileManager.default.fileExists(atPath: journal.path) }
    /// A real model around `service` (the caller removes the preference suite and stops the model).
    func makeModel(_ service: NativeChargeService, percent: Int? = nil, charging: Bool? = nil, externalPower: Bool? = nil) -> (TilveroModel, String) {
        makeModel(service, snapshot: { ScopeFixture.snapshot(percent: percent, charging: charging, externalPower: externalPower) })
    }
    func makeModel(_ service: NativeChargeService, configure: (UserDefaults) -> Void = { _ in },
                   snapshot: @escaping @Sendable () async -> BatterySnapshot) -> (TilveroModel, String) {
        let suite = TestDefaults.name("ScopeModel")
        let preferences = TestDefaults.defaults(suite)
        preferences.set(false, forKey: "historyEnabled")
        configure(preferences)
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: [:]), preferences: preferences,
            historyURL: root.appendingPathComponent("model.sqlite"), snapshotProvider: snapshot, nativeCharge: service)
        return (model, suite)
    }
    nonisolated static func snapshot(percent: Int?, charging: Bool?, externalPower: Bool?) -> BatterySnapshot {
        guard percent != nil || charging != nil || externalPower != nil else { return .unavailable(reason: "Scope fixture") }
        let reason = "Scope fixture"
        return BatterySnapshot(chargePercent: percent.map { .init(value: $0, source: "fixture", freshness: .fresh) } ?? .unavailable(reason: reason),
                               isCharging: charging.map { .init(value: $0, source: "fixture", freshness: .fresh) } ?? .unavailable(reason: reason),
                               isExternalPower: externalPower.map { .init(value: $0, source: "fixture", freshness: .fresh) } ?? .unavailable(reason: reason))
    }
    /// Files set aside as `session.invalid-*.json`.
    func setAside() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session.invalid-") && $0.pathExtension == "json" }
    }
    func assertWrites(_ expected: [String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let writes = await client.writes
        XCTAssertEqual(writes, expected, message, file: file, line: line)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    /// A v2 waiting target with nothing written, as builds before 0.8.2 left it (a limit below the charge level).
    func writeWaitingJournal(environment: String) throws {
        let config = NativeChargeConfiguration(enabled: true, target: 85, optimizedCharging: true)
        var saved = NativeChargeJournal(sessionID: UUID(), environment: environment, baseline: config, lastVerified: config,
                                        plannedTarget: 80, phase: .pendingTarget)
        saved.version = 2
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: journal)
    }
}

actor ScopeTransport: NativeChargeTransport {
    var writes: [String] = []
    private var mode: String
    private var target: Int
    init(mode: String, initialTarget: Int = 90) { self.mode = mode; target = initialTarget }
    func setMode(_ value: String) { mode = value }
    private var failAfterWrites: Int?
    func failReadsAfterNextWrite() { failAfterWrites = writes.count }
    func clearReadFailure() { failAfterWrites = nil }
    func external(target value: Int) { target = value }
    private var failedReadAfterWrite = false
    /// A write held inside the transport until `releaseWrite()` (a quit in the middle of a write).
    private var holdNextWrite = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    var isHoldingWrite: Bool { heldWrite != nil }
    func holdWrites() { holdNextWrite = true }
    func releaseWrite() { heldWrite?.resume(); heldWrite = nil }
    func read() throws -> NativeChargeSnapshot {
        if mode == "unknown" || failAfterWrites.map({ writes.count > $0 }) == true {
            throw NativeChargeReadFailure(supportedTargets: [80,85,90,95,100], currentTarget: 100, rawManualState: 3, diagnosticStoredTarget: 90)!
        }
        // "failFirstReadAfterWrite": the first read after a write fails once (an unrecognized state), the next one is clean.
        if mode == "failFirstReadAfterWrite", !writes.isEmpty, !failedReadAfterWrite {
            failedReadAfterWrite = true
            throw NativeChargeReadFailure(supportedTargets: [80,85,90,95,100], currentTarget: target, rawManualState: 3)!
        }
        // "conflictUntilWrite": the two-row AC registry after a macOS update; a write rewrites both rows.
        // "staleRow": one AC row with an old 80 until a write. "offeredAll": macOS offers every level 80…100.
        let conflicted = mode == "conflict" || mode == "batteryConflict" || (mode == "conflictUntilWrite" && writes.isEmpty)
        if mode == "staleRow" && writes.isEmpty {
            return .init(configuration: .init(enabled: target != 100, target: target, optimizedCharging: true),
                         supportedTargets: [80,85,90,95,100], registeredManualLimit: 80)
        }
        if conflicted && mode == "conflictUntilWrite" {
            return .init(configuration: .init(enabled: target != 100, target: target, optimizedCharging: true), supportedTargets: [80,85,90,95,100],
                         registeredManualLimit: nil, policyReadbackAvailable: false, registryConflict: true)
        }
        let target = mode == "baseline100" ? 100 : target
        // macOS stores 100 as "limit off": disabled, no registered manual limit (mode "baseline100" is an inconsistent enabled 100).
        let battery = mode == "battery" || mode == "batteryStaleRows" || mode == "batteryConflict"   // on battery power: the setting is stored, nothing is registered
        let off = target == 100 && mode != "baseline100"
        return .init(configuration: .init(enabled: mode != "disabled" && !off, target: target, optimizedCharging: mode != "obc"),
              supportedTargets: mode == "offered" ? [80,85,90,100] : mode == "offeredAll" ? Array(80...100) : [80,85,90,95,100],
              // "batteryStaleRows": just unplugged, macOS still lists the old 90 rows for a few minutes.
              registeredManualLimit: mode == "batteryStaleRows" ? 90 : mode == "disabled" || off || battery ? nil : target,
              policyReadbackAvailable: mode != "conflict" && mode != "batteryConflict",
              collectedAt: mode == "stale" ? Date().addingTimeInterval(-100) : Date(), registrationExpected: !battery,
              registryConflict: mode == "conflict" || mode == "batteryConflict")
    }
    func setLimit(_ target: Int) async {
        writes.append("limit\(target)")
        if holdNextWrite { holdNextWrite = false; await withCheckedContinuation { heldWrite = $0 } }
        self.target = target
    }
    func setEnabled(_ enabled: Bool) { writes.append(enabled ? "enable" : "disable") }
}
