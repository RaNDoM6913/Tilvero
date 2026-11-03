import XCTest
import Darwin
import ChargeBackends
@testable import TilveroApp

final class UpdateRecoveryTests: XCTestCase {
    func testReadinessNeverAdmitsOwnedOrIndeterminateHardware() {
        var value = UpdateRecoverySnapshot()
        XCTAssertTrue(value.blockers.isEmpty)
        for flag in [\UpdateRecoverySnapshot.nativeOwnership, \.nativeRecovery,
                     \.helperOwnership, \.helperRecovery, \.lidOwnership, \.lidRecovery,
                     \.operationInFlight, \.sleepTransition, \.persistentEvidence,
                     \.externalController, \.environmentUnknown] {
            value[keyPath: flag] = true
            XCTAssertFalse(value.blockers.isEmpty, "An unresolved boundary must postpone installation")
            value[keyPath: flag] = false
        }
    }

    func testAwakeAndTimerAreConsequencesButNotPermissionToRestoreHardware() {
        var value = UpdateRecoverySnapshot()
        value.awakeActive = true; value.timerActive = true
        XCTAssertTrue(value.blockers.isEmpty)
        XCTAssertEqual(value.consequences.count, 2)
        value.nativeOwnership = true
        XCTAssertFalse(value.blockers.isEmpty)
    }

    func testEvidenceProbeDoesNotCreateMissingDirectoriesOrReadJournalContents() throws {
        let root = physicalTemporaryDirectory.appendingPathComponent("UpdateEvidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(UpdateEvidenceProbe.inspect(root.appendingPathComponent("missing/session.json")), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let journal = root.appendingPathComponent("session.json")
        let bytes = Data("unreadable private recovery evidence".utf8)
        try bytes.write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.path)
        XCTAssertEqual(UpdateEvidenceProbe.inspect(journal), .present)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int, bytes.count)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testEvidenceProbeRejectsRedirectedPathRatherThanCallingItAbsent() throws {
        let root = physicalTemporaryDirectory.appendingPathComponent("UpdateSymlink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("redirect"),
                                                 withDestinationURL: root.appendingPathComponent("nonexistent"))
        XCTAssertEqual(UpdateEvidenceProbe.inspect(root.appendingPathComponent("redirect/session.json")), .unknown)
    }

