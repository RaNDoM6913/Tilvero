// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Darwin
import PowerCore
import XCTest
@testable import TilveroApp

/// The watchdog's view of the system, faked: no pmset, sudo, display or audio is touched. The type has no way to
/// disable sleep, and every call is recorded so a test can prove that nothing but these calls happened.
private final class FakeWatchdogSystem: LidWatchdogSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool?
    private var log: [String] = []
    /// Readings returned in order before `state` is used (nil entries: unreadable).
    private var scripted: [Bool?] = []
    var clearWorks = true
    var lidClosed = false
    var sleepAccepted = true
    init(sleepDisabled: Bool?) { state = sleepDisabled }

    var calls: [String] { lock.withLock { log } }
    var sleepDisabled: Bool? { lock.withLock { state } }
    func script(_ readings: [Bool?]) { lock.withLock { scripted = readings } }
    private func note(_ call: String) { lock.withLock { log.append(call) } }

    func readSleepDisabled() async -> Bool? {
        note("read")
        return lock.withLock { scripted.isEmpty ? state : scripted.removeFirst() }
    }
    func clearSleepDisabled() async -> Bool {
        note("clear")
        if clearWorks { lock.withLock { state = false } }
        return clearWorks
    }
    func lidClosedWouldSleep() -> Bool { lidClosed }
    func requestSleep() -> Bool { note("sleep"); return sleepAccepted }
    func restoreComfort() async { note("comfort") }
}

private let allowedWatchdogCalls: Set<String> = ["read", "clear", "sleep", "comfort"]

