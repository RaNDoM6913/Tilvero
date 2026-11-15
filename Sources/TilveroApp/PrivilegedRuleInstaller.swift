// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Darwin

/// Features whose passwordless rule needs one administrator prompt. Nothing else may ever be added to the rule file:
/// each feature maps to exactly the narrow `pmset` commands its service already runs through `sudo -n`.
enum PrivilegedFeature: String, CaseIterable, Comparable, Sendable {
    case lidClosed, chargeByTime
    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// Exactly the commands of the per-feature rules (`NativeLidSleepSystem.rule`, `NativeWakeScheduler.rule`).
    var commands: [String] {
        switch self {
        case .lidClosed: ["/usr/bin/pmset disablesleep 1", "/usr/bin/pmset disablesleep 0"]
        case .chargeByTime: ["/usr/bin/pmset schedule wake *", "/usr/bin/pmset schedule cancel wake *"]
        }
    }
    /// The older one-feature rule file.
    var legacyPath: String {
        switch self {
        case .lidClosed: "/etc/sudoers.d/tilvero-lid"
        case .chargeByTime: "/etc/sudoers.d/tilvero-wake"
        }
    }
}


/// Pure builder of the rule lines and the one shell script run under the administrator prompt.
///
/// The merged file holds one line per feature. The app cannot read it (root-only), so it never rewrites the file from
/// its own memory: every script runs as root, copies the existing file minus exactly the lines it replaces or
/// removes, and keeps everything else it cannot account for (another feature, another copy's line). A removed
/// feature's line is always taken out, whatever the app remembers.
enum SudoersRules {
    static let mergedPath = "/etc/sudoers.d/tilvero"
    /// `mktemp` template: a unique name per run; sudo ignores names containing a dot, so an unvalidated file is never live.
    static let tempTemplate = "/etc/sudoers.d/tilvero.XXXXXX"
    /// A hint of which features the app wrote into the merged file (used only to report "permission present").
    static let mergedFeaturesKey = "privilegedRules.merged.v1"
    static var allPaths: [String] { [mergedPath] + PrivilegedFeature.allCases.map(\.legacyPath) }

    /// One uid-bound line for one feature: exactly the per-feature rule of its service.
    static func rule(uid: uid_t, feature: PrivilegedFeature) -> String {
        "#\(uid) ALL=(root) NOPASSWD: " + feature.commands.joined(separator: ", ")
    }
    static func rules(uid: uid_t, features: Set<PrivilegedFeature>) -> [String] {
        features.sorted().map { rule(uid: uid, feature: $0) }
    }

    /// Existing file minus `lines` (exact whole-line matches), into `$T`; nothing when there is no file.
    private static func copyExisting(without lines: [String]) -> String {
        let patterns = lines.map { "-e '\($0)'" }.joined(separator: " ")
        return "{ [ ! -f \(mergedPath) ] || grep -v -x -F \(patterns) \(mergedPath) || true; } > \"$T\""
    }

    /// Copy the existing file without the requested lines, append them, validate with `visudo -c`, move into place,
    /// and only then remove the old one-feature files of the requested features. Any failure removes the temporary
    /// file and leaves the installed files untouched.
    static func installScript(uid: uid_t, features: Set<PrivilegedFeature>) -> String? {
        let lines = rules(uid: uid, features: features)
        guard !lines.isEmpty else { return nil }
        let removeOld = features.sorted().map { "rm -f \($0.legacyPath)" }.joined(separator: " && ")
        return "mkdir -p /etc/sudoers.d && T=$(mktemp \(tempTemplate)) && \(copyExisting(without: lines))"
            + " && printf '%s\\n' \(lines.map { "'\($0)'" }.joined(separator: " ")) >> \"$T\""
            + " && chmod 0440 \"$T\" && /usr/sbin/visudo -c -f \"$T\" && mv -f \"$T\" \(mergedPath) && \(removeOld)"
            + " || { rm -f \"$T\"; exit 1; }"
    }

