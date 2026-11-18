// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
import OSLog
import PowerCore

// The closed-lid "lifeline watchdog". `pmset disablesleep 1` is system-wide and survives the app, so every override
// session starts a child copy of the app executable (`--lid-watchdog <token> <markerDir>`) whose stdin is a pipe the
// app holds. A confirmed restore sends one release byte; a crash, a force quit or a kill closes the pipe instead, and
// the child (in its own session, deaf to HUP/TERM/INT/PIPE) puts normal sleep back if, and only if, the marker on
// disk still carries its token. The child can read the state, clear it, request sleep and restore the lid-close
// comfort journal; it has no way to disable sleep.

// MARK: - App side

/// The app's end of one watchdog's pipe.
protocol LidWatchdogHandle: AnyObject, Sendable {
    /// Only after a confirmed `SleepDisabled 0`: sends the release byte and closes the pipe (idempotent).
    func release()
}

protocol LidWatchdogLaunching: Sendable {
    /// Starts the watchdog for one override session and waits until it reports that it is watching; nil when it could
    /// not be started, and then the override must not start either.
    func launch(token: String, markerDirectory: URL) async -> (any LidWatchdogHandle)?
}

/// Demo, monitoring-only and first-run preview launches, and models built around a fake lid system: nothing is
/// spawned (none of them can write the real setting).
struct InertLidWatchdogLauncher: LidWatchdogLaunching {
    final class Handle: LidWatchdogHandle { func release() {} }
    func launch(token: String, markerDirectory: URL) async -> (any LidWatchdogHandle)? { Handle() }
}

/// The default for anything that did not choose a launcher: refuses, so an override can never start unguarded.
struct UnavailableLidWatchdogLauncher: LidWatchdogLaunching {
    func launch(token: String, markerDirectory: URL) async -> (any LidWatchdogHandle)? { nil }
}

/// Spawns the app's own executable. Only from a real `.app` bundle: a test runner or a bare SwiftPM executable is
/// never re-launched as a watchdog (the override is then refused).
struct NativeLidWatchdogLauncher: LidWatchdogLaunching {
    /// How long the child has to report that it is watching (normally well under a second).
    static let readyTimeout: TimeInterval = 3

    func launch(token: String, markerDirectory: URL) async -> (any LidWatchdogHandle)? {
        guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        var lifeline: [Int32] = [-1, -1], ready: [Int32] = [-1, -1]
        guard pipe(&lifeline) == 0 else { return nil }
        guard pipe(&ready) == 0 else { close(lifeline[0]); close(lifeline[1]); return nil }
        let (readEnd, writeEnd, readyRead, readyWrite) = (lifeline[0], lifeline[1], ready[0], ready[1])
        func closeAll() { for fd in [readEnd, writeEnd, readyRead, readyWrite] { close(fd) } }
        // The app's ends are never inherited by later children (pmset, sudo, another watchdog), which would hold the
        // pipe open after the app is gone; and a write to a watchdog that already exited must not raise SIGPIPE.
        guard [readEnd, writeEnd, readyRead, readyWrite].allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
              fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0 else { closeAll(); return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = LidWatchdog.arguments(token: token, markerDirectory: markerDirectory)
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        // dup2 onto the child's stdin/stdout clears close-on-exec there; the parent's copies are closed after the spawn.
        process.standardInput = FileHandle(fileDescriptor: readEnd, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: readyWrite, closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice
        let handle = NativeLidWatchdogHandle(writeEnd: writeEnd, process: process)
        process.terminationHandler = { [weak handle] _ in if let handle { NativeLidWatchdogHandle.forget(handle) } }
        do { try process.run() } catch { closeAll(); return nil }
        close(readEnd); close(readyWrite)
        NativeLidWatchdogHandle.remember(handle)
        // The child confirms that it took the watchdog branch and is waiting on the pipe. Anything else (it crashed,
        // or it started as something other than a watchdog) is stopped and the override is refused.
        let confirmed = await LidWatchdog.waitForReady(fd: readyRead, timeout: Self.readyTimeout)
        close(readyRead)
        guard confirmed else {
            kill(process.processIdentifier, SIGKILL)
            handle.discard()
            return nil
        }
        return handle
    }
}

/// Kept alive (with its `Process`) until the child exits, so a dropped reference never closes the pipe by accident:
/// only `release()` or the end of the app does.
final class NativeLidWatchdogHandle: LidWatchdogHandle, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: NativeLidWatchdogHandle] = [:]
    static func remember(_ handle: NativeLidWatchdogHandle) { registryLock.withLock { registry[ObjectIdentifier(handle)] = handle } }
    static func forget(_ handle: NativeLidWatchdogHandle) { registryLock.withLock { registry[ObjectIdentifier(handle)] = nil } }

    private let lock = NSLock()
    private var writeEnd: Int32
    private let process: Process
    init(writeEnd: Int32, process: Process) { self.writeEnd = writeEnd; self.process = process }