@MainActor final class LidWatchdogTests: XCTestCase {
    private var directory: URL!
    private var store: LidOverrideMarkerStore!
    private var suite: String!
    private var defaults: UserDefaults!
    private let fast = LidWatchdog.Timing(lockTimeout: 0.3, comfortTimeout: .milliseconds(200), clearRetryDelay: .milliseconds(1),
                                          sleepAttempts: 3, sleepRetryDelay: .milliseconds(1))

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroTests-LidWatchdog-\(UUID().uuidString)", isDirectory: true)
        store = LidOverrideMarkerStore(directory: directory)
        suite = "TilveroTests-LidWatchdog-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func marker(_ token: String = UUID().uuidString) -> LidOverrideMarker {
        LidOverrideMarker(token: token, pid: getpid(), createdAt: Date(), boot: LidOverrideMarkerStore.bootSessionUUID())
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        return (fds[0], fds[1])
    }

    // MARK: Marker store

    func testTheMarkerIsWrittenAtomicallyWithOwnerOnlyPermissions() throws {
        let written = marker()
        try store.write(written)
        XCTAssertEqual(store.read(), .marker(written))
        var info = stat()
        XCTAssertEqual(lstat(store.markerURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "No temporary file is left behind.")
        let replacement = marker()
        try store.write(replacement)
        XCTAssertEqual(store.read(), .marker(replacement), "A new session's marker replaces the old one.")
    }

    func testCompareTokenAndDeleteOnlyRemovesTheOwnMarker() throws {
        let own = marker()
        try store.write(own)
        XCTAssertFalse(store.deleteIfOwned(by: UUID().uuidString))
        XCTAssertEqual(store.read(), .marker(own))
        XCTAssertTrue(store.deleteIfOwned(by: own.token))
        XCTAssertEqual(store.read(), .absent)
        XCTAssertNoThrow(try store.delete(), "Deleting a missing marker counts as done.")
    }

    func testADamagedMarkerIsPresentButNeverOwn() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a marker".utf8).write(to: store.markerURL)
        XCTAssertEqual(store.read(), .unreadable)
        XCTAssertTrue(store.read().isPresent)
        XCTAssertEqual(store.read().ownership(of: UUID().uuidString), .foreign)
        XCTAssertEqual(LidOverrideMarkerStore(directory: directory.appendingPathComponent("missing")).read(), .absent)
    }

    func testTheLockIsExclusiveBetweenOpenFiles() throws {
        let first = try XCTUnwrap(store.tryLock())
        XCTAssertNil(store.tryLock(), "A second holder (another process, or a watchdog) waits.")
        XCTAssertNil(store.lock(timeout: 0.1))
        first.unlock()
        let second = try XCTUnwrap(store.tryLock())
        second.unlock()
    }

    func testTheAppHoldsOneSharedLockAcrossOverlappingOperations() async throws {
        let holder = LidOverrideLockHolder(store: store)
        let outer = await holder.acquire(timeout: .milliseconds(100))
        let inner = await holder.acquire(timeout: .milliseconds(100))
        XCTAssertTrue(outer); XCTAssertTrue(inner)
        XCTAssertNil(store.tryLock())
        holder.release()
        XCTAssertNil(store.tryLock(), "Still held by the outer operation.")
        holder.release()
        let free = try XCTUnwrap(store.tryLock())
        let blocked = await holder.acquire(timeout: .milliseconds(80))
        XCTAssertFalse(blocked, "Taken by someone else: the app gives up after the timeout instead of blocking.")
        free.unlock()
    }

    // MARK: The watchdog over a real pipe

    func testTheReleaseByteEndsTheWatchdogWithoutTouchingAnything() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let ends = try makePipe(); defer { close(ends.read) }
        var byte = LidWatchdog.releaseByte
        XCTAssertEqual(write(ends.write, &byte, 1), 1)
        close(ends.write)
        let signal = await LidWatchdog.watch(fd: ends.read)
        XCTAssertEqual(signal, .released)
        let outcome = await LidWatchdog.act(signal: signal, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .released)
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertEqual(store.read(), .marker(own), "Released means the app owns the cleanup.")
    }

    func testOtherBytesAreIgnoredAndTheEndOfThePipeActs() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let ends = try makePipe(); defer { close(ends.read) }
        var noise: UInt8 = 0x00
        XCTAssertEqual(write(ends.write, &noise, 1), 1)
        close(ends.write)                                 // the app died without a release
        let signal = await LidWatchdog.watch(fd: ends.read)
        XCTAssertEqual(signal, .endOfFile)
        let outcome = await LidWatchdog.act(signal: signal, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(system.calls, ["read", "comfort", "clear", "read"], "Comfort first, then the clear, then a confirming read.")
        XCTAssertEqual(system.sleepDisabled, false)
        XCTAssertEqual(store.read(), .absent)
        XCTAssertTrue(Set(system.calls).isSubset(of: allowedWatchdogCalls))
    }

    func testAClosedLidGetsTheSleepItWouldHaveCaused() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true); system.lidClosed = true; system.sleepAccepted = false
        let outcome = await LidWatchdog.act(signal: .endOfFile, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(system.calls.filter { $0 == "sleep" }.count, 3, "Refused requests are retried a bounded number of times.")
        XCTAssertEqual(system.calls.filter { $0 == "comfort" }.count, 1)
        XCTAssertLessThan(system.calls.firstIndex(of: "clear")!, system.calls.firstIndex(of: "sleep")!)
    }

    func testAForeignTokenOrNoMarkerMeansTheWatchdogLeavesEverythingAlone() async throws {
        let newer = marker(); try store.write(newer)
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let foreign = await LidWatchdog.act(signal: .endOfFile, token: UUID().uuidString, store: store, system: system, timing: fast)
        XCTAssertEqual(foreign, .notOwner)
        XCTAssertEqual(store.read(), .marker(newer), "The newer session's marker stays.")
        try store.delete()
        let absent = await LidWatchdog.act(signal: .endOfFile, token: newer.token, store: store, system: system, timing: fast)
        XCTAssertEqual(absent, .notOwner)
        XCTAssertTrue(system.calls.isEmpty, "Nothing is read or written for someone else's override.")
        XCTAssertEqual(system.sleepDisabled, true)
    }

    func testSleepAlreadyNormalOnlyRemovesTheMarker() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: false)
        let outcome = await LidWatchdog.act(signal: .endOfFile, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .alreadyNormal)
        XCTAssertEqual(system.calls, ["read"])
        XCTAssertEqual(store.read(), .absent)
    }

    func testAnUnreadableStateIsClearedAndConfirmed() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true)
        system.script([nil])
        let outcome = await LidWatchdog.act(signal: .endOfFile, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(system.calls, ["read", "comfort", "clear", "read"])
    }

    func testTheRetryCapLeavesTheMarkerForLaunchRecovery() async throws {
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true); system.clearWorks = false
        let outcome = await LidWatchdog.act(signal: .endOfFile, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .gaveUp)
        XCTAssertEqual(system.calls.filter { $0 == "clear" }.count, LidWatchdogPolicy.maximumClearAttempts)
        XCTAssertEqual(system.calls.filter { $0 == "comfort" }.count, 1)
        XCTAssertEqual(store.read(), .marker(own))
        XCTAssertTrue(Set(system.calls).isSubset(of: allowedWatchdogCalls))
    }

    func testALockHeldByALiveRunMeansNoAction() async throws {
        let own = marker(); try store.write(own)
        let held = try XCTUnwrap(store.tryLock())
        defer { held.unlock() }
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let outcome = await LidWatchdog.act(signal: .endOfFile, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .lockUnavailable)
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertEqual(store.read(), .marker(own))
    }

    /// The race the lock exists for: an old watchdog wakes up while a new session is starting. It waits for the lock,
    /// then finds the new token and never clears the new session's override.
    func testAWatchdogThatWaitsForANewSessionNeverClearsIt() async throws {
        let old = marker(); try store.write(old)
        let enabling = try XCTUnwrap(store.tryLock())     // the app is in its enable step
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let store = self.store!
        var patient = fast; patient.lockTimeout = 5
        let timing = patient
        let watchdog = Task.detached { await LidWatchdog.act(signal: .endOfFile, token: old.token, store: store, system: system, timing: timing) }
        try await Task.sleep(for: .milliseconds(100))
        try store.write(marker())                          // the new session's marker, then its disablesleep 1
        enabling.unlock()
        let outcome = await watchdog.value
        XCTAssertEqual(outcome, .notOwner)
        XCTAssertFalse(system.calls.contains("clear"))
        XCTAssertEqual(system.sleepDisabled, true)
    }

    func testTheStartHandshakeNeedsTheReadyByteInTime() async throws {
        let confirmed = try makePipe(); defer { close(confirmed.read) }
        var byte = LidWatchdog.readyByte
        XCTAssertEqual(write(confirmed.write, &byte, 1), 1)
        let ok = await LidWatchdog.waitForReady(fd: confirmed.read, timeout: 1)
        XCTAssertTrue(ok)
        close(confirmed.write)

        let silent = try makePipe(); defer { close(silent.read); close(silent.write) }
        let timedOut = await LidWatchdog.waitForReady(fd: silent.read, timeout: 0.1)
        XCTAssertFalse(timedOut, "A child that never confirms is not a watchdog.")

        let gone = try makePipe(); defer { close(gone.read) }
        close(gone.write)
        let ended = await LidWatchdog.waitForReady(fd: gone.read, timeout: 1)
        XCTAssertFalse(ended, "A child that exited before confirming is not a watchdog.")

        let wrong = try makePipe(); defer { close(wrong.read) }
        var other: UInt8 = 0x41
        XCTAssertEqual(write(wrong.write, &other, 1), 1)
        close(wrong.write)
        let mismatch = await LidWatchdog.waitForReady(fd: wrong.read, timeout: 1)
        XCTAssertFalse(mismatch)
    }

    func testABrokenPipeIsNeverMistakenForTheAppEnding() async throws {
        XCTAssertEqual(LidWatchdog.waitForSignal(fd: -1), .pipeFailed)
        let own = marker(); try store.write(own)
        let system = FakeWatchdogSystem(sleepDisabled: true)
        let outcome = await LidWatchdog.act(signal: .pipeFailed, token: own.token, store: store, system: system, timing: fast)
        XCTAssertEqual(outcome, .pipeFailed)
        XCTAssertTrue(system.calls.isEmpty)
    }

    /// The watchdog's code path has no way to disable sleep: neither its system protocol nor its source mentions it.
    func testTheWatchdogCannotDisableSleep() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let watchdog = try String(contentsOf: root.appendingPathComponent("Sources/TilveroApp/LidWatchdog.swift"), encoding: .utf8)
        for forbidden in ["\"disablesleep\", \"1\"", "disablesleep 1\"", "setSleepDisabledPasswordless", "NativeLidSleepSystem"] {
            XCTAssertFalse(watchdog.contains(forbidden), forbidden)
        }
        let service = try String(contentsOf: root.appendingPathComponent("Sources/TilveroApp/LidSleepOverrideService.swift"), encoding: .utf8)
        let shared = try XCTUnwrap(service.range(of: "enum LidSleepCommands"))
        let native = try XCTUnwrap(service.range(of: "struct NativeLidSleepSystem"))
        let commands = service[shared.lowerBound..<native.lowerBound]
        XCTAssertFalse(commands.contains("\"1\""), "The shared commands (used by the watchdog) only clear.")
        XCTAssertEqual(LidSleepCommands.clearArguments, ["-n", "/usr/bin/pmset", "disablesleep", "0"])
    }

    // MARK: Launch

    func testOnlyTheExactWatchdogInvocationIsRecognised() {
        let token = UUID().uuidString
        XCTAssertEqual(LidWatchdog.invocation(arguments: ["/A/Tilvero", "--lid-watchdog", token, "/Users/x/Library/Application Support/Tilvero/Production"]),
                       LidWatchdog.Invocation(token: token, markerDirectory: URL(fileURLWithPath: "/Users/x/Library/Application Support/Tilvero/Production", isDirectory: true)))
        XCTAssertEqual(LidWatchdog.arguments(token: token, markerDirectory: URL(fileURLWithPath: "/tmp/m", isDirectory: true)),
                       ["--lid-watchdog", token, "/tmp/m"])
        for arguments in [["/A/Tilvero"], ["/A/Tilvero", "--demo"], ["/A/Tilvero", "--lid-watchdog"],
                          ["/A/Tilvero", "--lid-watchdog", "not-a-uuid", "/tmp"], ["/A/Tilvero", "--lid-watchdog", token, "relative"],
                          ["/A/Tilvero", "--doctor", "--lid-watchdog", token], ["/A/Tilvero", "--lid-watchdog", token, "/tmp", "--extra"]] {
            XCTAssertNil(LidWatchdog.invocation(arguments: arguments), arguments.joined(separator: " "))
        }
    }

    /// `--lid-watchdog` branches off first in `main`, before `--doctor` and before NSApplication, and never returns.
    func testTheWatchdogBranchRunsBeforeNSApplication() throws {
        let never: (LidWatchdog.Invocation) -> Never = LidWatchdog.runAndExit
        _ = never
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/TilveroApp/TilveroMain.swift"), encoding: .utf8)
        let branch = try XCTUnwrap(main.range(of: "LidWatchdog.invocation(arguments: CommandLine.arguments)"))
        let doctor = try XCTUnwrap(main.range(of: "\"--doctor\""))
        let application = try XCTUnwrap(main.range(of: "NSApplication.shared"))
        XCTAssertLessThan(branch.lowerBound, doctor.lowerBound)
        XCTAssertLessThan(branch.lowerBound, application.lowerBound)
    }

    func testAWatchdogProcessIsRecognisedByItsArguments() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(4)) { bytes += $0 }
        bytes += Array("/A/Tilvero.app/Contents/MacOS/Tilvero".utf8) + [0, 0, 0]
        for argument in ["/A/Tilvero.app/Contents/MacOS/Tilvero", "--lid-watchdog", "T", "/D"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("HOME=/Users/x".utf8) + [0]
        XCTAssertEqual(LidWatchdog.parseProcessArguments(bytes), ["/A/Tilvero.app/Contents/MacOS/Tilvero", "--lid-watchdog", "T", "/D"])
        XCTAssertNil(LidWatchdog.parseProcessArguments([1, 0]))
        let own = try XCTUnwrap(LidWatchdog.processArguments(pid: getpid()))
        XCTAssertFalse(own.isEmpty)
        XCTAssertFalse(LidWatchdog.isWatchdogProcess(pid: getpid()))
    }

    func testTheNativeLauncherNeverSpawnsOutsideAnAppBundle() async throws {
        try XCTSkipIf(Bundle.main.bundleURL.pathExtension == "app", "Only meaningful when the tests run outside an app bundle.")
        let handle = await NativeLidWatchdogLauncher().launch(token: UUID().uuidString, markerDirectory: directory)
        XCTAssertNil(handle)
    }

    func testTheModelPicksTheWatchdogAndTheMarkerPlace() async {
        let history = URL(fileURLWithPath: "/Users/x/Library/Application Support/Tilvero/Production/History.sqlite")
        let live = TilveroModel.lidSleepRoute(isDemo: false, monitoringOnly: false, injectedSystem: false, appBundle: true, historyURL: history)
        XCTAssertTrue(live.watchdogIsNative)
        XCTAssertEqual(live.markerDirectory.path, "/Users/x/Library/Application Support/Tilvero/Production")
        XCTAssertTrue(live.observesSystemSleep)
        let demo = TilveroModel.lidSleepRoute(isDemo: true, monitoringOnly: false, injectedSystem: false, appBundle: true, historyURL: history)
        XCTAssertTrue(demo.watchdogIsInert)
        XCTAssertNotEqual(demo.markerDirectory.path, live.markerDirectory.path, "A demo never sees the real marker.")
        XCTAssertTrue(TilveroModel.lidSleepRoute(isDemo: false, monitoringOnly: true, injectedSystem: false, appBundle: true, historyURL: history).watchdogIsInert)
        let fake = TilveroModel.lidSleepRoute(isDemo: false, monitoringOnly: false, injectedSystem: true, appBundle: false, historyURL: nil)
        XCTAssertTrue(fake.watchdogIsInert)
        XCTAssertTrue(fake.markerDirectory.lastPathComponent.hasPrefix("TilveroLidMarker-"))
        let runner = TilveroModel.lidSleepRoute(isDemo: false, monitoringOnly: false, injectedSystem: false, appBundle: false, historyURL: nil,
                                                identityHistoryURL: { history })
        XCTAssertFalse(runner.watchdogIsNative); XCTAssertFalse(runner.watchdogIsInert)
        let refused = await runner.watchdog.launch(token: UUID().uuidString, markerDirectory: directory)
        XCTAssertNil(refused, "A test runner never gets a watchdog, so never an override.")
        XCTAssertFalse(runner.observesSystemSleep, "The real system is not even read from a test runner.")
        XCTAssertNotEqual(runner.markerDirectory.path, live.markerDirectory.path)
    }

    // MARK: The service with a fake launcher

    private func makeService(_ system: FakeLidSystem, launcher: FakeWatchdogLauncher, awake: Bool = true,
                             enableLockTimeout: Duration = .seconds(5), observes: Bool = true) -> LidSleepOverrideService {
        let flag = awake
        return LidSleepOverrideService(system: system, defaults: defaults, allowed: true, markers: store, watchdog: launcher,
                                       observesSystemSleep: observes, awakeIsActive: { flag }, lidSleepRetryDelay: .milliseconds(1),
                                       enableLockTimeout: enableLockTimeout, restoreLockTimeout: .milliseconds(200), recoveryLockTimeout: .milliseconds(200))
    }

    func testTheWatchdogStartsAndTheMarkerIsWrittenBeforeTheOverride() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher()
        launcher.onLaunch = { _ in system.note("spawn") }
        let store = self.store!
        nonisolated(unsafe) var onDiskAtWrite: LidOverrideMarkerReading?
        system.onSet = { disabled in if disabled { onDiskAtWrite = store.read() } }
        let service = makeService(system, launcher: launcher)
        await service.setPreferred(true)
        XCTAssertTrue(service.isOn)
        let spawn = try XCTUnwrap(system.calls.firstIndex(of: "spawn")), write = try XCTUnwrap(system.calls.firstIndex(of: "set true"))
        XCTAssertLessThan(spawn, write)
        let handle = try XCTUnwrap(launcher.handles.first)
        guard case .marker(let marker)? = onDiskAtWrite else { return XCTFail("The marker must be on disk before disablesleep 1.") }
        XCTAssertEqual(marker.token, handle.token)
        XCTAssertEqual(marker.pid, getpid())
        XCTAssertNil(defaults.object(forKey: LidSleepOverrideService.legacyRecoveryKey), "The legacy flag is never written.")
        XCTAssertFalse(handle.released)
    }

    func testTheWatchdogIsReleasedOnlyAfterAConfirmedZero() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher()
        let service = makeService(system, launcher: launcher)
        await service.setPreferred(true)
        let handle = try XCTUnwrap(launcher.handles.first)
        system.ruleWorks = false                               // the restore fails
        await service.restore(userInitiated: false, sleepIfLidClosed: false)
        XCTAssertTrue(service.needsRecovery)
        XCTAssertFalse(handle.released, "A failed restore keeps the pipe open: the watchdog acts if the app ends now.")
        XCTAssertTrue(store.read().isPresent)
        let quit = await service.prepareForTermination()
        XCTAssertFalse(quit)
        XCTAssertFalse(handle.released)
        system.ruleWorks = true
        let retried = await service.prepareForTermination()
        XCTAssertTrue(retried)
        XCTAssertTrue(handle.released)
        XCTAssertEqual(store.read(), .absent)
    }

    func testASpawnFailureRefusesTheOverride() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher(); launcher.fails = true
        let service = makeService(system, launcher: launcher)
        await service.setPreferred(true)
        XCTAssertFalse(service.isOn)
        XCTAssertNotNil(service.failure)
        XCTAssertFalse(system.calls.contains("set true"), "No watchdog, no override.")
        XCTAssertEqual(store.read(), .absent)
        XCTAssertFalse(system.sleepDisabled)
    }

    func testAMarkerFailureRefusesTheOverrideAndLetsTheWatchdogGo() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher()
        let service = makeService(system, launcher: launcher)
        try FileManager.default.createDirectory(at: store.markerURL, withIntermediateDirectories: true)   // nothing can be renamed there
        await service.setPreferred(true)
        XCTAssertFalse(service.isOn)
        XCTAssertEqual(service.failure, L10n.text("The lid mode could not start safely."))
        XCTAssertFalse(system.calls.contains("set true"), "No marker, no override.")
        XCTAssertEqual(launcher.handles.count, 1)
        XCTAssertTrue(launcher.handles[0].released)
    }

    func testAnEnableRefusesWhileTheLockStaysTaken() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher()
        let held = try XCTUnwrap(store.tryLock())             // a watchdog of an ended run is acting
        defer { held.unlock() }
        let service = makeService(system, launcher: launcher, enableLockTimeout: .milliseconds(100))
        await service.setPreferred(true)
        XCTAssertFalse(service.isOn)
        XCTAssertNotNil(service.failure)
        XCTAssertTrue(launcher.handles.isEmpty)
        XCTAssertFalse(system.calls.contains("set true"))
    }

    func testEverySessionGetsANewTokenAndTheOldWatchdogIsReleased() async throws {
        let system = FakeLidSystem(), launcher = FakeWatchdogLauncher()
        let service = makeService(system, launcher: launcher)
        await service.setPreferred(true)
        await service.setPreferred(false)
        await service.setPreferred(true)
        XCTAssertEqual(launcher.handles.count, 2)
        let (first, second) = (launcher.handles[0], launcher.handles[1])
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertTrue(first.released)
        XCTAssertFalse(second.released)
        guard case .marker(let marker) = store.read() else { return XCTFail("The running session has a marker.") }
        XCTAssertEqual(marker.token, second.token)
    }

    func testLaunchRecoveryRemovesAMarkerOfAnEndedRunOnceSleepIsNormal() async throws {
        try store.write(marker())                              // left by a run that crashed; its watchdog restored
        let system = FakeLidSystem(); system.sleepDisabled = false
        let service = makeService(system, launcher: FakeWatchdogLauncher())
        XCTAssertTrue(service.needsRecovery)
        await service.recoverIfNeeded()
        XCTAssertFalse(service.needsRecovery)
        XCTAssertEqual(store.read(), .absent)
        XCTAssertFalse(system.calls.contains { $0.hasPrefix("set") })
    }

    func testLaunchRecoveryRestoresWhatTheWatchdogCouldNot() async throws {
        try store.write(marker())
        let system = FakeLidSystem(); system.sleepDisabled = true
        let service = makeService(system, launcher: FakeWatchdogLauncher())
        await service.recoverIfNeeded()
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertFalse(service.needsRecovery)
        XCTAssertEqual(store.read(), .absent)
        XCTAssertFalse(system.calls.contains("set true"))
        XCTAssertFalse(system.calls.contains("authorized restore"), "Launch never prompts.")
    }

    func testTheLegacyFlagMigratesToTheFileMarkerRules() async throws {
        defaults.set(true, forKey: LidSleepOverrideService.legacyRecoveryKey)
        let system = FakeLidSystem(); system.sleepDisabled = true
        let service = makeService(system, launcher: FakeWatchdogLauncher())
        XCTAssertTrue(service.needsRecovery, "The old flag still counts as a marker of unknown owner.")
        XCTAssertTrue(service.markerPresent)
        await service.recoverIfNeeded()
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertNil(defaults.object(forKey: LidSleepOverrideService.legacyRecoveryKey))
        XCTAssertFalse(service.markerPresent)
    }

    // MARK: The in-app warning

    func testSleepDisabledWithoutASessionShowsTheWarningAndRestoreClearsIt() async throws {
        let system = FakeLidSystem(); system.sleepDisabled = true      // an ended run, or another tool
        let service = makeService(system, launcher: FakeWatchdogLauncher(), awake: false)
        await service.recoverIfNeeded()                                 // launch, no marker
        XCTAssertTrue(service.systemSleepDisabled)
        XCTAssertFalse(system.calls.contains { $0.hasPrefix("set") }, "Showing the warning writes nothing.")
        await service.restoreSleep()                                    // the user's "Restore sleep"
        XCTAssertFalse(system.sleepDisabled)
        XCTAssertFalse(service.systemSleepDisabled)
        XCTAssertFalse(system.calls.contains("authorized restore"), "The passwordless path is enough when it works.")
    }

    func testTheWarningRestoreMayPromptOnlyBecauseTheUserAsked() async throws {
        let system = FakeLidSystem(); system.sleepDisabled = true; system.ruleWorks = false
        let service = makeService(system, launcher: FakeWatchdogLauncher(), awake: false)
        await service.checkSystemSleep()
        XCTAssertTrue(service.systemSleepDisabled)
        XCTAssertFalse(system.calls.contains("authorized restore"))
        await service.restoreSleep()
        XCTAssertTrue(system.calls.contains("authorized restore"))
        XCTAssertFalse(service.systemSleepDisabled)
    }

    func testNoWarningForTheOwnSessionOrWhereTheSystemIsNotObserved() async throws {
        let system = FakeLidSystem()
        let service = makeService(system, launcher: FakeWatchdogLauncher())
        await service.setPreferred(true)
        XCTAssertTrue(system.sleepDisabled)
        await service.checkSystemSleep()
        XCTAssertFalse(service.systemSleepDisabled, "SleepDisabled 1 is expected while the own session runs.")

        let other = FakeLidSystem(); other.sleepDisabled = true
        let elsewhere = LidOverrideMarkerStore(directory: directory.appendingPathComponent("other", isDirectory: true))
        let unobserved = LidSleepOverrideService(system: other, defaults: defaults, allowed: true, markers: elsewhere,
                                                 watchdog: FakeWatchdogLauncher(), observesSystemSleep: false)
        XCTAssertFalse(unobserved.needsRecovery)
        await unobserved.checkSystemSleep()
        XCTAssertFalse(unobserved.systemSleepDisabled)
        XCTAssertTrue(other.calls.isEmpty)
        let demo = LidSleepOverrideService(system: other, defaults: defaults, allowed: false, markers: elsewhere, watchdog: FakeWatchdogLauncher())
        await demo.checkSystemSleep()
        XCTAssertTrue(other.calls.isEmpty, "Demo and monitoring-only runs never read for the warning.")
    }
}
