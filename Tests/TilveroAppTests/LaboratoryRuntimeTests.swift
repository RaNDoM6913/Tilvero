// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Darwin
@testable import TilveroApp

final class LaboratoryRuntimeTests: XCTestCase {
    @MainActor func testMonitoringPolicyReachesEveryModelControlAndQuitDoesNotAcquireOwnership() async throws {
        let suite = "LabMonitoring-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabMonitoring-\(UUID())")
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let policy = AppLaunchPolicy.resolve(metadata: [:], arguments: ["--monitor-only"])
        let awake = MonitoringAwakeDriver(), timer = MonitoringSleepDriver()
        let model = TilveroModel(isDemo: false, launchPolicy: policy, preferences: preferences,
            historyURL: root.appendingPathComponent("History.sqlite"), keepAwakeTransport: awake, sleepTimerTransport: timer)
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.nativeCharge.isMonitoringOnly)
        XCTAssertFalse(model.keepAwake.isAvailable)
        XCTAssertFalse(model.sleepTimer.isAvailable)
        XCTAssertFalse(model.liveControl.canRegister)
        XCTAssertFalse(model.liveControl.canCharge)
        XCTAssertThrowsError(try model.keepAwake.start(seconds: 60))
        XCTAssertThrowsError(try model.selectSleepTimer(minutes: 15))
        do { try await model.nativeCharge.qualify(); XCTFail("Monitoring cannot qualify hardware") } catch {}
        do { try await model.nativeCharge.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Monitoring cannot write") } catch {}
        await model.keyboardBacklight.setEnabled(true)
        XCTAssertNil(model.keyboardBacklight.lastAppliedBrightness)
        XCTAssertFalse(model.keyboardBacklight.isAvailable)
        let sleepReady = await model.liveControl.prepareForRequestedSleep()
        XCTAssertFalse(sleepReady)
        model.setSleeping(true)
        let quitReady = await model.prepareForTermination()
        XCTAssertTrue(quitReady)
        model.stop()
        XCTAssertEqual(awake.mutations, 0)
        XCTAssertEqual(timer.mutations, 0)
        XCTAssertNotNil(preferences.string(forKey: "identitySalt").flatMap(UUID.init(uuidString:)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("native-charge-session.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("native-charge-validation.json").path))
    }
    func testLaboratoryIdentityUsesIndependentHistoryAndReopenChannel() throws {
        let lab = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.lab", "TilveroDataScope": "laboratory"])
        let root = URL(fileURLWithPath: "/isolated/Application Support")
        XCTAssertFalse(lab.isProduction, "Lab must never enter prototype migration")
        XCTAssertEqual(lab.historyURL(applicationSupport: root).path, "/isolated/Application Support/Tilvero/Laboratory/History.sqlite")
        XCTAssertEqual(lab.reopenNotificationName.rawValue, "local.tilvero.lab.showDetails")
        XCTAssertThrowsError(try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.lab", "TilveroDataScope": "production"]))
        XCTAssertThrowsError(try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.prototype", "TilveroDataScope": "laboratory"]))
    }

    func testLidTrialCannotSharePrototypeProductionOrCanonicalLabHistory() throws {
        let metadata: [String: Any] = ["CFBundleIdentifier": "local.tilvero.lidtrial",
            "TilveroDataScope": "lid-trial", "TilveroLidTrialHost": true]
        let trial = try ReleaseIdentity(metadata: metadata)
        let root = URL(fileURLWithPath: "/isolated/Application Support")
        let policy = AppLaunchPolicy.resolve(metadata: metadata)
        XCTAssertFalse(policy.monitoringOnly, "The dedicated lid trial retains its own qualified control route")
        XCTAssertTrue(policy.ordinaryHardwarePolicy.monitoringOnly, "Native charging/fans/general helper remain monitoring-only")
        XCTAssertTrue(policy.tighteningForUnavailableController().ordinaryHardwarePolicy.monitoringOnly)
        XCTAssertFalse(AppLaunchPolicy.resolve(metadata: [:]).ordinaryHardwarePolicy.monitoringOnly)
        XCTAssertTrue(trial.isLaboratory)
        XCTAssertTrue(trial.isLidTrial)
        XCTAssertFalse(trial.isProduction, "Trial must never enter prototype migration")
        XCTAssertEqual(trial.historyURL(applicationSupport: root).path, "/isolated/Application Support/Tilvero/LidTrial/History.sqlite")
        XCTAssertEqual(trial.reopenNotificationName.rawValue, "local.tilvero.lidtrial.showDetails")
        for scope in ["prototype", "production", "laboratory"] {
            var invalid = metadata; invalid["TilveroDataScope"] = scope
            XCTAssertThrowsError(try ReleaseIdentity(metadata: invalid))
        }
        var noMarker = metadata; noMarker.removeValue(forKey: "TilveroLidTrialHost")
        XCTAssertThrowsError(try ReleaseIdentity(metadata: noMarker))
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: metadata, arguments: ["--monitor-only"]).monitoringOnly)
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: metadata, runningBundleIdentifiers: ["local.tilvero.lab"]).monitoringOnly)
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: [:], runningBundleIdentifiers: ["local.tilvero.lidtrial"]).monitoringOnly)
    }

    func testLaunchPolicyOnlyTightensAcrossArgumentsAndKnownRunningVariants() {
        let lab: [String: Any] = ["CFBundleIdentifier": "local.tilvero.lab", "TilveroDataScope": "laboratory"]
        XCTAssertFalse(AppLaunchPolicy.resolve(metadata: lab).monitoringOnly)
        for identifier in ["local.tilvero.prototype", "io.github.random6913.tilvero", "local.tilvero.lab", "local.tilvero.lidtrial"] {
            let policy = AppLaunchPolicy.resolve(metadata: lab, runningBundleIdentifiers: [identifier])
            XCTAssertTrue(policy.monitoringOnly, identifier)
            XCTAssertNotNil(policy.monitoringReasonKey)
            XCTAssertEqual(policy.tighteningForUnavailableController(), policy, "A second restriction preserves the original reason")
        }
        XCTAssertFalse(AppLaunchPolicy.resolve(metadata: lab, runningBundleIdentifiers: ["unrelated.app"]).monitoringOnly)
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: lab, arguments: ["--monitor-only"]).monitoringOnly)
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: lab, arguments: ["--demo"]).monitoringOnly)
        var monitoring = lab; monitoring["TilveroReleaseMode"] = "monitoring"
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: monitoring, arguments: ["--control", "--normal"]).monitoringOnly)
        let production: [String: Any] = ["CFBundleIdentifier": "io.github.random6913.tilvero", "TilveroDataScope": "production"]
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: production, runningBundleIdentifiers: ["local.tilvero.lab"]).monitoringOnly)
        XCTAssertTrue(AppLaunchPolicy.resolve(metadata: lab).tighteningForUnavailableController().monitoringOnly)
    }

    func testControllerLeaseContendsUntilOwnerDestructionAndKeepsStableFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: ControllerSessionLease? = try ControllerSessionLease.acquire(directory: directory)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: directory))
        first = nil
        let second = try ControllerSessionLease.acquire(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("controller.lock").path))
        try withExtendedLifetime(second) {
            XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: directory))
        }
    }

    func testControllerLeaseRejectsSymlinkPermissiveDirectoryAndHardlinkedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeaseSafety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let insecure = root.appendingPathComponent("insecure")
        try FileManager.default.createDirectory(at: insecure, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: insecure))
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: alias))
        let external = root.appendingPathComponent("external")
        XCTAssertTrue(FileManager.default.createFile(atPath: external.path, contents: Data("preserve".utf8), attributes: [.posixPermissions: 0o600]))
        let lock = target.appendingPathComponent("controller.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: external)
        XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: target))
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: external, to: lock)
        XCTAssertThrowsError(try ControllerSessionLease.acquire(directory: target))
        XCTAssertEqual(try Data(contentsOf: external), Data("preserve".utf8))
    }
}

@MainActor private final class MonitoringAwakeDriver: KeepAwakeTransport {
    var mutations = 0
    func create(seconds: Int, name: String) throws -> UInt32 { mutations += 1; throw KeepAwakeError.unavailable }
    func createUntilStopped(name: String) throws -> UInt32 { mutations += 1; throw KeepAwakeError.unavailable }
    func setTimeout(_ id: UInt32, seconds: Int, name: String) throws { mutations += 1 }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? { nil }
    func release(_ id: UInt32, name: String) throws { mutations += 1 }
}
@MainActor private final class MonitoringSleepDriver: SleepTimerTransport {
    var mutations = 0
    var hasIdleHold: Bool { false }
    func acquireIdleHold(seconds: Int) throws { mutations += 1 }
    func extendIdleHold() throws { mutations += 1 }
    func replaceIdleHold(seconds: Int) throws { mutations += 1 }
    func releaseIdleHold() throws { mutations += 1 }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() throws { mutations += 1 }
}
