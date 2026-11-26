// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

@MainActor final class NativeChargeScopeTests: XCTestCase {
    func testModePreviewDoesNotOfferTargetsOutsideVerifiedScope() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.qualify()
        let suite = TestDefaults.name("ScopeModePreview")
        let preferences = TestDefaults.defaults(suite)
        preferences.set(false, forKey: "historyEnabled")
        defer { TestDefaults.remove(suite) }
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: [:]), preferences: preferences,
            historyURL: f.root.appendingPathComponent("preview.sqlite"),
            snapshotProvider: { .unavailable(reason: "Scoped mode preview fixture") }, nativeCharge: f.service)
        defer { model.stop() }
        for target in [80, 85, 95, 100] {
            let allowed = ModePlan(mode: .economy, chargeTarget: target, lowPower: false, displayIdleMinutes: nil, brightnessPercent: nil)
            XCTAssertEqual(model.modePreview(allowed).first { $0.action == .charge }?.status, .available, "\(target)")
        }
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
    }

    func testSuccessfulQualificationPreservesExactHistoricalProofBeforeReplacingIt() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let old = Data([0, 255, 123, 34, 118, 49, 34, 125, 10])
        try old.write(to: f.admission)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: f.admission.path)
        try await f.service.qualify()
        XCTAssertTrue(NativeChargeAdmission.load(from: f.admission, environment: "scope-fixture"))
        let receipts = try FileManager.default.contentsOfDirectory(at: f.proofHistory, includingPropertiesForKeys: nil)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(receipts.first)), old)
        let historyMode = try FileManager.default.attributesOfItem(atPath: f.proofHistory.path)[.posixPermissions] as? NSNumber
        let archiveMode = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(receipts.first).path)[.posixPermissions] as? NSNumber
        let liveMode = try FileManager.default.attributesOfItem(atPath: f.admission.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(historyMode?.intValue, 0o700)
        XCTAssertEqual(archiveMode?.intValue, 0o600)
        XCTAssertEqual(liveMode?.intValue, 0o400, "Publishing must not broaden the old proof's mode")
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
    }

    func testProofArchiveFailurePreservesOldLiveBytesAndDoesNotClaimNewAdmission() async throws {
        for obstruction in ["file", "hardlinkedFile", "symlink", "nonprivateDirectory"] {
            let f = ScopeFixture(); defer { f.cleanup() }
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
            let old = Data("untouched historical v1".utf8); try old.write(to: f.admission)
            if obstruction == "file" { try Data("occupied".utf8).write(to: f.proofHistory) }
            else if obstruction == "hardlinkedFile" {
                let foreign = f.root.appendingPathComponent("foreign-history-file")
                try Data("foreign history must survive".utf8).write(to: foreign)
                try FileManager.default.linkItem(at: foreign, to: f.proofHistory)
            } else if obstruction == "symlink" {
                let destination = f.root.appendingPathComponent("foreign-history")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: f.proofHistory, withDestinationURL: destination)
            } else {
                try FileManager.default.createDirectory(at: f.proofHistory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
            do { try await f.service.qualify(); XCTFail("Archive obstruction must stop proof publication: \(obstruction)") } catch {}
            XCTAssertEqual(try Data(contentsOf: f.admission), old, obstruction)
            XCTAssertFalse(f.service.admitted, obstruction)
            XCTAssertTrue(f.service.authorizedPersistentTargets.isEmpty, obstruction)
            XCTAssertFalse(f.service.hasOwnedSettings, "The physical fixture baseline was already restored")
            XCTAssertEqual(f.service.observed?.configuration.target, 90)
            XCTAssertNotNil(f.service.message)
            await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"], obstruction)
        }
    }

    func testLinkedOrNonregularLiveProofCannotBeReplacedOrArchived() async throws {
        for node in ["symlink", "hardlink", "directory"] {
            let f = ScopeFixture(); defer { f.cleanup() }
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
            let foreign = f.root.appendingPathComponent("foreign-proof.json")
            let old = Data("foreign historical proof".utf8); try old.write(to: foreign)
            if node == "symlink" { try FileManager.default.createSymbolicLink(at: f.admission, withDestinationURL: foreign) }
            else if node == "hardlink" { try FileManager.default.linkItem(at: foreign, to: f.admission) }
            else { try FileManager.default.createDirectory(at: f.admission, withIntermediateDirectories: true) }
            let attributes = try FileManager.default.attributesOfItem(atPath: f.admission.path)
            do { try await f.service.qualify(); XCTFail("Unsafe historical proof node must remain untouched: \(node)") } catch {}
            XCTAssertEqual(try Data(contentsOf: foreign), old)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.admission.path)[.type] as? FileAttributeType, attributes[.type] as? FileAttributeType)
            XCTAssertFalse(f.service.admitted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.proofHistory.path))
            await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
        }
    }

    func testProofHistoryIsNeverCreatedByConstructionReadsOrFailedPreflight() async throws {
        let f = ScopeFixture(mode: "battery89"); defer { f.cleanup() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        await f.service.refresh()
        do { try await f.service.qualify(); XCTFail("Unsafe battery") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.proofHistory.path))
        await f.assertWrites([])
    }

    func testQualificationUsesOnlyThePersistentTargetsAndLoadsExactScope() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        XCTAssertFalse(f.service.admitted)
        XCTAssertTrue(f.service.authorizedPersistentTargets.isEmpty)
        await f.service.refresh()
        XCTAssertTrue(f.service.canRequestQualification)
        try await f.service.qualify()
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
        XCTAssertTrue(f.service.admitted)
        XCTAssertEqual(f.service.authorizedPersistentTargets, [80, 85, 90, 95, 100])
        XCTAssertTrue(f.service.canApplyTarget(95))
        XCTAssertTrue(f.service.canApplyTarget(80))
        XCTAssertTrue(f.service.canApplyTarget(85))
        XCTAssertTrue(f.service.canApplyTarget(100), "100 is the verified limit-off state")
        XCTAssertFalse(f.service.hasOwnedSettings)
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let reopened = f.makeService(scope: scope)
        await reopened.refresh()
        XCTAssertEqual(reopened.authorizedPersistentTargets, [80, 85, 90, 95, 100])
        for target in [75, 99] {
            do { try await reopened.apply(target, batteryPercent: 50, batteryFresh: true); XCTFail("Unqualified target \(target)") }
            catch NativeChargeServiceError.unqualifiedTarget {} catch NativeChargeServiceError.unsupportedTarget {} catch { XCTFail("Wrong error: \(error)") }
        }
        do { try await reopened.chargeToFullOnce(batteryPercent: 50, batteryFresh: true); XCTFail("No full once capability") } catch {}
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
    }

    func testQualificationPreflightRejectsUnknownDisabledWrongBaselineAndUnsafeBatteryWithoutFilesOrWrites() async throws {
        for mode in ["unknown", "disabled", "baseline100", "policy", "offered", "stale", "battery80", "battery89", "battery100", "batteryStale", "batteryMissing"] {
            let f = ScopeFixture(mode: mode); defer { f.cleanup() }
            await f.service.refresh()
            do { try await f.service.qualify(); XCTFail("Must reject \(mode)") } catch {}
            XCTAssertFalse(f.service.admitted, mode)
            XCTAssertTrue(f.service.authorizedPersistentTargets.isEmpty, mode)
            await f.assertWrites([], mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path), mode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path), mode)
        }
    }

    func testUnknownPost95KeepsWriteAheadJournalAndOldProofWithoutGuessingRollback() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let old = Data("historical-v1-proof".utf8); try old.write(to: f.admission)
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        await f.assertWrites(["limit80"])
        XCTAssertTrue(f.service.recoveryRequired)
        XCTAssertFalse(f.service.admitted)
        XCTAssertEqual(try Data(contentsOf: f.admission), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.proofHistory.path))
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.expectedMutation?.target, 80)
        XCTAssertTrue(saved.hasWritten)
        _ = try? await f.service.restore(batteryPercent: 50, batteryFresh: true)
        await f.assertWrites(["limit80"])
    }

    func testInterruptedScopedJournalCanOnlyRecoverWithoutProof() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Expected interrupted qualification") } catch {}
        await f.client.setMode("")
        let reopened = f.makeService()
        await reopened.refresh()
        XCTAssertFalse(reopened.admitted)
        XCTAssertTrue(reopened.authorizedPersistentTargets.isEmpty)
        XCTAssertFalse(reopened.canApplyTarget(90))
        do { try await reopened.apply(90, batteryPercent: 50, batteryFresh: true); XCTFail("Recovery is not normal admission") } catch {}
        // Nothing is owed to the baseline: Restore (and Quit) write nothing and never refuse.
        let restored = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored)
        XCTAssertTrue(f.journalExists, "a young journal stays until a settled clear read")
        try f.settle()
        await reopened.refresh()
        XCTAssertFalse(f.journalExists, "the first settled clear read closes it")
        XCTAssertFalse(reopened.hasUnresolvedSession)
        await f.assertWrites(["limit80"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path))
    }

    func testScopedRestoreCannotWriteFromDisabledOrOutOfPairState() async throws {
        for mode in ["disabled", "baseline100", "baseline85", "unknown"] {
            let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
            do { try await f.service.qualify(); XCTFail("Expected interruption") } catch {}
            let bytes = try Data(contentsOf: f.journal)
            await f.client.setMode(mode)
            let reopened = f.makeService()
            _ = try? await reopened.restore(batteryPercent: 50, batteryFresh: true)
            await f.assertWrites(["limit80"], mode)
            XCTAssertEqual(try Data(contentsOf: f.journal), bytes, mode)
        }
    }

    func testSchema2RejectsLegacyMalformedEnvironmentScopePolicyOBCAndChronology() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let valid = try Data(contentsOf: f.admission)
        XCTAssertFalse(NativeChargeAdmission.load(from: f.admission, environment: "changed-env"))
        for change in ["version", "semantic", "scope", "empty", "disabled", "policy", "obc", "chronology", "before", "offered", "stageOrder", "stageMissing"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            switch change {
            case "version": json["version"] = 1
            case "semantic": json["semanticContract"] = "PowerUI-v1-fixed-ABI"
            case "scope": json["authorizedPersistentTargets"] = [80, 85, 90, 95]
            case "empty": json["authorizedPersistentTargets"] = []
            case "disabled", "obc":
                var stages = json["stages"] as! [[String: Any]]
                var config = stages[0]["configuration"] as! [String: Any]
                config[change == "disabled" ? "enabled" : "optimizedCharging"] = false
                stages[0]["configuration"] = config; json["stages"] = stages
            case "policy":
                var stages = json["stages"] as! [[String: Any]]; stages[0]["registeredManualLimit"] = 90; json["stages"] = stages
            case "chronology": json["completedAt"] = 0
            case "before": json.removeValue(forKey: "before")
            case "stageOrder": json["stages"] = (json["stages"] as! [[String: Any]]).reversed() as [[String: Any]]
            case "stageMissing": json["stages"] = Array((json["stages"] as! [[String: Any]]).dropFirst())
            default: json["offeredTargets"] = [95, 90]
            }
            try JSONSerialization.data(withJSONObject: json).write(to: f.admission)
            XCTAssertNil(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"), change)
        }
    }

    /// Optimized Battery Charging is its own macOS setting: flipping it (System Settings or Tilvero's own switch) never
    /// locks the limit slider or blocks a restore of the limit.
    func testFlippedOptimizedChargingKeepsTheLimitWorkingAndRestorable() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        await f.client.setMode("obc")
        let service = f.makeService(scope: scope)
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95, batteryPercent: 50, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration, .init(enabled: true, target: 95, optimizedCharging: false))
        XCTAssertFalse(service.recoveryRequired)
        await f.client.setMode("")   // OBC flipped back while the limit stays
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(90))
        XCTAssertFalse(service.recoveryRequired)

        let g = ScopeFixture(mode: "postUnknown"); defer { g.cleanup() }
        do { try await g.service.qualify(); XCTFail("Expected interruption") } catch {}
        await g.client.setMode("obc")
        let reopened = g.makeService()
        let restored = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored, "nothing is owed: no write, no refusal")
        try g.settle()
        await reopened.refresh()   // a flipped OBC is no obstacle: the clear read closes the session
        await g.assertWrites(["limit80"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.journal.path))
    }

    func testScopedAdmissionDoesNotOwnAnUnverifiedBaseline() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        for mode in ["disabled", "baseline100", "unknown"] {   // 85 is a verified persistent target now
            await f.client.setMode(mode)
            let scoped = f.makeService(scope: scope)
            await scoped.refresh()
            do { try await scoped.apply(95, batteryPercent: 50, batteryFresh: true); XCTFail("Unverified baseline: \(mode)") } catch {}
            XCTAssertFalse(scoped.hasOwnedSettings)
            await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
        }
    }

    func testQualificationRechecksDedicatedBatteryAndPersistentStateAtDispatch() async throws {
        for mode in ["risingBefore95", "externalBefore95", "unknownBefore95"] {
            let f = ScopeFixture(mode: mode); defer { f.cleanup() }
            do { try await f.service.qualify(); XCTFail("Prewrite recheck must stop \(mode)") } catch {}
            await f.assertWrites([], mode)
            XCTAssertFalse(f.service.admitted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path))
        }
    }

    func testUnknownAfterRestorationWritePreservesExpected90InsteadOfReclassifying95() async throws {
        let f = ScopeFixture(mode: "restoreUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Final readback is unknown") } catch {}
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
        XCTAssertEqual(saved.expectedMutation?.target, 90)
        XCTAssertEqual(saved.lastVerified.target, 100)
        XCTAssertEqual(saved.phase, .indeterminate)
        XCTAssertTrue(f.service.recoveryRequired)
        XCTAssertFalse(f.service.admitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path))
    }

    func testScopedApplyPendingAndRestoreStayInsidePairUsingDedicatedBattery() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        try await service.apply(95, batteryPercent: nil, batteryFresh: false)
        await f.client.setMode("battery91")
        try await service.apply(90, batteryPercent: 50, batteryFresh: true)   // below the 91 % charge: written at once
        XCTAssertNil(service.pendingTarget)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit95", "limit90"])
        await f.client.setMode("")
        await service.observeBattery(percent: nil, fresh: false)
        XCTAssertNil(service.pendingTarget)
        XCTAssertEqual(service.observed?.configuration.target, 90)
        let restored = try await service.restore(batteryPercent: nil, batteryFresh: false)
        XCTAssertTrue(restored)
        XCTAssertFalse(service.hasOwnedSettings)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit95", "limit90"])
    }

    /// Owner decision 2026-11-06: the limit is the system's own setting. A verified slider choice stays after the app
    /// quits; quitting neither rewrites the previous value nor refuses to quit.
    func testVerifiedLimitIsAdoptedAndSurvivesQuitWithoutAnyRestoreWrite() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        try await service.apply(85, batteryPercent: 50, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        XCTAssertFalse(service.hasOwnedSettings, "A confirmed choice is the user's own macOS setting, not an app session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path), "No journal outlives the confirmed apply")
        XCTAssertFalse(service.recoveryRequired)
        let (model, suite) = f.makeModel(service)
        defer { model.stop(); TestDefaults.remove(suite) }
        let quit = await model.prepareForTermination()
        XCTAssertTrue(quit)
        XCTAssertEqual(service.observed?.configuration.target, 85)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit85"])
        let reopened = f.makeService(scope: scope)
        await reopened.refresh()
        XCTAssertFalse(reopened.recoveryRequired, "The next launch has nothing to review")
        XCTAssertEqual(reopened.observed?.configuration.target, 85)
        XCTAssertTrue(reopened.needsApply(target: 90), "The slider keeps working from the adopted setting")
    }

    /// Owner decision 2026-11-26: the slider does what System Settings does: 85 at a 91 % charge is written at once.
    func testLowerLimitThanTheChargeIsWrittenAtOnceLikeSystemSettings() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        await f.client.setMode("battery91")
        try await service.apply(85, batteryPercent: 91, batteryFresh: true)
        XCTAssertNil(service.pendingTarget)
        XCTAssertEqual(service.observed?.configuration.target, 85)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path), "a confirmed limit is the user's macOS setting")
        let quit = try await service.restore(batteryPercent: 91, batteryFresh: true)
        XCTAssertTrue(quit)
        XCTAssertEqual(service.observed?.configuration.target, 85, "quitting keeps it")
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit85"])
    }

    /// Owner report 2026-11-13: at 80 % charge, choosing the 80 % limit was refused with "waiting for discharge" (macOS accepts it).
    /// A limit equal to the charge level is applied at once; only a limit below the level waits.
    func testLimitEqualToTheChargeIsAppliedAtOnce() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        await f.client.setMode("battery80")
        try await service.apply(80, batteryPercent: 80, batteryFresh: true)
        XCTAssertNil(service.pendingTarget, "80 % limit at 80 % charge is not a lower limit")
        XCTAssertEqual(service.observed?.configuration.target, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        await f.client.setMode("battery91")
        try await service.apply(85, batteryPercent: 91, batteryFresh: true)
        XCTAssertNil(service.pendingTarget, "a limit below the charge level is written at once, as System Settings does")
        XCTAssertEqual(service.observed?.configuration.target, 85)
    }

    /// Owner report 2026-11-13: a waiting target (nothing written) plus a limit changed in System Settings left the panel
    /// stuck in "session needs review" with every new limit refused.
    func testWaitingTargetWithNothingWrittenNeverBecomesAReviewState() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        try f.writeWaitingJournal(environment: "scope-fixture")   // only older builds left a waiting target
        let reopened = f.makeService(scope: scope)
        XCTAssertFalse(reopened.recoveryRequired, "nothing was written, so there is nothing to review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        await reopened.refresh()
        XCTAssertTrue(reopened.canApplyTarget(90), "new limits are accepted")
    }

    func testQualificationFromAnotherPersistentBaselineRestoresThatBaseline() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.canRequestQualification)
        try await f.service.qualify()
        await f.assertWrites(["limit80", "limit90", "limit95", "limit100", "limit85"])
        XCTAssertTrue(f.service.admitted)
        XCTAssertEqual(f.service.authorizedPersistentTargets, [80, 85, 90, 95, 100])
        XCTAssertEqual(f.service.observed?.configuration.target, 85, "The user's own setting is what comes back.")
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertNotNil(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
    }

    func testScopedApplyToLimitOffAndBackKeepsEachConfirmedChoice() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        XCTAssertTrue(service.needsApply(target: 100))
        try await service.apply(100, batteryPercent: 50, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration, .init(enabled: false, target: 100, optimizedCharging: true), "100 is stored as limit off")
        XCTAssertFalse(service.hasOwnedSettings, "A confirmed choice is the user's own setting")
        XCTAssertFalse(service.needsApply(target: 100), "Already off: nothing to write")
        try await service.apply(85, batteryPercent: 50, batteryFresh: true)   // re-enables through the limit write itself
        XCTAssertEqual(service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        try await service.apply(100, batteryPercent: 50, batteryFresh: true)
        let quit = try await service.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(quit)
        XCTAssertEqual(service.observed?.configuration, .init(enabled: false, target: 100, optimizedCharging: true), "Quit leaves the last confirmed choice")
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit100", "limit85", "limit100"])
        XCTAssertFalse(service.recoveryRequired)
    }

    func testOnBatteryPowerTheValidatedLimitStillWorksButValidationNeedsTheRegistry() async throws {
        // Validation evidence is strict: with no registry entry (battery power) it is refused without a write.
        let unplugged = ScopeFixture(mode: "battery"); defer { unplugged.cleanup() }
        await unplugged.service.refresh()
        XCTAssertFalse(unplugged.service.canRequestQualification)
        do { try await unplugged.service.qualify(); XCTFail("Strict evidence needs the registry") } catch {}
        await unplugged.assertWrites([])
        XCTAssertFalse(unplugged.service.admitted)

        // Validated on AC, then used on battery power: the stored setting is read back and trusted.
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        await f.client.setMode("battery")
        let service = f.makeService(scope: scope)
        await service.refresh()
        XCTAssertTrue(service.isAvailable, "Policy matches: no registry entry is expected on battery power")
        XCTAssertTrue(service.canApplyTarget(85))
        try await service.apply(85, batteryPercent: 50, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration, .init(enabled: true, target: 85, optimizedCharging: true))
        XCTAssertFalse(service.hasOwnedSettings, "On battery power too, the confirmed limit is the user's own setting")
        let quit = try await service.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(quit)
        XCTAssertEqual(service.observed?.configuration.target, 85)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit85"])
    }

    /// Seen on macOS 27.2.1 (2026-11-25): a write's readback never agreed (two manual rows in the registry), the journal
    /// stayed unresolved and every later launch showed "unconfirmed outcome" forever. Once one clear limit reads back and
    /// it is a state the journal knew, the journal closes without any write.
    func testUnresolvedApplyJournalClosesWithoutWriteOnceAClearJournaledLimitReadsBack() async throws {
        let qualification = ["limit80", "limit85", "limit95", "limit100", "limit90"]
        for (label, settled) in [("requested 85", 85), ("original 90", 90)] {
            let f = ScopeFixture(); defer { f.cleanup() }
            try await f.service.qualify()
            let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
            let service = f.makeService(scope: scope)
            await service.refresh()
            await f.client.failReadsAfterNextWrite()
            do { try await service.apply(85, batteryPercent: 50, batteryFresh: true); XCTFail("\(label): unknown readback must stop") } catch {}
            XCTAssertFalse(service.recoveryRequired, "\(label): an unconfirmed write blocks nothing")
            XCTAssertEqual(service.presentation().attention, .mutationUnresolved, label)
            XCTAssertFalse(service.presentation().requiresGlobalAttention, "\(label): a status line, not a banner")
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
            XCTAssertEqual(saved.qualification, false, label)
            XCTAssertEqual(saved.phase, .indeterminate, label)
            await f.client.clearReadFailure()
            await f.client.external(target: settled)
            let young = f.makeService(scope: scope)
            await young.refresh()
            XCTAssertTrue(f.journalExists, "\(label): a just-written journal is not closed at once")
            XCTAssertFalse(young.recoveryRequired, label)
            try f.settle()
            let reopened = f.makeService(scope: scope)
            await reopened.refresh()
            XCTAssertFalse(reopened.recoveryRequired, label)
            XCTAssertFalse(reopened.hasOwnedSettings, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path), label)
            XCTAssertEqual(reopened.observed?.configuration.target, settled, label)
            XCTAssertTrue(reopened.needsApply(target: 90) || settled == 90, label)
            await f.assertWrites(qualification + ["limit85"], label)
        }
    }

    /// Owner contract 2026-11-26: even a failed validation run owes nothing (a confirmed limit is the user's own): its stage
    /// value 80 closes the journal at the first settled clear read, with no write.
    func testUnresolvedValidationJournalClosesOnAnyClearLimit() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
        XCTAssertEqual(saved.qualification, true)
        await f.client.setMode("")
        try f.settle()
        let stage = f.makeService()
        XCTAssertFalse(stage.recoveryRequired)
        await stage.refresh()   // reads 80, the requested stage value
        XCTAssertFalse(stage.recoveryRequired)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit80"])
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
    func testUnresolvedJournalStaysWhileTheRegistryConflictsOrTheLimitIsUnknown() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        try f.settle()
        await f.client.setMode("conflict")
        let conflicted = f.makeService(implicit: true)
        await conflicted.refresh()
        XCTAssertFalse(conflicted.recoveryRequired)
        XCTAssertTrue(f.journalExists)
        XCTAssertEqual(conflicted.presentation().attention, .mutationUnresolved)
        XCTAssertTrue(conflicted.canApplyTarget(85), "an unresolved session never blocks the slider")
        XCTAssertEqual(conflicted.nativeSetting?.registryConflict, true)
        XCTAssertEqual(conflicted.message, "macOS lists two different charge limits. Set the limit once in System Settings › Battery to bring them together.")
        await f.client.setMode("")
        await f.client.external(target: 85)   // neither before, confirmed nor requested: still the user's own clear setting
        await conflicted.refresh()
        XCTAssertFalse(f.journalExists)
        XCTAssertFalse(conflicted.hasUnresolvedSession)
        XCTAssertEqual(conflicted.presentation().attention, .none)
        await f.assertWrites(["limit80"])
    }

    /// Leftovers of every scoped phase and origin load without blocking anything and close at the first settled clear
    /// read with no write; a journal that never dispatched a write is deleted at launch.
    func testLeftoverSessionsOfEveryPhaseAndOriginCloseWithoutAWrite() async throws {
        let phases: [(NativeChargeJournal.Phase, Int?)] = [(.owned, nil), (.preparing, 85), (.restorationPending, nil), (.restoring, 90), (.indeterminate, 85)]
        for (phase, expected) in phases {
            for qualification in [true, false, nil] as [Bool?] {
                let label = "\(phase) \(String(describing: qualification))"
                let f = ScopeFixture(); defer { f.cleanup() }
                try f.writeSessionJournal(phase: phase, qualification: qualification, expected: expected)
                let reopened = f.makeService(implicit: true)
                XCTAssertFalse(reopened.recoveryRequired, label)
                XCTAssertFalse(reopened.restorationPending, label)
                XCTAssertTrue(reopened.hasUnresolvedSession, label)
                await reopened.refresh()
                XCTAssertTrue(f.journalExists, "\(label): young")
                XCTAssertTrue(reopened.offersTarget(85), label)
                XCTAssertTrue(reopened.canApplyTarget(85), label)
                XCTAssertFalse(reopened.hasOwnedSettings, "\(label): a scoped session owns nothing")
                let owed = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
                XCTAssertTrue(owed, "\(label): nothing is owed")
                try f.settle()
                await reopened.refresh()
                XCTAssertFalse(f.journalExists, label)
                XCTAssertFalse(reopened.hasUnresolvedSession, label)
                await f.assertWrites([], label)

                let g = ScopeFixture(); defer { g.cleanup() }
                try g.writeSessionJournal(phase: phase, hasWritten: false, qualification: qualification, expected: expected)
                let fresh = g.makeService(implicit: true)
                XCTAssertFalse(g.journalExists, "\(label): nothing was dispatched, nothing to review")
                XCTAssertFalse(fresh.hasUnresolvedSession, label)
            }
        }
    }

    func testOnBatteryALeftoverClosesButConflictingRowsWait() async throws {
        let f = ScopeFixture(mode: "battery"); defer { f.cleanup() }
        try f.writeSessionJournal(phase: .indeterminate, age: 120)
        let unplugged = f.makeService(implicit: true)
        await unplugged.refresh()
        XCTAssertFalse(f.journalExists, "the stored setting is the evidence on battery power")
        let g = ScopeFixture(mode: "batteryConflict"); defer { g.cleanup() }
        try g.writeSessionJournal(phase: .indeterminate, age: 120)
        let conflicted = g.makeService(implicit: true)
        await conflicted.refresh()
        XCTAssertTrue(g.journalExists, "two different rows wait until they age out")
        XCTAssertTrue(conflicted.canApplyTarget(85))
        await f.assertWrites([]); await g.assertWrites([])
    }

    /// A macOS update that changes the offered list is no reason to keep a session: it closes, and the slider writes.
    func testAChangedOfferedListClosesTheSessionAndTheSliderKeepsWorking() async throws {
        let f = ScopeFixture(mode: "offeredAll"); defer { f.cleanup() }
        try f.writeSessionJournal(phase: .indeterminate, age: 120)
        let service = f.makeService(implicit: true)
        await service.refresh()
        XCTAssertFalse(f.journalExists)
        await f.client.external(target: 85)
        await service.refresh()
        try await service.apply(90, batteryPercent: nil, batteryFresh: false)
        XCTAssertEqual(service.reportedLimit, 90)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit90"])
    }

    func testRestoreClosesAnOldUnresolvedJournalThatReadsItsBaseline() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        await f.client.setMode("")
        await f.client.external(target: 90)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: f.journal.path)
        let reopened = f.makeService()
        let restored = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored, "nothing is owed: no write, no refusal")
        XCTAssertFalse(reopened.recoveryRequired)
        await reopened.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path), "a later clear refresh closes it")
        await f.assertWrites(["limit80"])
    }

    /// Owner decision 2026-11-26: the limit works at once, at any charge, after every macOS update: the live interface
    /// grants it (no validation run, no proof file), and every write is still read back.
    func testLiveInterfaceGrantsTheLimitWithoutValidationAtAnyCharge() async throws {
        let f = ScopeFixture(mode: "battery89"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        XCTAssertTrue(service.awaitingDiscovery, "no Validate button flashes before the first read")
        XCTAssertFalse(service.admitted)
        await service.refresh()
        XCTAssertTrue(service.admitted)
        XCTAssertFalse(service.awaitingDiscovery)
        XCTAssertEqual(service.authorizedPersistentTargets, NativeChargeAdmission.persistentTargets)
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95, batteryPercent: 89, batteryFresh: true)   // above the charge: written and read back
        XCTAssertEqual(service.observed?.configuration.target, 95)
        try await service.apply(100, batteryPercent: 89, batteryFresh: true)  // limit off
        XCTAssertEqual(service.observed?.configuration.enabled, false)
        try await service.apply(85, batteryPercent: 89, batteryFresh: true)   // below the charge: written at once, as System Settings does
        XCTAssertNil(service.pendingTarget)
        XCTAssertEqual(service.observed?.configuration.target, 85)
        await f.assertWrites(["limit95", "limit100", "limit85"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path), "no proof file is invented")
        XCTAssertFalse(service.recoveryRequired)
    }

    func testOnBatteryJustAfterUnpluggingTheStaleRegistryRowsDoNotBlockAWrite() async throws {
        let f = ScopeFixture(mode: "batteryStaleRows"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95, batteryPercent: 60, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration.target, 95)
        XCTAssertFalse(service.recoveryRequired, "the stored setting is the evidence on battery power, not the stale rows")
        try await service.apply(100, batteryPercent: 60, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration.enabled, false)
        await f.assertWrites(["limit95", "limit100"])
    }

    func testOnBatteryConflictingStaleRowsAreNotEvidenceAndOnACTheSliderStillWrites() async throws {
        let f = ScopeFixture(mode: "batteryConflict"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95, batteryPercent: 60, batteryFresh: true)
        XCTAssertEqual(service.observed?.configuration.target, 95)
        XCTAssertFalse(service.recoveryRequired)
        await f.client.setMode("conflict")   // on AC two different rows: the hint shows, the slider still writes
        await service.refresh()
        XCTAssertEqual(service.message, "macOS lists two different charge limits. Set the limit once in System Settings › Battery to bring them together.")
        XCTAssertTrue(service.canApplyTarget(90), "the write is what clears a two-row conflict; the readback decides")
        XCTAssertEqual(service.reportedLimit, 95, "what macOS stores is shown")
        do { try await service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("a conflict that stays is not confirmed") } catch {}
        XCTAssertTrue(f.journalExists, "an unconfirmed write leaves a session that closes itself")
        XCTAssertTrue(service.canApplyTarget(85))
        await f.assertWrites(["limit95", "limit90"])
    }

    /// A macOS update changes only the middle of "model / OS / contract": a session journal stays reviewable.
    func testSessionJournalSurvivesAMacOSUpdateButNotAnotherMac() async throws {
        let contract = NativeChargeAdmission.semanticContract
        let before = "Mac17,3 / Version 27.2 (Build 26B123) / \(contract)", after = "Mac17,3 / Version 27.2.1 (Build 26B131) / \(contract)"
        XCTAssertTrue(NativeChargeAdmission.sameMachine(before, after))
        XCTAssertFalse(NativeChargeAdmission.sameMachine(before, "Mac16,1 / Version 27.2.1 (Build 26B131) / \(contract)"))
        XCTAssertFalse(NativeChargeAdmission.sameMachine(before, "Mac17,3 / Version 27.2.1 (Build 26B131) / PowerUI-v3"))
        XCTAssertFalse(NativeChargeAdmission.sameMachine("scope-fixture", "other-fixture"))
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Expected interruption") } catch {}
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        json["environment"] = before
        let moved = try JSONDecoder().decode(NativeChargeJournal.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(moved.hasPersistentScope(environment: after))
        XCTAssertFalse(moved.hasPersistentScope(environment: "Mac16,1 / Version 27.2.1 (Build 26B131) / \(contract)"))
    }

    func testWaitingTargetFromAnyMacOSVersionIsDroppedAtLaunch() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        _ = scope
        try f.writeWaitingJournal(environment: "an older macOS")
        let reopened = f.makeService(implicit: true)
        XCTAssertFalse(reopened.recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
    }

    func testLiveInterfaceGrantsNothingWhenATargetIsMissingOrMonitoringOnly() async throws {
        let f = ScopeFixture(mode: "offered"); defer { f.cleanup() }   // macOS offers no 95
        let partial = f.makeService(implicit: true)
        await partial.refresh()
        XCTAssertFalse(partial.admitted)
        XCTAssertFalse(partial.canApplyTarget(90))
        let g = ScopeFixture(); defer { g.cleanup() }
        let monitor = g.makeService(implicit: true, monitoringOnly: true)
        await monitor.refresh()
        XCTAssertFalse(monitor.admitted)
        XCTAssertFalse(monitor.awaitingDiscovery)
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
            let service = f.makeService(implicit: true)
            XCTAssertTrue(service.unreadableJournal, label)
            XCTAssertFalse(service.recoveryRequired, label)
            let restored = try await service.restore(batteryPercent: 50, batteryFresh: true)
            XCTAssertTrue(restored, "\(label): never acted on, never refuses")
            XCTAssertEqual(try Data(contentsOf: f.journal), bytes, "\(label): untouched before a clear read")
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
        let service = f.makeService(implicit: true)
        await service.refresh()   // young: stays
        XCTAssertTrue(service.unreadableJournal)
        try await service.apply(85, batteryPercent: nil, batteryFresh: false)
        XCTAssertFalse(service.unreadableJournal)
        XCTAssertEqual(try f.setAside().count, 1)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit85"])
    }

    // MARK: The one apply path (A2)

    func testAFailedFirstReadAfterTheWriteIsRetriedAndTheNextConfirms() async throws {
        let f = ScopeFixture(mode: "failFirstReadAfterWrite"); defer { f.cleanup() }
        let service = f.makeService(implicit: true, verificationAttempts: 2)
        await service.refresh()
        try await service.apply(85, batteryPercent: nil, batteryFresh: false)
        XCTAssertEqual(service.reportedLimit, 85)
        XCTAssertFalse(f.journalExists, "confirmed: the user's own setting, no journal left")
        XCTAssertFalse(service.hasUnresolvedSession)
        await f.assertWrites(["limit85"])
    }

    func testAnACRegistryConflictWritesOnceAndTheReadbackDecides() async throws {
        // The write rewrites both rows: confirmed, nothing left.
        let f = ScopeFixture(mode: "conflictUntilWrite"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        XCTAssertNil(service.presentation().activePolicy, "a conflict is not a confirmed policy")
        XCTAssertEqual(service.reportedLimit, 90, "but what macOS stores is shown")
        XCTAssertTrue(service.canApplyTarget(85))
        try await service.apply(85, batteryPercent: nil, batteryFresh: false)
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(service.presentation().activePolicy?.target, 85)
        await f.assertWrites(["limit85"])

        // The conflict stays: an indeterminate session that blocks nothing and closes itself later with no extra write.
        let g = ScopeFixture(mode: "conflict"); defer { g.cleanup() }
        let stuck = g.makeService(implicit: true)
        await stuck.refresh()
        do { try await stuck.apply(85, batteryPercent: nil, batteryFresh: false); XCTFail("not confirmed while two rows differ") }
        catch NativeChargeServiceError.readbackMismatch {} catch { XCTFail("Wrong error: \(error)") }
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: g.journal))
        XCTAssertEqual(saved.phase, .indeterminate)
        XCTAssertFalse(stuck.recoveryRequired)
        XCTAssertTrue(stuck.canApplyTarget(90))
        await g.client.setMode("")
        try g.settle()
        await stuck.refresh()
        XCTAssertFalse(g.journalExists)
        await g.assertWrites(["limit85"])
    }

    func testASingleStaleACRowDoesNotStopAWrite() async throws {
        let f = ScopeFixture(mode: "staleRow"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95))
        try await service.apply(95, batteryPercent: nil, batteryFresh: false)
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(service.presentation().activePolicy?.target, 95)
        await f.assertWrites(["limit95"])
    }

    func testAnInSessionLeftoverAndAnExternalChangeNeverFailTheNextApply() async throws {
        let f = ScopeFixture(mode: "conflict"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        do { try await service.apply(85, batteryPercent: nil, batteryFresh: false); XCTFail("unconfirmed") } catch {}
        XCTAssertTrue(service.hasUnresolvedSession)
        await f.client.setMode("")
        await f.client.external(target: 80)   // System Settings
        try await service.apply(95, batteryPercent: nil, batteryFresh: false)
        XCTAssertEqual(service.reportedLimit, 95)
        XCTAssertFalse(f.journalExists)
        XCTAssertFalse(service.hasUnresolvedSession)
        await f.assertWrites(["limit85", "limit95"])
    }

    func testAUserApplyNeedsNoBatteryReading() async throws {
        let f = ScopeFixture(mode: "batteryStale"); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        try await service.apply(80, batteryPercent: nil, batteryFresh: false)
        XCTAssertEqual(service.reportedLimit, 80)
        XCTAssertFalse(f.journalExists)
        await f.assertWrites(["limit80"])
    }

    func testAnExpectedCurrentMismatchWritesNothing() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        do { try await service.apply(100, batteryPercent: nil, batteryFresh: false, expectedCurrent: 80); XCTFail("changed elsewhere") }
        catch NativeChargeServiceError.changedElsewhere {} catch { XCTFail("Wrong error: \(error)") }
        XCTAssertFalse(f.journalExists)
        XCTAssertEqual(NativeChargeServiceError.changedElsewhere.localizedDescription, "The charge limit was changed in System Settings. Nothing was written.")
        try await service.apply(100, batteryPercent: nil, batteryFresh: false, expectedCurrent: 90)
        await f.assertWrites(["limit100"])
    }

    func testMonitoringOnlyNeverWrites() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let monitor = f.makeService(implicit: true, monitoringOnly: true)
        await monitor.refresh()
        do { try await monitor.apply(85, batteryPercent: 50, batteryFresh: true); XCTFail("monitoring never writes") } catch {}
        let restored = try await monitor.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored)
        await f.assertWrites([])
    }

    /// A journal save failure before the dispatch writes nothing and leaves nothing behind (no review, slider usable).
    func testAWriteAheadFailureBeforeDispatchLeavesNothingBehind() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        let service = f.makeService(implicit: true)
        await service.refresh()
        try FileManager.default.createDirectory(at: f.journal, withIntermediateDirectories: true)   // the journal path is blocked
        do { try await service.apply(85, batteryPercent: nil, batteryFresh: false); XCTFail("the journal must be saved first") } catch {}
        await f.assertWrites([])
        XCTAssertFalse(service.recoveryRequired)
        XCTAssertNotEqual(service.presentation().attention, .journalIntegrity)
        XCTAssertFalse(f.journalExists, "nothing is left on disk")
        try? FileManager.default.removeItem(at: f.journal)
        await service.refresh()
        try await service.apply(85, batteryPercent: nil, batteryFresh: false)
        await f.assertWrites(["limit85"])
    }
}

