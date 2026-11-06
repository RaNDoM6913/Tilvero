import XCTest
@testable import TilveroApp

/// A fake system: no pmset, sudo, osascript or sudoers file is ever touched by these tests.
private final class FakeLidSystem: LidSleepSystem, @unchecked Sendable {
    private let lock = NSLock()
    var sleepDisabled = false
    var ruleWorks = true
    var installGranted = true
    var writeSucceeds = true
    var writeApplies = true          // a refused write may still have applied
    var authorizedRestoreWorks = true
    var lidClosed = false
    var sleepAccepted = true
    private(set) var calls: [String] = []
    private func note(_ call: String) { lock.withLock { calls.append(call) } }
    var ruleFilePresent: Bool { ruleWorks }

    func readSleepDisabled() async -> Bool? { note("read"); return sleepDisabled }
    func passwordlessPathWorks() async -> Bool { note("probe"); return ruleWorks }
    func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool {
        note("set \(disabled)")
        guard ruleWorks else { return false }
        if writeSucceeds || writeApplies { sleepDisabled = disabled }
        return writeSucceeds
    }
    func installRule() async -> Bool { note("install"); if installGranted { ruleWorks = true }; return installGranted }
    func removeRule() async -> Bool { note("remove"); ruleWorks = false; return true }
    func restoreWithAuthorization() async -> Bool {
        note("authorized restore")
        if authorizedRestoreWorks { sleepDisabled = false }
        return authorizedRestoreWorks
    }
    func lidClosedWouldSleep() -> Bool { lidClosed }
    func requestSleep() -> Bool { note("sleep"); return sleepAccepted }
}

@MainActor final class LidSleepOverrideTests: XCTestCase {
    private func make(_ system: FakeLidSystem, awake: Bool = true) -> (LidSleepOverrideService, UserDefaults, () -> Void, () -> Void) {
        let suite = "LidSleep-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        var awakeFlag = awake
        let service = LidSleepOverrideService(system: system, defaults: defaults, allowed: true,
                                              awakeIsActive: { awakeFlag }, lidSleepRetryDelay: .milliseconds(1))
        return (service, defaults, { awakeFlag = false }, { defaults.removePersistentDomain(forName: suite) })
    }

    func testEnableWritesTheMarkerFirstThenTheOverrideAndRestoreClearsBoth() async throws {
        let system = FakeLidSystem()
        let (service, defaults, _, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        XCTAssertTrue(service.isOn)
        XCTAssertTrue(system.sleepDisabled)
        XCTAssertTrue(defaults.bool(forKey: LidSleepOverrideService.recoveryKey), "The intent is recorded while the override is set.")
        XCTAssertFalse(system.calls.contains("install"), "A working rule needs no administrator prompt.")
        await service.setPreferred(false)
        XCTAssertFalse(service.isOn)
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
        XCTAssertFalse(system.calls.contains("authorized restore"))
    }

    func testMissingRuleIsInstalledOnceAndADeniedPromptKeepsTheModeOff() async throws {
        let granted = FakeLidSystem(); granted.ruleWorks = false
        let (a, _, _, cleanA) = make(granted); defer { cleanA() }
        await a.setPreferred(true)
        XCTAssertTrue(a.isOn)
        XCTAssertEqual(granted.calls.filter { $0 == "install" }.count, 1)

        let denied = FakeLidSystem(); denied.ruleWorks = false; denied.installGranted = false
        let (b, defaults, _, cleanB) = make(denied); defer { cleanB() }
        await b.setPreferred(true)
        XCTAssertFalse(b.isOn)
        XCTAssertNotNil(b.failure)
        XCTAssertFalse(denied.calls.contains("set true"), "Nothing is written without the permission.")
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
    }

    func testAnOverrideThatIsAlreadySetIsNeverAdopted() async throws {
        let system = FakeLidSystem(); system.sleepDisabled = true   // another tool or the user's own pmset
        let (service, defaults, _, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        XCTAssertFalse(service.isOn)
        XCTAssertNotNil(service.failure)
        XCTAssertFalse(system.calls.contains { $0.hasPrefix("set") }, "Foreign state is never written.")
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
        XCTAssertTrue(system.sleepDisabled)
    }

    func testTerminationNeverClearsTheMarkerWhileAnOperationIsInFlight() async throws {
        let system = FakeLidSystem(); system.ruleWorks = false; system.installGranted = true
        let (service, defaults, _, cleanUp) = make(system)
        defer { cleanUp() }
        async let enabling: Void = service.setPreferred(true)
        try await Task.sleep(for: .milliseconds(1))
        let ready = await service.prepareForTermination()
        await enabling
        // Either the operation finished first and was restored, or termination refused; never "off + marker cleared + still set".
        XCTAssertTrue(ready || defaults.bool(forKey: LidSleepOverrideService.recoveryKey) || !system.sleepDisabled)
        XCTAssertFalse(system.sleepDisabled && !defaults.bool(forKey: LidSleepOverrideService.recoveryKey), "A set override always has its marker.")
    }

    func testTheOptionNeverStartsAnythingAndOnlyRecordsTheChoiceWithoutASession() async throws {
        let system = FakeLidSystem()
        let (service, defaults, _, cleanUp) = make(system, awake: false)
        defer { cleanUp() }
        await service.setPreferred(true)
        XCTAssertTrue(service.isPreferred)
        XCTAssertTrue(defaults.bool(forKey: LidSleepOverrideService.preferenceKey))
        XCTAssertFalse(service.isOn, "Without a Keep Awake session the override is not applied.")
        XCTAssertFalse(system.calls.contains("set true"), "Nothing is written to the system without a session.")
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
        await service.setPreferred(false)
        XCTAssertFalse(service.isPreferred)
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.preferenceKey))
    }

