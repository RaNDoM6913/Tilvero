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
        let restored = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored)
        await f.assertWrites(["limit80", "limit90"])
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
        XCTAssertTrue(restored)
        await g.assertWrites(["limit80", "limit90"])
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
        try await service.apply(90, batteryPercent: 50, batteryFresh: true)
        XCTAssertEqual(service.pendingTarget, 90)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit95"])
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
        let quit = try await service.restore(batteryPercent: 50, batteryFresh: true)   // what Quit calls
        XCTAssertTrue(quit)
        XCTAssertEqual(service.observed?.configuration.target, 85)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90", "limit85"])
        let reopened = f.makeService(scope: scope)
        await reopened.refresh()
        XCTAssertFalse(reopened.recoveryRequired, "The next launch has nothing to review")
        XCTAssertEqual(reopened.observed?.configuration.target, 85)
        XCTAssertTrue(reopened.needsApply(target: 90), "The slider keeps working from the adopted setting")
    }

    func testPendingLowerLimitIsDroppedOnQuitWithoutWritingAnything() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        await f.client.setMode("battery91")
        try await service.apply(85, batteryPercent: 91, batteryFresh: true)
        XCTAssertEqual(service.pendingTarget, 85)
        let quit = try await service.restore(batteryPercent: 91, batteryFresh: true)
        XCTAssertTrue(quit, "Quitting must not be refused because a lower limit is waiting")
        XCTAssertNil(service.pendingTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        XCTAssertEqual(service.observed?.configuration.target, 90, "Nothing was written: macOS keeps the previous limit")
        await f.assertWrites(["limit80", "limit85", "limit95", "limit100", "limit90"])
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
        XCTAssertEqual(service.pendingTarget, 85, "A limit below the charge level still waits for natural discharge")
    }

    /// Owner report 2026-11-13: a waiting target (nothing written) plus a limit changed in System Settings left the panel
    /// stuck in "session needs review" with every new limit refused.
    func testWaitingTargetWithNothingWrittenNeverBecomesAReviewState() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let service = f.makeService(scope: scope)
        await service.refresh()
        await f.client.setMode("battery91")
        try await service.apply(80, batteryPercent: 91, batteryFresh: true)
        XCTAssertEqual(service.pendingTarget, 80)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
        // The next launch: nothing was written, so there is nothing to review.
        let reopened = f.makeService(scope: scope)
        XCTAssertFalse(reopened.recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        // The user changes the limit in System Settings while a target waits.
        try await service.apply(80, batteryPercent: 91, batteryFresh: true)
        await f.client.external(target: 80)
        await service.refresh()
        XCTAssertFalse(service.recoveryRequired)
        XCTAssertNil(service.pendingTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        XCTAssertEqual(service.observed?.configuration.target, 80)
        XCTAssertTrue(service.canApplyTarget(90) || service.needsApply(target: 90), "New limits are accepted again")
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
            XCTAssertTrue(service.recoveryRequired, label)
            let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
            XCTAssertEqual(saved.qualification, false, label)
            await f.client.clearReadFailure()
            await f.client.external(target: settled)
            let young = f.makeService(scope: scope)
            await young.refresh()
            XCTAssertTrue(young.recoveryRequired, "\(label): a just-written journal is not closed at once")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: f.journal.path)
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

    /// A failed validation run still owes the original limit: its stage values never close the journal, the original does.
    func testUnresolvedValidationJournalClosesOnlyOnTheOriginalLimit() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
        XCTAssertEqual(saved.qualification, true)
        await f.client.setMode("")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: f.journal.path)
        let stage = f.makeService()
        await stage.refresh()   // reads 80, the requested stage value
        XCTAssertTrue(stage.recoveryRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
        await f.client.external(target: 90)
        let original = f.makeService()
        await original.refresh()
        XCTAssertFalse(original.recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        await f.assertWrites(["limit80"])
    }

    /// A journal from a build before 0.8.2 has no origin: before validation completed it can only be a validation run.
    func testLegacyUnresolvedJournalWithoutOriginIsTreatedAsValidationUntilAdmitted() {
        var journal = NativeChargeJournal(sessionID: UUID(), environment: "scope-fixture", baseline: .init(enabled: true, target: 90, optimizedCharging: true),
                                          lastVerified: .init(enabled: true, target: 90, optimizedCharging: true), plannedTarget: 80, phase: .indeterminate)
        journal.version = 2; journal.hasWritten = true; journal.expectedMutation = .init(enabled: true, target: 80, optimizedCharging: true)
        let read80 = NativeChargeSnapshot(configuration: .init(enabled: true, target: 80, optimizedCharging: true), supportedTargets: [80,85,90,95,100], registeredManualLimit: 80)
        XCTAssertFalse(NativeChargeService.closesUnresolvedJournal(journal, value: read80, age: 120, admitted: false))
        XCTAssertTrue(NativeChargeService.closesUnresolvedJournal(journal, value: read80, age: 120, admitted: true))
        XCTAssertFalse(NativeChargeService.closesUnresolvedJournal(journal, value: read80, age: 10, admitted: true))
        var restore = journal   // the user's own Restore to 90 from a confirmed 80: only the original closes it
        restore.qualification = false; restore.lastVerified = read80.configuration; restore.expectedMutation = restore.baseline
        XCTAssertFalse(NativeChargeService.closesUnresolvedJournal(restore, value: read80, age: 120, admitted: true))
        restore.expectedMutation = nil; restore.phase = .restorationPending
        XCTAssertFalse(NativeChargeService.closesUnresolvedJournal(restore, value: read80, age: 120, admitted: true))
        let read90 = NativeChargeSnapshot(configuration: .init(enabled: true, target: 90, optimizedCharging: true), supportedTargets: [80,85,90,95,100], registeredManualLimit: 90)
        restore.expectedMutation = restore.baseline; restore.phase = .indeterminate
        XCTAssertTrue(NativeChargeService.closesUnresolvedJournal(restore, value: read90, age: 120, admitted: true))
        let conflict = NativeChargeSnapshot(configuration: .init(enabled: true, target: 90, optimizedCharging: true), supportedTargets: [80,85,90,95,100],
                                            registeredManualLimit: nil, policyReadbackAvailable: false, registryConflict: true)
        XCTAssertFalse(NativeChargeService.closesUnresolvedJournal(journal, value: conflict, age: 120, admitted: true))
        let old = Data(#"{"configuration":{"enabled":true,"target":90,"optimizedCharging":true},"supportedTargets":[90],"registeredManualLimit":90,"policyReadbackAvailable":true,"collectedAt":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NativeChargeSnapshot.self, from: old).registryConflict, false)
    }

    func testUnresolvedJournalStaysWhileTheRegistryConflictsOrTheLimitIsUnknown() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: f.journal.path)
        await f.client.setMode("conflict")
        let conflicted = f.makeService()
        await conflicted.refresh()
        XCTAssertTrue(conflicted.recoveryRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
        XCTAssertEqual(conflicted.nativeSetting?.registryConflict, true)
        XCTAssertEqual(conflicted.message, "macOS lists two different charge limits. Set the limit once in System Settings › Battery to bring them together.")
        await f.client.setMode("")
        await f.client.external(target: 85)   // neither before, confirmed nor requested
        let foreign = f.makeService()
        await foreign.refresh()
        XCTAssertTrue(foreign.recoveryRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
        await f.assertWrites(["limit80"])
    }

    func testRestoreClosesAnOldUnresolvedJournalThatReadsItsBaseline() async throws {
        let f = ScopeFixture(mode: "postUnknown"); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Unknown postwrite must stop") } catch {}
        await f.client.setMode("")
        await f.client.external(target: 90)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: f.journal.path)
        let reopened = f.makeService()
        let restored = try await reopened.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(restored)
        XCTAssertFalse(reopened.recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
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
        try await service.apply(85, batteryPercent: 89, batteryFresh: true)   // below the charge: waits, as System Settings would hold it
        XCTAssertEqual(service.pendingTarget, 85)
        await f.assertWrites(["limit95", "limit100"])
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

    func testProductionScopeRejectsLegacyJournalAndPreservesItsBytes() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let legacy = NativeChargeJournal(sessionID: UUID(), environment: "scope-fixture", baseline: .init(enabled: true, target: 80, optimizedCharging: true), lastVerified: .init(enabled: true, target: 95, optimizedCharging: true), plannedTarget: nil, phase: .owned, hasWritten: true)
        let bytes = try JSONEncoder().encode(legacy); try bytes.write(to: f.journal)
        let service = f.makeService()
        _ = try? await service.restore(batteryPercent: 50, batteryFresh: true)
        XCTAssertTrue(service.recoveryRequired)
        XCTAssertEqual(try Data(contentsOf: f.journal), bytes)
        await f.assertWrites([])
    }
}

@MainActor private struct ScopeFixture {
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
    func makeService(scope: NativeChargeAdmission.Scope? = nil, implicit: Bool = false, monitoringOnly: Bool = false) -> NativeChargeService {
        let transport = client
        return NativeChargeService(client: client, journalURL: journal, admissionScope: scope, monitoringOnly: monitoringOnly, verificationAttempts: 1,
            environment: "scope-fixture", batteryProvider: { await transport.battery() }, admissionURL: admission, implicitAdmission: implicit)
    }
    func assertWrites(_ expected: [String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let writes = await client.writes
        XCTAssertEqual(writes, expected, message, file: file, line: line)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor ScopeTransport: NativeChargeTransport {
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
    func read() throws -> NativeChargeSnapshot {
        reads += 1
        if mode == "unknown" || (mode == "postUnknown" && !writes.isEmpty) || failAfterWrites.map({ writes.count > $0 }) == true
            || (mode == "unknownBefore95" && reads >= 2) || (mode == "restoreUnknown" && writes.count >= 5) {
            throw NativeChargeReadFailure(supportedTargets: [80,85,90,95,100], currentTarget: 100, rawManualState: 3, diagnosticStoredTarget: 90)!
        }
        let target = mode == "baseline100" ? 100 : mode == "baseline85" || (mode == "externalBefore95" && reads >= 2) ? 85 : target
        // macOS stores 100 as "limit off": disabled, no registered manual limit (mode "baseline100" is an inconsistent enabled 100).
        let battery = mode == "battery" || mode == "batteryStaleRows"   // on battery power: the setting is stored, nothing is registered
        let off = target == 100 && mode != "baseline100"
        return .init(configuration: .init(enabled: mode != "disabled" && !off, target: target, optimizedCharging: mode != "obc"),
              supportedTargets: mode == "offered" ? [80,85,90,100] : [80,85,90,95,100],
              // "batteryStaleRows": just unplugged, macOS still lists the old 90 rows for a few minutes.
              registeredManualLimit: mode == "batteryStaleRows" ? 90 : mode == "disabled" || mode == "policy" || off || battery ? nil : target,
              policyReadbackAvailable: mode != "conflict",
              collectedAt: mode == "stale" ? Date().addingTimeInterval(-100) : Date(), registrationExpected: !battery,
              registryConflict: mode == "conflict")
    }
    func setLimit(_ target: Int) { writes.append("limit\(target)"); self.target = target }
    func setEnabled(_ enabled: Bool) { writes.append(enabled ? "enable" : "disable") }
}