    func release() {
        lock.withLock {
            guard writeEnd >= 0 else { return }
            var byte = LidWatchdog.releaseByte
            _ = Darwin.write(writeEnd, &byte, 1)   // EPIPE if the watchdog is already gone: harmless (no SIGPIPE)
            close(writeEnd); writeEnd = -1
        }
    }

    /// A watchdog that never confirmed: its pipe is closed without a release (it was killed already).
    func discard() {
        lock.withLock {
            guard writeEnd >= 0 else { return }
            close(writeEnd); writeEnd = -1
        }
    }
}

// MARK: - Watchdog side

/// Everything the watchdog may do to the system. There is deliberately no way to disable sleep here.
protocol LidWatchdogSystem: Sendable {
    /// `pmset -g` `SleepDisabled`; nil when it cannot be read.
    func readSleepDisabled() async -> Bool?
    /// `sudo -n /usr/bin/pmset disablesleep 0`.
    func clearSleepDisabled() async -> Bool
    /// Lid closed AND macOS would sleep because of it.
    func lidClosedWouldSleep() -> Bool
    func requestSleep() -> Bool
    /// Best effort: the lid-close comfort journal (brightness, volume) is put back.
    func restoreComfort() async
}

struct NativeLidWatchdogSystem: LidWatchdogSystem {
    func readSleepDisabled() async -> Bool? { await LidSleepCommands.readSleepDisabled() }
    func clearSleepDisabled() async -> Bool { await LidSleepCommands.clearSleepDisabled() }
    func lidClosedWouldSleep() -> Bool { LidSleepCommands.lidClosedWouldSleep() }
    func requestSleep() -> Bool { LidSleepCommands.requestSleep() }
    /// The app's own journal and restore rules (`LidComfortService`), with the native transports; the app's
    /// preferences domain is the same because the watchdog is the same bundle.
    func restoreComfort() async { await LidComfortService.recoverForWatchdog() }
}

enum LidWatchdog {
    static let argument = "--lid-watchdog"
    static let releaseByte: UInt8 = 0x52   // "R"
    /// Written once to stdout when the child is set up and about to wait on the pipe.
    static let readyByte: UInt8 = 0x4B     // "K"

    struct Invocation: Equatable, Sendable {
        let token: String
        let markerDirectory: URL
    }

    struct Timing: Sendable {
        /// How long the act step waits for the lock (a live Tilvero holding it longer owns the recovery itself).
        var lockTimeout: TimeInterval = 60
        var comfortTimeout: Duration = .seconds(3)
        var clearRetryDelay: Duration = .milliseconds(500)
        var sleepAttempts = 10
        var sleepRetryDelay: Duration = .milliseconds(500)
        static let live = Timing()
    }

    enum Outcome: Equatable, Sendable {
        /// The app released the watchdog after a confirmed restore.
        case released
        /// The pipe failed without a clean end: nothing is done (the app may still be alive).
        case pipeFailed
        /// No marker, or another session's: someone else restored or owns the override.
        case notOwner
        /// Sleep was already normal: the marker was removed.
        case alreadyNormal
        /// `disablesleep 0` was confirmed: the marker was removed.
        case restored
        /// Still disabled after the bounded attempts: the marker stays for launch recovery and the in-app warning.
        case gaveUp
        /// The lock stayed taken: a live Tilvero is working on it, the marker stays.
        case lockUnavailable
    }

    static func arguments(token: String, markerDirectory: URL) -> [String] {
        [argument, token, markerDirectory.path]
    }

    /// Exactly `[executable, "--lid-watchdog", <UUID>, <absolute directory>]`; anything else is not a watchdog launch.
    static func invocation(arguments: [String]) -> Invocation? {
        guard arguments.count == 4, arguments[1] == argument, UUID(uuidString: arguments[2]) != nil,
              arguments[3].hasPrefix("/") else { return nil }
        return Invocation(token: arguments[2], markerDirectory: URL(fileURLWithPath: arguments[3], isDirectory: true))
    }

