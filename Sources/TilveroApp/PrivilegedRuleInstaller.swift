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

/// Pure builder of the merged rule and the one shell script run under the administrator prompt.
enum SudoersRules {
    static let mergedPath = "/etc/sudoers.d/tilvero"
    /// sudo ignores names containing a dot, so the unvalidated file is never live.
    static let mergedTempPath = "/etc/sudoers.d/tilvero.tmp"
    /// Which features the merged file was written with (it is root-only readable, so the app keeps its own record).
    static let mergedFeaturesKey = "privilegedRules.merged.v1"
    static var allPaths: [String] { [mergedPath] + PrivilegedFeature.allCases.map(\.legacyPath) }

    /// One uid-bound line, features in a fixed order; nil for an empty selection.
    static func rule(uid: uid_t, features: Set<PrivilegedFeature>) -> String? {
        guard !features.isEmpty else { return nil }
        return "#\(uid) ALL=(root) NOPASSWD: " + features.sorted().flatMap(\.commands).joined(separator: ", ")
    }

    /// Write to the temporary name, validate with `visudo -c`, move into place, and only then remove the old
    /// one-feature files of the features now covered. Any failure removes the temporary file and leaves the old
    /// files untouched.
    static func installScript(uid: uid_t, features: Set<PrivilegedFeature>) -> String? {
        guard let rule = rule(uid: uid, features: features) else { return nil }
        let removeOld = features.sorted().map { "rm -f \($0.legacyPath)" }.joined(separator: " && ")
        return "mkdir -p /etc/sudoers.d && echo '\(rule)' > \(mergedTempPath) && chmod 0440 \(mergedTempPath)"
            + " && /usr/sbin/visudo -c -f \(mergedTempPath) && mv -f \(mergedTempPath) \(mergedPath) && \(removeOld)"
            + " || { rm -f \(mergedTempPath); exit 1; }"
    }

    /// Takes one feature out: its old file goes, and the merged file is rewritten (validated) with what remains, or
    /// removed when nothing remains.
    static func removalScript(uid: uid_t, removing feature: PrivilegedFeature, merged: Set<PrivilegedFeature>) -> String {
        let remaining = merged.subtracting([feature])
        let dropOld = "rm -f \(feature.legacyPath)"
        guard merged.contains(feature) else { return dropOld }
        guard let rule = rule(uid: uid, features: remaining) else { return "\(dropOld) && rm -f \(mergedPath)" }
        return "\(dropOld) && echo '\(rule)' > \(mergedTempPath) && chmod 0440 \(mergedTempPath)"
            + " && /usr/sbin/visudo -c -f \(mergedTempPath) && mv -f \(mergedTempPath) \(mergedPath)"
            + " || { rm -f \(mergedTempPath); exit 1; }"
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func appleScriptSource(script: String, prompt: String) -> String {
        "do shell script \(appleScriptLiteral(script)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"
    }
}

/// "Permission present": the old per-feature file OR the merged file written with that feature.
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
        // The dialog attaches to the requesting process; an inactive menu bar app would open it behind other windows.
        await MainActor.run { NSApplication.shared.activate() }
        let result = await AdministratorProcess.run("/usr/bin/osascript", ["-e", SudoersRules.appleScriptSource(script: script, prompt: prompt)])
        if result.status == 0 { return .succeeded }
        // osascript reports "User canceled. (-128)" when the prompt is dismissed; a cancelled task terminated it.
        return result.output.contains("-128") || Task.isCancelled ? .cancelled : .failed
    }
}

private enum AdministratorProcess {
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var done = false; var process: Process?
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 600) async -> (status: Int32, output: String) {
        let box = Box()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
                box.process = process
                process.terminationHandler = { finished in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if box.take() { continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self))) }
                }
                do { try process.run() } catch { if box.take() { continuation.resume(returning: (-1, "")) }; return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    process.terminate()
                    if box.take() { continuation.resume(returning: (-2, "")) }
                }
            }
        } onCancel: {
            box.process?.terminate()
            _ = box.take()
        }
    }
}

enum PrivilegedInstallOutcome: Equatable { case granted(Set<PrivilegedFeature>), cancelled, failed }

/// One administrator prompt for every chosen feature. The rule keeps the features recorded earlier, so a later
/// request never drops a line that already works.
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
        guard !requested.isEmpty else { return .granted([]) }
        let mergedBefore = fileExists(SudoersRules.mergedPath)
        let recorded = mergedBefore ? PrivilegedRulePresence.recordedMergedFeatures(defaults) : []
        let features = requested.union(recorded)
        guard let script = SudoersRules.installScript(uid: uid, features: features) else { return .failed }
        let outcome = await executor.run(script: script, prompt: Self.prompt(for: features))
        // A prompt cancelled after the script already moved a fresh file into place still installed it.
        if outcome != .succeeded, !mergedBefore, fileExists(SudoersRules.mergedPath) {
            PrivilegedRulePresence.record(features, in: defaults)
            return .granted(features)
        }
        switch outcome {
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .succeeded:
            // Only a file that is really in place counts.
            guard fileExists(SudoersRules.mergedPath) else { return .failed }
            PrivilegedRulePresence.record(features, in: defaults)
            return .granted(features)
        }
    }
}