    func testLeaseInspectionIsReadOnlyAndRecognizesHeldOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateLease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ControllerSessionLease.inspect(directory: directory), .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var lease: ControllerSessionLease? = try ControllerSessionLease.acquire(directory: directory)
        XCTAssertEqual(ControllerSessionLease.inspect(directory: directory), .occupied)
        lease = nil
        XCTAssertNil(lease)
        XCTAssertEqual(ControllerSessionLease.inspect(directory: directory), .available)
    }

    private var physicalTemporaryDirectory: URL {
        let path = FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
    }

    @MainActor func testInspectingAndCheckingIndeterminateJournalNeverStartsRestoration() async throws {
        let fixture = try UpdateModelFixture()
        defer { fixture.cleanUp() }
        let journalURL = fixture.root.appendingPathComponent("native.json")
        let configuration = NativeChargeConfiguration(enabled: true, target: 85, optimizedCharging: true)
        var journal = NativeChargeJournal(sessionID: UUID(), environment: "test", baseline: configuration,
                                          lastVerified: configuration, phase: .indeterminate)
        journal.hasWritten = true
        let bytes = try JSONEncoder().encode(journal)
        try bytes.write(to: journalURL)
        let transport = NativeChargeFixtureClient()
        let native = NativeChargeService(client: transport, journalURL: journalURL, environment: "test")
        let model = fixture.model(native: native, evidence: { [.absent] })
        defer { model.stop() }
        XCTAssertFalse(model.updateReadiness.blockers.isEmpty)
        XCTAssertFalse(model.updateReadiness.blockers.isEmpty)
        let admitted = await model.prepareForUpdateInstallation()
        XCTAssertFalse(admitted)
        let writes = await transport.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
        XCTAssertFalse(model.updatePreparationActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lease.path))
    }

    @MainActor func testUnknownPersistentStateDoesNotEndActiveAwakeSession() async throws {
        let fixture = try UpdateModelFixture()
        defer { fixture.cleanUp() }
        let awake = KeepAwakeService(driver: AwakeFixture(), sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        try awake.start(seconds: 60)
        let model = fixture.model(awake: awake, evidence: { [.unknown] })
        defer { model.stop() }
        let admitted = await model.prepareForUpdateInstallation()
        XCTAssertFalse(admitted)
        XCTAssertTrue(awake.isActive, "Readiness cannot cancel a session before an admitted install plan")
        XCTAssertFalse(model.updatePreparationActive)
    }

    @MainActor func testExplicitMonitoringHandoffHoldsLeaseAndBlocksNewSessionsUntilCancelled() async throws {
        let fixture = try UpdateModelFixture()
        defer { fixture.cleanUp() }
        let awake = KeepAwakeService(driver: AwakeFixture(), sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        try awake.start(seconds: 60)
        let model = fixture.model(awake: awake, evidence: { [.absent] })
        defer { model.stop() }
        let first = await model.prepareForUpdateInstallation()
        XCTAssertTrue(first)
        XCTAssertFalse(awake.hasOwnedAssertion)
        XCTAssertTrue(model.updatePreparationActive)
        XCTAssertEqual(ControllerSessionLease.inspect(directory: fixture.lease), .occupied)
        XCTAssertFalse(model.canStartKeepAwakeDraft)
        XCTAssertThrowsError(try model.startKeepAwakeDraft())
        XCTAssertThrowsError(try model.selectSleepTimer(minutes: 15))
        let repeated = await model.prepareForUpdateInstallation()
        XCTAssertTrue(repeated, "Final Sparkle confirmation must be repeat-safe")
        model.releaseUpdateInstallation()
        XCTAssertFalse(model.updatePreparationActive)
        XCTAssertEqual(ControllerSessionLease.inspect(directory: fixture.lease), .available)
        XCTAssertTrue(model.canStartKeepAwakeDraft)
    }

    @MainActor func testNewEvidenceAfterExclusionBlocksBeforeEndingSession() async throws {
        let fixture = try UpdateModelFixture()
        defer { fixture.cleanUp() }
        let awake = KeepAwakeService(driver: AwakeFixture(), sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        try awake.start(seconds: 60)
        var inspections = 0
        let model = fixture.model(awake: awake, evidence: { inspections += 1; return inspections == 1 ? [.absent] : [.present] })
        defer { model.stop() }
        let admitted = await model.prepareForUpdateInstallation()
        XCTAssertFalse(admitted)
        XCTAssertTrue(awake.isActive)
        XCTAssertFalse(model.updatePreparationActive)
        XCTAssertEqual(ControllerSessionLease.inspect(directory: fixture.lease), .available)
    }
}

@MainActor private struct UpdateModelFixture {
    let suite = "UpdateRecoveryModel-\(UUID())"
    let root: URL
    let preferences: UserDefaults
    var lease: URL { root.appendingPathComponent("lease") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateModel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    func model(native: NativeChargeService? = nil, awake: KeepAwakeService? = nil,
               evidence: @escaping () -> [UpdateEvidenceProbe.Result]) -> TilveroModel {
        TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: ["TilveroReleaseMode": "monitoring"]),
                     preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                     snapshotProvider: { .unavailable(reason: "Updater fixture") }, nativeCharge: native,
                     keepAwakeService: awake, updateIdentity: .init(info: ["CFBundleIdentifier": "io.github.random6913.tilvero",
                        "TilveroDataScope": "production", "TilveroReleaseMode": "monitoring",
                        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "4"]),
                     updateEvidence: evidence, updateLeaseDirectory: lease)
    }
    func cleanUp() { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