    /// Takes one feature out, always: its old file goes and its line is removed from the merged file, which is
    /// rewritten (validated) with every other line, or deleted when nothing remains.
    static func removalScript(uid: uid_t, removing feature: PrivilegedFeature) -> String {
        "rm -f \(feature.legacyPath) && T=$(mktemp \(tempTemplate)) && \(copyExisting(without: [rule(uid: uid, feature: feature)]))"
            + " && if [ -s \"$T\" ]; then chmod 0440 \"$T\" && /usr/sbin/visudo -c -f \"$T\" && mv -f \"$T\" \(mergedPath);"
            + " else rm -f \"$T\" \(mergedPath); fi || { rm -f \"$T\"; exit 1; }"
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func appleScriptSource(script: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(script)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
    }
}

/// "Permission present": the old per-feature file OR the merged file written with that feature. A lost record only
/// makes a feature look absent, which leads to asking again (the script keeps or replaces its line), never to a
/// missing line being reported as present.
enum PrivilegedRulePresence {
    static func recordedMergedFeatures(_ defaults: UserDefaults) -> Set<PrivilegedFeature> {
        Set((defaults.stringArray(forKey: SudoersRules.mergedFeaturesKey) ?? []).compactMap(PrivilegedFeature.init(rawValue:)))
    }
    static func record(_ features: Set<PrivilegedFeature>, in defaults: UserDefaults) {
        if features.isEmpty { defaults.removeObject(forKey: SudoersRules.mergedFeaturesKey) }
        else { defaults.set(features.sorted().map(\.rawValue), forKey: SudoersRules.mergedFeaturesKey) }
    }
    static func isPresent(_ feature: PrivilegedFeature, fileExists: (String) -> Bool, merged: Set<PrivilegedFeature>) -> Bool {
        fileExists(feature.legacyPath) || (fileExists(SudoersRules.mergedPath) && merged.contains(feature))
    }
    static func isPresent(_ feature: PrivilegedFeature, defaults: UserDefaults = .standard) -> Bool {
        isPresent(feature, fileExists: { FileManager.default.fileExists(atPath: $0) }, merged: recordedMergedFeatures(defaults))
    }
}

enum AdministratorScriptOutcome: Equatable, Sendable { case succeeded, cancelled, failed }

/// The only way the shared installer runs anything as root. Tests and the preview inject fakes.
protocol AdministratorScriptExecuting: Sendable {
    func run(script: String, prompt: String) async -> AdministratorScriptOutcome
}

/// The existing mechanism: `osascript` `do shell script … with administrator privileges`. macOS shows its own prompt
/// (Touch ID or password); the app never sees a password. Cancelling the calling task dismisses the prompt.
struct OsascriptAdministratorExecutor: AdministratorScriptExecuting {
    func run(script: String, prompt: String) async -> AdministratorScriptOutcome {
        guard !Task.isCancelled else { return .cancelled }
        // The dialog attaches to the requesting process; an inactive menu bar app would open it behind other windows.
        await MainActor.run { NSApplication.shared.activate() }
        let result = await CancellableProcessRun.run(launch: CancellableProcessRun.process("/usr/bin/osascript",
            ["-e", SudoersRules.appleScriptSource(script: script, prompt: prompt)]))
        return Self.outcome(status: result.status, output: result.output, cancelled: Task.isCancelled)
    }
    /// osascript reports "User canceled. (-128)" when the prompt is dismissed; a cancelled task terminated it.
    static func outcome(status: Int32, output: String, cancelled: Bool) -> AdministratorScriptOutcome {
        if status == 0 && !cancelled { return .succeeded }
        return output.contains("-128") || cancelled || status == CancellableProcessRun.cancelledBeforeStart ? .cancelled : .failed
    }
}

/// Runs one process whose continuation resumes exactly once: on exit, on a launch failure, on the timeout, or
/// immediately when the task was cancelled before the launch (then nothing is launched). Cancelling a running
/// process terminates it and the result arrives through its normal exit.
enum CancellableProcessRun {
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

    static func run(launch: Launch, timeout: TimeInterval = 600) async -> (status: Int32, output: String) {
        let state = State()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation), !Task.isCancelled else {
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
        } onCancel: {
            state.cancel()   // only terminates; the exit (or the pre-launch guard) resumes the continuation
        }
    }

    static func process(_ path: String, _ arguments: [String]) -> Launch {
        { finished in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
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

enum PrivilegedInstallOutcome: Equatable { case granted(Set<PrivilegedFeature>), cancelled, failed }

/// One administrator prompt for every chosen feature. The script keeps every other line of the merged file, so a
/// request never drops a feature the app does not know about.
@MainActor final class PrivilegedRuleInstaller {
    private let executor: any AdministratorScriptExecuting
    private let defaults: UserDefaults
    private let uid: uid_t
    private let fileExists: (String) -> Bool

    init(executor: any AdministratorScriptExecuting, defaults: UserDefaults, uid: uid_t = getuid(),
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.executor = executor; self.defaults = defaults; self.uid = uid; self.fileExists = fileExists
    }

    static func prompt(for features: Set<PrivilegedFeature>) -> String {
        L10n.text("Tilvero asks to allow narrow pmset commands without a password for the features you chose.")
    }

    func install(_ requested: Set<PrivilegedFeature>) async -> PrivilegedInstallOutcome {
        guard let script = SudoersRules.installScript(uid: uid, features: requested) else { return .granted([]) }
        let mergedBefore = fileExists(SudoersRules.mergedPath)
        let recorded = mergedBefore ? PrivilegedRulePresence.recordedMergedFeatures(defaults) : []
        let outcome = await executor.run(script: script, prompt: Self.prompt(for: requested))
        // A prompt cancelled after the script already moved a fresh file into place still installed it.
        if outcome != .succeeded, !mergedBefore, fileExists(SudoersRules.mergedPath) {
            PrivilegedRulePresence.record(requested, in: defaults)
            return .granted(requested)
        }
        switch outcome {
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .succeeded:
            // Only a file that is really in place counts.
            guard fileExists(SudoersRules.mergedPath) else { return .failed }
            PrivilegedRulePresence.record(requested.union(recorded), in: defaults)
            return .granted(requested)
        }
    }
}
