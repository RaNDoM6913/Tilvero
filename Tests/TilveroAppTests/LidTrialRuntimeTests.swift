// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import KeyboardBackends
import PowerPrivileged
@testable import TilveroApp

@MainActor final class LidTrialRuntimeTests: XCTestCase {
    func testTrialModelKeepsAwakeAndLidAdmissionSeparateFromOrdinaryHardware() async throws {
        let suite = "LidTrialRuntime-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let policy = AppLaunchPolicy.resolve(metadata: ["CFBundleIdentifier": ReleaseIdentity.lidTrialBundleIdentifier])
        let awake = AwakeFixture()
        let model = TilveroModel(isDemo: false, launchPolicy: policy, preferences: preferences,
            historyURL: root.appendingPathComponent("History.sqlite"), keepAwakeTransport: awake,
            sideEffects: .init(loginStatus: { "Fixture disabled" }, toggleLogin: {}, openBatterySettings: {}, rawCatalog: { [] }))
        defer { model.stop() }
        XCTAssertFalse(model.launchPolicy.monitoringOnly)
        XCTAssertTrue(model.nativeCharge.isMonitoringOnly)
        XCTAssertFalse(model.nativeCharge.canApply)
        XCTAssertFalse(model.liveControl.canRegister)
        XCTAssertFalse(model.liveControl.canCharge)
        XCTAssertFalse(model.liveControl.canFans)
        XCTAssertTrue(model.keepAwake.isAvailable)
        try model.startKeepAwakeDraft()
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        XCTAssertEqual(awake.createCount, 1)
        XCTAssertFalse(model.closedLid.isFixture, "An unsigned fixture host cannot become a simulated live trial")
        let fixtureLid = ClosedLidService(mode: .fixtureMemory, allowed: !policy.monitoringOnly)
        XCTAssertTrue(fixtureLid.isAvailable, "The dedicated lid route uses the original policy")
        for restricted in [AppLaunchPolicy.resolve(metadata: ["CFBundleIdentifier": ReleaseIdentity.lidTrialBundleIdentifier], arguments: ["--monitor-only"]),
                           policy.tighteningForUnavailableController()] {
            XCTAssertTrue(restricted.monitoringOnly)
            XCTAssertTrue(restricted.ordinaryHardwarePolicy.monitoringOnly)
            XCTAssertFalse(ClosedLidService(mode: .fixtureMemory, allowed: !restricted.monitoringOnly).isAvailable)
        }
    }

    func testTrialHardwarePolicyCannotQualifyApplyRecoverEnrollOrMutateKeyboard() async throws {
        let suite = "LidTrialPorts-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let policy = AppLaunchPolicy.resolve(metadata: ["CFBundleIdentifier": ReleaseIdentity.lidTrialBundleIdentifier]).ordinaryHardwarePolicy
        let journal = root.appendingPathComponent("native-charge-session.json")
        let original = Data("Preserve unrelated recovery data".utf8)
        try original.write(to: journal)
        let nativePort = TrialNativePort()
        let native = NativeChargeService(client: nativePort, journalURL: journal, admitted: true, monitoringOnly: policy.monitoringOnly)
        XCTAssertFalse(native.recoveryRequired, "A lid trial must not load unrelated native recovery state")
        do { try await native.qualify(); XCTFail("Trial cannot qualify charging") } catch {}
        do { try await native.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Trial cannot write charging") } catch {}
        _ = try await native.restore(batteryPercent: 60, batteryFresh: true)
        let nativeCalls = await nativePort.calls
        XCTAssertEqual(nativeCalls, 0)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        let registration = TrialRegistrationPort()
        let live = LiveControlService(preferences: preferences, trustVerified: true, registration: registration,
            makeTransport: { throw LiveControlError.unavailable }, discovery: { .init(capabilities: []) }, monitoringOnly: policy.monitoringOnly)
        do { try await live.registerHelper(); XCTFail("Trial cannot enroll ordinary helper") } catch {}
        XCTAssertEqual(registration.calls, 0)
        let keyboardPort = TrialKeyboardPort()
        let keyboard = KeyboardBacklightService(driver: keyboardPort,
            storage: UserDefaultsKeyboardBacklightStorage(defaults: preferences), allowed: !policy.monitoringOnly)
        await keyboard.refresh()
        await keyboard.setEnabled(true)
        XCTAssertEqual(keyboardPort.calls, 0)
        XCTAssertNil(keyboard.lastAppliedBrightness)
    }
}

private actor TrialNativePort: NativeChargeTransport {
    private(set) var calls = 0
    func read() throws -> NativeChargeSnapshot { calls += 1; throw NativeChargeServiceError.unavailable }
    func setLimit(_ target: Int) { calls += 1 }
    func setEnabled(_ enabled: Bool) { calls += 1 }
}
@MainActor private final class TrialRegistrationPort: LiveHelperRegistrationDriving {
    var state: HelperInstallationState { .notRegistered }
    var calls = 0
    func register() { calls += 1 }
    func unregister(afterVerifiedRestoration: Bool) { calls += 1 }
}
@MainActor private final class TrialKeyboardPort: KeyboardBacklightTransport {
    var calls = 0
    func read() throws -> KeyboardBacklightObservation { calls += 1; throw KeyboardBacklightError.unavailable }
    func setBrightness(_ value: Double, keyboardID: UInt64) { calls += 1 }
}