    /// From `TilveroMain.main`, before anything else (no NSApplication, no model). Never returns.
    static func runAndExit(_ invocation: Invocation) -> Never {
        _ = setsid()
        for number in [SIGHUP, SIGTERM, SIGINT, SIGPIPE] { signal(number, SIG_IGN) }
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? ReleaseIdentity.prototypeBundleIdentifier, category: "LidWatchdog")
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else {
            log.error("Lid watchdog: stdin is not a pipe; exiting without action.")
            exit(65)
        }
        // Tell the app it is watching, then let go of the ready pipe (stdout goes to /dev/null from here on).
        var ready = readyByte
        _ = write(STDOUT_FILENO, &ready, 1)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { _ = dup2(null, STDOUT_FILENO); close(null) }
        let received = waitForSignal(fd: STDIN_FILENO)
        guard received == .endOfFile else {
            if received == .pipeFailed { log.error("Lid watchdog: the pipe failed; exiting without action.") }
            exit(0)
        }
        // A hard ceiling: the watchdog never lingers, whatever a command does.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { exit(3) }
        let store = LidOverrideMarkerStore(directory: invocation.markerDirectory)
        let token = invocation.token
        Task.detached(priority: .userInitiated) {
            let outcome = await act(signal: received, token: token, store: store, system: NativeLidWatchdogSystem())
            log.notice("Lid watchdog finished: \(String(describing: outcome), privacy: .public)")
            exit(outcome == .gaveUp || outcome == .lockUnavailable ? 2 : 0)
        }
        dispatchMain()   // the main queue serves the comfort restore (main actor)
    }

    /// Blocks on `fd` until the release byte (other bytes are ignored), the end of the pipe, or a read error.
    static func waitForSignal(fd: Int32) -> LidWatchdogSignal {
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == releaseByte { return .released }
                continue
            }
            if count == 0 { return .endOfFile }
            if errno == EINTR { continue }
            return .pipeFailed
        }
    }

    /// The app's side of the start handshake: true only when the ready byte arrives within `timeout`.
    static func waitForReady(fd: Int32, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeout)
                var byte: UInt8 = 0
                while true {
                    let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                    var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let polled = poll(&entry, 1, remaining)
                    if polled < 0, errno == EINTR { continue }
                    guard polled > 0 else { return continuation.resume(returning: false) }
                    let count = read(fd, &byte, 1)
                    if count < 0, errno == EINTR { continue }
                    return continuation.resume(returning: count == 1 && byte == readyByte)
                }
            }
        }
    }

    /// The same wait without blocking the caller's thread (tests).
    static func watch(fd: Int32) async -> LidWatchdogSignal {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: waitForSignal(fd: fd)) }
        }
    }

    /// The act step: the decision table of `LidWatchdogPolicy`, under the marker lock.
    static func act(signal: LidWatchdogSignal, token: String, store: LidOverrideMarkerStore,
                    system: any LidWatchdogSystem, timing: Timing = .live) async -> Outcome {
        switch signal {
        case .released: return .released
        case .pipeFailed: return .pipeFailed
        case .endOfFile: break
        }
        // An absent or foreign marker needs nothing, and no wait for the lock either.
        guard store.read().ownership(of: token) == .own else { return .notOwner }
        guard let lock = await lock(store, timeout: timing.lockTimeout) else { return .lockUnavailable }
        var attempts = 0
        var comfortRestored = false
        while true {
            let ownership = store.read().ownership(of: token)
            let reading: Bool? = ownership == .own ? await system.readSleepDisabled() : nil
            switch LidWatchdogPolicy.decide(signal: .endOfFile, marker: ownership, sleepDisabled: reading, clearAttempts: attempts) {
            case .exit:
                lock.unlock(); return .notOwner
            case .giveUp:
                lock.unlock(); return .gaveUp
            case .clear(let restoreComfortFirst):
                if restoreComfortFirst {
                    await bounded(timing.comfortTimeout) { await system.restoreComfort() }
                    comfortRestored = true
                } else {
                    try? await Task.sleep(for: timing.clearRetryDelay)
                }
                _ = await system.clearSleepDisabled()
                attempts += 1
            case .finish:
                store.deleteIfOwned(by: token)
                lock.unlock()
                // A lid that closed during the session is not evaluated again by macOS: ask for the sleep it would have
                // caused, after the screen and the sound are back.
                if system.lidClosedWouldSleep() {
                    if !comfortRestored { await bounded(timing.comfortTimeout) { await system.restoreComfort() } }
                    await requestSleep(system, timing: timing)
                }
                return attempts == 0 ? .alreadyNormal : .restored
            }
        }
    }

    /// macOS refuses briefly while the cleared flag propagates, hence the bounded retries (as in the app).
    private static func requestSleep(_ system: any LidWatchdogSystem, timing: Timing) async {
        for _ in 0..<timing.sleepAttempts {
            guard system.lidClosedWouldSleep() else { return }
            if system.requestSleep() { return }
            try? await Task.sleep(for: timing.sleepRetryDelay)
        }
    }

    private static func lock(_ store: LidOverrideMarkerStore, timeout: TimeInterval) async -> LidOverrideLock? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: store.lock(timeout: timeout)) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    /// Waits for `operation` at most `timeout`; the operation may keep running after that (best effort).
    static func bounded(_ timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            Task { await operation(); if once.take() { continuation.resume() } }
            Task { try? await Task.sleep(for: timeout); if once.take() { continuation.resume() } }
        }
    }

    // MARK: Process identification

    /// A watchdog runs the app's own executable: a new app instance must not mistake it for a running copy.
    static func isWatchdogProcess(pid: pid_t) -> Bool {
        guard let arguments = processArguments(pid: pid) else { return false }
        return arguments.count >= 2 && arguments[1] == argument
    }

    static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`: argc (Int32), the executable path, NUL padding, then argc NUL-terminated arguments.
    static func parseProcessArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
