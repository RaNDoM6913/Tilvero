import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

@MainActor final class NativeChargeScopeTests: XCTestCase {
    func testModePreviewDoesNotOfferTargetsOutsideVerifiedScope() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        await f.service.refresh()
        try await f.service.qualify()
        let suite = "ScopeModePreview-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(false, forKey: "historyEnabled")
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: [:]), preferences: preferences,
            historyURL: f.root.appendingPathComponent("preview.sqlite"),
            snapshotProvider: { .unavailable(reason: "Scoped mode preview fixture") }, nativeCharge: f.service)
        defer { model.stop() }
        for target in [100] {
            let plan = ModePlan(mode: .economy, chargeTarget: target, lowPower: false, displayIdleMinutes: nil, brightnessPercent: nil)
            XCTAssertEqual(model.modePreview(plan).first { $0.action == .charge }?.status, .excluded)
            model.setDraft(target)
            XCTAssertFalse(model.canApply)
        }
        for target in [80, 85, 95] {
            let allowed = ModePlan(mode: .economy, chargeTarget: target, lowPower: false, displayIdleMinutes: nil, brightnessPercent: nil)
            XCTAssertEqual(model.modePreview(allowed).first { $0.action == .charge }?.status, .available, "\(target)")
        }
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
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
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
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
            await f.assertWrites(["limit80", "limit85", "limit95", "limit90"], obstruction)
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
            await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
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
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
        XCTAssertTrue(f.service.admitted)
        XCTAssertEqual(f.service.authorizedPersistentTargets, [80, 85, 90, 95])
        XCTAssertTrue(f.service.canApplyTarget(95))
        XCTAssertTrue(f.service.canApplyTarget(80))
        XCTAssertTrue(f.service.canApplyTarget(85))
        XCTAssertFalse(f.service.canApplyTarget(100))
        XCTAssertFalse(f.service.hasOwnedSettings)
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        let reopened = f.makeService(scope: scope)
        await reopened.refresh()
        XCTAssertEqual(reopened.authorizedPersistentTargets, [80, 85, 90, 95])
        for target in [100] {
            do { try await reopened.apply(target, batteryPercent: 50, batteryFresh: true); XCTFail("Unqualified target \(target)") }
            catch NativeChargeServiceError.unqualifiedTarget {} catch { XCTFail("Wrong error: \(error)") }
        }
        do { try await reopened.chargeToFullOnce(batteryPercent: 50, batteryFresh: true); XCTFail("No full once capability") } catch {}
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
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

    func testScopedRestoreCannotWriteFromDisabledOutOfPairOrChangedOBCState() async throws {
        for mode in ["disabled", "baseline100", "baseline85", "obc", "unknown"] {
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
            case "scope": json["authorizedPersistentTargets"] = [80, 85, 90, 95, 100]
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

    func testScopedAdmissionDoesNotOwnAnUnverifiedBaseline() async throws {
        let f = ScopeFixture(); defer { f.cleanup() }
        try await f.service.qualify()
        let scope = try XCTUnwrap(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
        for mode in ["disabled", "baseline100", "obc", "unknown"] {   // 85 is a verified persistent target now
            await f.client.setMode(mode)
            let scoped = f.makeService(scope: scope)
            await scoped.refresh()
            do { try await scoped.apply(95, batteryPercent: 50, batteryFresh: true); XCTFail("Unverified baseline: \(mode)") } catch {}
            XCTAssertFalse(scoped.hasOwnedSettings)
            await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
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
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90"])
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: f.journal))
        XCTAssertEqual(saved.expectedMutation?.target, 90)
        XCTAssertEqual(saved.lastVerified.target, 95)
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
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90", "limit95"])
        await f.client.setMode("")
        await service.observeBattery(percent: nil, fresh: false)
        XCTAssertNil(service.pendingTarget)
        XCTAssertEqual(service.observed?.configuration.target, 90)
        let restored = try await service.restore(batteryPercent: nil, batteryFresh: false)
        XCTAssertTrue(restored)
        XCTAssertFalse(service.hasOwnedSettings)
        await f.assertWrites(["limit80", "limit85", "limit95", "limit90", "limit95", "limit90"])
    }

    func testQualificationFromAnotherPersistentBaselineRestoresThatBaseline() async throws {
        let f = ScopeFixture(initialTarget: 85); defer { f.cleanup() }
        await f.service.refresh()
        XCTAssertTrue(f.service.canRequestQualification)
        try await f.service.qualify()
        await f.assertWrites(["limit80", "limit90", "limit95", "limit85"])
        XCTAssertTrue(f.service.admitted)
        XCTAssertEqual(f.service.authorizedPersistentTargets, [80, 85, 90, 95])
        XCTAssertEqual(f.service.observed?.configuration.target, 85, "The user's own setting is what comes back.")
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertNotNil(NativeChargeAdmission.loadScope(from: f.admission, environment: "scope-fixture"))
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
    func makeService(scope: NativeChargeAdmission.Scope? = nil) -> NativeChargeService {
        let transport = client
        return NativeChargeService(client: client, journalURL: journal, admissionScope: scope, verificationAttempts: 1,
            environment: "scope-fixture", batteryProvider: { await transport.battery() }, admissionURL: admission)
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
    func battery() -> ChargeObservation {
        batteryReads += 1
        return .init(percent: mode == "risingBefore95" && batteryReads >= 2 ? 89 : mode == "battery91" ? 91 : mode == "batteryMissing" ? nil : mode == "battery89" ? 89 : mode == "battery80" ? 80 : mode == "battery100" ? 100 : 60,
              externalPower: true, fresh: mode != "batteryStale")
    }
    func read() throws -> NativeChargeSnapshot {
        reads += 1
        if mode == "unknown" || (mode == "postUnknown" && !writes.isEmpty)
            || (mode == "unknownBefore95" && reads >= 2) || (mode == "restoreUnknown" && writes.count >= 4) {
            throw NativeChargeReadFailure(supportedTargets: [80,85,90,95,100], currentTarget: 100, rawManualState: 3, diagnosticStoredTarget: 90)!
        }
        let target = mode == "baseline100" ? 100 : mode == "baseline85" || (mode == "externalBefore95" && reads >= 2) ? 85 : target
        return .init(configuration: .init(enabled: mode != "disabled", target: target, optimizedCharging: mode != "obc"),
              supportedTargets: mode == "offered" ? [80,85,90,100] : [80,85,90,95,100],
              registeredManualLimit: mode == "disabled" || mode == "policy" ? nil : target,
              collectedAt: mode == "stale" ? Date().addingTimeInterval(-100) : Date())
    }
    func setLimit(_ target: Int) { writes.append("limit\(target)"); self.target = target }
    func setEnabled(_ enabled: Bool) { writes.append(enabled ? "enable" : "disable") }
}