@MainActor struct ScopeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroScope-\(UUID())")
    let client: ScopeTransport
    let service: NativeChargeService
    var journal: URL { root.appendingPathComponent("session.json") }
    var admission: URL { root.appendingPathComponent("admission.json") }
    var proofHistory: URL { root.appendingPathComponent("native-charge-proof-history", isDirectory: true) }
    init(mode: String = "", initialTarget: Int = 90) {
        let transport = ScopeTransport(mode: mode, initialTarget: initialTarget); client = transport
        service = NativeChargeService(client: transport, journalURL: root.appendingPathComponent("session.json"), verificationAttempts: 1,
            environment: "scope-fixture", batteryProvider: { await transport.battery() }, admissionURL: root.appendingPathComponent("admission.json"))
    }
    func makeService(scope: NativeChargeAdmission.Scope? = nil, implicit: Bool = false, monitoringOnly: Bool = false,
                     verificationAttempts: Int = 1, operationTimeout: Duration = .seconds(15)) -> NativeChargeService {
        let transport = client
        return NativeChargeService(client: client, journalURL: journal, admissionScope: scope, monitoringOnly: monitoringOnly,
            verificationAttempts: verificationAttempts, environment: "scope-fixture", batteryProvider: { await transport.battery() },
            admissionURL: admission, operationTimeout: operationTimeout, implicitAdmission: implicit)
    }
    /// A scoped (v2) session journal as `makeScopedJournal` writes it: baseline 90, requested 85.
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
    private var batteryReads = 0
    private var reads = 0
    init(mode: String, initialTarget: Int = 90) { self.mode = mode; target = initialTarget }
    func setMode(_ value: String) { mode = value }
    private var failAfterWrites: Int?
    func failReadsAfterNextWrite() { failAfterWrites = writes.count }
    func clearReadFailure() { failAfterWrites = nil }
    func external(target value: Int) { target = value }
    func battery() -> ChargeObservation {
        batteryReads += 1
        return .init(percent: mode == "risingBefore95" && batteryReads >= 2 ? 89 : mode == "battery91" ? 91 : mode == "batteryMissing" ? nil : mode == "battery89" ? 89 : mode == "battery80" ? 80 : mode == "battery100" ? 100 : 60,
              externalPower: true, fresh: mode != "batteryStale")
    }
    private var failedReadAfterWrite = false
    /// A write held inside the transport until `releaseWrite()` (a quit in the middle of a write).
    private var holdNextWrite = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    var isHoldingWrite: Bool { heldWrite != nil }
    func holdWrites() { holdNextWrite = true }
    func releaseWrite() { heldWrite?.resume(); heldWrite = nil }
    func read() throws -> NativeChargeSnapshot {
        reads += 1
        if mode == "unknown" || (mode == "postUnknown" && !writes.isEmpty) || failAfterWrites.map({ writes.count > $0 }) == true
            || (mode == "unknownBefore95" && reads >= 2) || (mode == "restoreUnknown" && writes.count >= 5) {
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
        let target = mode == "baseline100" ? 100 : mode == "baseline85" || (mode == "externalBefore95" && reads >= 2) ? 85 : target
        // macOS stores 100 as "limit off": disabled, no registered manual limit (mode "baseline100" is an inconsistent enabled 100).
        let battery = mode == "battery" || mode == "batteryStaleRows" || mode == "batteryConflict"   // on battery power: the setting is stored, nothing is registered
        let off = target == 100 && mode != "baseline100"
        return .init(configuration: .init(enabled: mode != "disabled" && !off, target: target, optimizedCharging: mode != "obc"),
              supportedTargets: mode == "offered" ? [80,85,90,100] : mode == "offeredAll" ? Array(80...100) : [80,85,90,95,100],
              // "batteryStaleRows": just unplugged, macOS still lists the old 90 rows for a few minutes.
              registeredManualLimit: mode == "batteryStaleRows" ? 90 : mode == "disabled" || mode == "policy" || off || battery ? nil : target,
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