    func testARefusedWriteClearsTheMarkerOnlyWhenOffIsConfirmed() async throws {
        let off = FakeLidSystem(); off.writeSucceeds = false; off.writeApplies = false
        let (a, da, _, cleanA) = make(off); defer { cleanA() }
        await a.setPreferred(true)
        XCTAssertFalse(a.isOn)
        XCTAssertFalse(da.bool(forKey: LidSleepOverrideService.recoveryKey))
        XCTAssertFalse(a.needsRecovery)

        let ambiguous = FakeLidSystem(); ambiguous.writeSucceeds = false; ambiguous.writeApplies = true
        let (b, db, _, cleanB) = make(ambiguous); defer { cleanB() }
        await b.setPreferred(true)
        XCTAssertFalse(b.isOn)
        XCTAssertTrue(db.bool(forKey: LidSleepOverrideService.recoveryKey), "The override may be set: keep the marker.")
        XCTAssertTrue(b.needsRecovery)
    }

    func testRestoreUsesAdministratorAuthorizationOnlyForAnExplicitAction() async throws {
        let system = FakeLidSystem()
        let (service, defaults, _, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        system.ruleWorks = false          // the passwordless path vanished
        await service.restore(userInitiated: false, sleepIfLidClosed: false)
        XCTAssertTrue(service.needsRecovery, "No prompt for an automatic restore; the user is told instead.")
        XCTAssertFalse(system.calls.contains("authorized restore"))
        XCTAssertTrue(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
        await service.restoreSleep()
        XCTAssertTrue(system.calls.contains("authorized restore"))
        XCTAssertFalse(service.needsRecovery)
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
    }

    func testRestoreWithAClosedLidRequestsTheSleepTheLidWouldHaveCausedWithBoundedRetries() async throws {
        let system = FakeLidSystem(); system.lidClosed = true
        let (service, _, endSession, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        endSession()
        system.sleepAccepted = false
        await service.setPreferred(false)
        XCTAssertEqual(system.calls.filter { $0 == "sleep" }.count, 10, "Refused requests are retried a bounded number of times.")
        let open = FakeLidSystem(); open.lidClosed = false
        let (second, _, end2, clean2) = make(open); defer { clean2() }
        await second.setPreferred(true); end2()
        await second.setPreferred(false)
        XCTAssertFalse(open.calls.contains("sleep"), "An open lid needs no sleep request.")
    }

    func testNoSleepRequestWhileKeepAwakeIsStillRunning() async throws {
        let system = FakeLidSystem(); system.lidClosed = true
        let (service, _, _, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        await service.setPreferred(false)
        XCTAssertFalse(system.calls.contains("sleep"))
    }

    func testTerminationAndSleepPreparationRestoreWithoutAPromptAndReportFailure() async throws {
        let system = FakeLidSystem()
        let (service, defaults, _, cleanUp) = make(system)
        defer { cleanUp() }
        let idle = await service.prepareForTermination()
        XCTAssertTrue(idle, "Nothing to restore.")
        XCTAssertTrue(system.calls.isEmpty)
        await service.setPreferred(true)
        let restored = await service.prepareForTermination()
        XCTAssertTrue(restored)
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertFalse(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))

        await service.setPreferred(false)
        await service.setPreferred(true)
        XCTAssertTrue(service.isOn)
        system.ruleWorks = false
        let failed = await service.prepareForTermination()
        XCTAssertFalse(failed, "A set override blocks a clean exit or a sleep request.")
        XCTAssertFalse(system.calls.contains("authorized restore"))
        XCTAssertTrue(defaults.bool(forKey: LidSleepOverrideService.recoveryKey))
    }

    func testLaunchRecoveryFollowsTheMarker() async throws {
        let cleared = FakeLidSystem(); cleared.sleepDisabled = false
        let (a, da, _, cleanA) = make(cleared); defer { cleanA() }
        da.set(true, forKey: LidSleepOverrideService.recoveryKey)
        let again = LidSleepOverrideService(system: cleared, defaults: da, allowed: true)
        XCTAssertTrue(again.needsRecovery)
        await again.recoverIfNeeded()
        XCTAssertFalse(again.needsRecovery)
        XCTAssertFalse(cleared.calls.contains("set false"), "Already off: nothing to write.")
        _ = a

        let stuck = FakeLidSystem(); stuck.sleepDisabled = true
        let (_, db, _, cleanB) = make(stuck); defer { cleanB() }
        db.set(true, forKey: LidSleepOverrideService.recoveryKey)
        let service = LidSleepOverrideService(system: stuck, defaults: db, allowed: true)
        await service.recoverIfNeeded()
        XCTAssertFalse(stuck.sleepDisabled)
        XCTAssertFalse(db.bool(forKey: LidSleepOverrideService.recoveryKey))

        let noMarker = FakeLidSystem()
        let (plain, _, _, cleanC) = make(noMarker); defer { cleanC() }
        await plain.recoverIfNeeded()
        XCTAssertTrue(noMarker.calls.isEmpty, "Without a marker launch touches nothing.")
    }

    func testRemovingThePermissionIsRefusedWhileTheModeIsOn() async throws {
        let system = FakeLidSystem()
        let (service, _, _, cleanUp) = make(system)
        defer { cleanUp() }
        await service.setPreferred(true)
        await service.removePermission()
        XCTAssertFalse(system.calls.contains("remove"))
        await service.setPreferred(false)
        await service.removePermission()
        XCTAssertTrue(system.calls.contains("remove"))
        XCTAssertFalse(service.ruleFilePresent)
    }

    func testNativeHelpersBuildTheNarrowRuleAndParseTheState() {
        XCTAssertEqual(NativeLidSleepSystem.rule(uid: 501),
                       "#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0")
        let command = NativeLidSleepSystem.installCommand(uid: 501)
        XCTAssertTrue(command.contains("/usr/sbin/visudo -c -f /etc/sudoers.d/tilvero-lid.tmp"), "The rule is validated before it is moved into place.")
        XCTAssertTrue(command.contains("mv /etc/sudoers.d/tilvero-lid.tmp /etc/sudoers.d/tilvero-lid"))
        XCTAssertTrue(command.contains("{ rm -f /etc/sudoers.d/tilvero-lid.tmp; exit 1; }"))
        XCTAssertFalse(command.contains("chmod 0755"), "The system directory is not touched.")
        XCTAssertTrue(command.contains("chmod 0440"))
        XCTAssertTrue(NativeLidSleepSystem.sleepDisabled(inPmsetOutput: " SleepDisabled\t\t1\n"))
        XCTAssertFalse(NativeLidSleepSystem.sleepDisabled(inPmsetOutput: " SleepDisabled\t\t0\n"))
        XCTAssertFalse(NativeLidSleepSystem.sleepDisabled(inPmsetOutput: "sleep 10\n"))
        XCTAssertEqual(NativeLidSleepSystem.appleScriptLiteral(#"a "quoted" \ path"#), #""a \"quoted\" \\ path""#)
    }

    /// The option is on first; Keep Awake is started by the user later: the override follows that session only.
    func testTheOptionAppliesToTheNextKeepAwakeSessionAndNeverStartsOne() async throws {
        let system = FakeLidSystem()
        let suite = "LidModel-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") },
                                 keepAwakeTransport: AwakeFixture(), lidSleepSystem: system)
        defer { model.stop() }
        await model.lidSleep.setPreferred(true)
        XCTAssertTrue(model.lidSleep.isPreferred)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion, "The lid option never starts Keep Awake.")
        XCTAssertFalse(model.lidSleep.isOn)
        XCTAssertFalse(system.sleepDisabled)
        try SleepPillActions.setAwakeEnabled(model, enabled: true, token: nil)   // the user starts Keep Awake
        for _ in 0..<200 where !model.lidSleep.isOn { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.lidSleep.isOn, "The session now continues with the lid closed.")
        XCTAssertTrue(system.sleepDisabled)
        try model.keepAwake.stop()
        for _ in 0..<200 where model.lidSleep.isOn { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.lidSleep.isOn, "Ending Keep Awake ends the override.")
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertTrue(model.lidSleep.isPreferred, "The option itself stays on for the next session.")
        XCTAssertFalse(system.calls.contains("install") && system.calls.filter { $0 == "install" }.count > 1)
    }

    func testASessionThatStartsByItselfNeverRaisesAPasswordPrompt() async throws {
        let system = FakeLidSystem()
        let suite = "LidModel2-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") },
                                 keepAwakeTransport: AwakeFixture(), lidSleepSystem: system)
        defer { model.stop() }
        await model.lidSleep.setPreferred(true)
        let installsBefore = system.calls.filter { $0 == "install" }.count
        system.ruleWorks = false     // the rule vanished later
        try SleepPillActions.setAwakeEnabled(model, enabled: true, token: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.lidSleep.isOn)
        XCTAssertEqual(system.calls.filter { $0 == "install" }.count, installsBefore, "No prompt appears by itself when a session starts.")
        XCTAssertNotNil(model.lidSleep.failure)
    }
}
