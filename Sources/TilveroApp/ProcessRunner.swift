// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// The one runner for short system commands (`pmset`, `sudo -n`, `osascript`): the lid override, the scheduled wake,
/// the shared permission installer and the lid watchdog all use it. The continuation resumes exactly once: on exit, on
/// a launch failure, on the timeout, or (for a cancellable run) immediately when the task was cancelled before the
/// launch, in which case nothing is launched. Cancelling a running cancellable run terminates the process and the
/// result arrives through its normal exit. Every run is an independent process with no shared queue, so a long
/// administrator prompt never delays a `pmset -g` or a restore.
enum ProcessRunner {
    static let cancelledBeforeStart: Int32 = -3
    static let timedOut: Int32 = -2
    static let launchFailed: Int32 = -1

    /// Starts the work; calls `finished` once when it ends; returns how to terminate it.
    typealias Launch = @Sendable (_ finished: @escaping @Sendable (Int32, String) -> Void) throws -> @Sendable () -> Void

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(status: Int32, output: String), Never>?
        private var terminate: (@Sendable () -> Void)?
        private var cancelled = false
        private var finished = false

        func install(_ c: CheckedContinuation<(status: Int32, output: String), Never>) -> Bool {
            lock.withLock { continuation = c; return !cancelled }
        }
        /// Records how to stop the running work; stops it at once if a cancel already arrived.
        func started(_ stop: @escaping @Sendable () -> Void) {
            let stopNow = lock.withLock { () -> Bool in terminate = stop; return cancelled && !finished }
            if stopNow { stop() }
        }
        func cancel() {
            let stop = lock.withLock { () -> (@Sendable () -> Void)? in cancelled = true; return finished ? nil : terminate }
            stop?()
        }
        func finish(_ status: Int32, _ output: String) {
            let c = lock.withLock { () -> CheckedContinuation<(status: Int32, output: String), Never>? in
                guard !finished else { return nil }
                finished = true; defer { continuation = nil }; return continuation
            }
            c?.resume(returning: (status, output))
        }
    }

    /// `terminatesOnCancel: false` is for writes that must not be cut short by the caller's task ending (a `pmset`
    /// restore): the process then always runs to its exit or the timeout.
    static func run(launch: Launch, timeout: TimeInterval = 600, terminatesOnCancel: Bool = true) async -> (status: Int32, output: String) {
        let state = State()
        @Sendable func body() async -> (status: Int32, output: String) {
            await withCheckedContinuation { continuation in
                guard state.install(continuation), !(terminatesOnCancel && Task.isCancelled) else {
                    state.finish(cancelledBeforeStart, ""); return
                }
                do {
                    let stop = try launch { status, output in state.finish(status, output) }
                    state.started(stop)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        stop()
                        state.finish(timedOut, "")
                    }
                } catch {
                    state.finish(launchFailed, "")
                }
            }
        }
        guard terminatesOnCancel else { return await body() }
        return await withTaskCancellationHandler {
            await body()
        } onCancel: {
            state.cancel()   // only terminates; the exit (or the pre-launch guard) resumes the continuation
        }
    }

    /// A short command that is never cut short by task cancellation (15 s by default): `pmset`, `sudo -n pmset`.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) async -> (status: Int32, output: String) {
        await run(launch: process(path, arguments), timeout: timeout, terminatesOnCancel: false)
    }

    /// Absolute executable, `/` as the working directory, no stdin.
    static func process(_ path: String, _ arguments: [String]) -> Launch {
        { finished in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { done in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                finished(done.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            try process.run()
            return { if process.isRunning { process.terminate() } }
        }
    }
}
