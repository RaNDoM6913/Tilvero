// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Darwin

/// Features whose passwordless rule needs one administrator password. Nothing else may ever be added to the rule file:
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

/// What one privileged run does: add the lines of some features, or take them out again (the exact inverse).
enum PrivilegedOperation: Equatable, Sendable {
    case install(Set<PrivilegedFeature>)
    case remove(Set<PrivilegedFeature>)
    var features: Set<PrivilegedFeature> { switch self { case .install(let f), .remove(let f): f } }
    var isRemoval: Bool { if case .remove = self { true } else { false } }
}

/// How the administrator password is asked for. The app never sees it on either route.
enum PermissionRoute: String, Equatable, Sendable {
    /// The macOS authorization dialog (`osascript … with administrator privileges`): Touch ID or password.
    case systemPrompt
    /// A prepared `.command` file opened in Terminal: `sudo` asks for the password there.
    case terminal
}

/// Result of one privileged run. `succeeded` carries the features that were added (install) or taken out (removal).
enum PrivilegedOutcome: Hashable, Sendable {
    case succeeded(Set<PrivilegedFeature>)
    case cancelled
    /// The script or the prompt failed; the code is the script's exit status when it is known (see `SudoersRules`).
    case failed(Int32?)
    /// Terminal route only: nothing finished within the waiting time.
    case timedOut
}

/// Pure builder of the rule lines and of the one shell script that runs as root.
///
/// The merged file holds one uid-bound line per feature. The app cannot read it (root-only), so it never rewrites the
/// file from memory: the root script copies the existing file minus exactly the lines it replaces or removes and keeps
/// everything else (another feature, another user's line, a line it cannot account for). Every command is an
/// absolute path, `PATH` and the locale are fixed, the temporary file is created by `mktemp` inside the root-owned
/// `/etc/sudoers.d` (no other user can create, swap or follow a link there) under a dotted name that sudo ignores,
/// it is validated by `visudo -c` and only then renamed into place.
///
/// Exit codes: 2 the folder cannot be created, 3 a rule path is a link or not a regular file, 4 no temporary file,
/// 5 copying failed, 6 owner/mode failed, 7 `visudo` rejected the file, 8 move/delete failed.
enum SudoersRules {
    static let directory = "/etc/sudoers.d"
    static let mergedPath = "/etc/sudoers.d/tilvero"
    /// A hint of which features the app wrote into the merged file (used only to report "permission present").
    static let mergedFeaturesKey = "privilegedRules.merged.v1"
    static var allPaths: [String] { [mergedPath] + PrivilegedFeature.allCases.map(\.legacyPath) }

    /// One uid-bound line for one feature: exactly the per-feature rule of its service. A uid is bare digits that
    /// neither sudoers nor the shell can read as anything else; the lines contain no single quote.
    static func rule(uid: uid_t, feature: PrivilegedFeature) -> String {
        "#\(uid) ALL=(root) NOPASSWD: " + feature.commands.joined(separator: ", ")
    }
    static func rules(uid: uid_t, features: Set<PrivilegedFeature>) -> [String] {
        features.sorted().map { rule(uid: uid, feature: $0) }
    }

    private static func patterns(_ lines: [String]) -> String { lines.map { "-e '\($0)'" }.joined(separator: " ") }

    private static func preamble(uid: uid_t, removal: Bool) -> [String] {
        [
            "# Tilvero: \(removal ? "remove the" : "add the") passwordless pmset rule of user #\(uid)",
            "cd / || exit 1",
            "umask 077",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "export PATH",
            "LC_ALL=C",
            "export LC_ALL",
            "D=\(directory)",
            "F=\(mergedPath)",
            "T=",
            "trap '[ -z \"$T\" ] || /bin/rm -f \"$T\"' EXIT",
            "# keep_others FILE -e LINE...: rewrite FILE without exactly these lines (validated), delete it when nothing is left",
            "keep_others() {",
            "  f=$1",
            "  shift",
            "  [ ! -L \"$f\" ] || return 3",
            "  [ -e \"$f\" ] || return 0",
            "  [ -f \"$f\" ] || return 3",
            "  T=$(/usr/bin/mktemp \"$D/tilvero.XXXXXX\") || return 4",
            "  /usr/bin/grep -v -x -F \"$@\" \"$f\" > \"$T\"",
            "  [ $? -le 1 ] || return 5",
            "  if [ -s \"$T\" ]; then",
            "    /usr/sbin/chown root:wheel \"$T\" && /bin/chmod 0440 \"$T\" || return 6",
            "    /usr/sbin/visudo -c -q -f \"$T\" || return 7",
            "    /bin/mv -f \"$T\" \"$f\" || return 8",
            "  else",
            "    /bin/rm -f \"$T\" \"$f\" || return 8",
            "  fi",
            "  T=",
            "}",
        ]
    }

    /// Copy the existing merged file without the requested lines, append them, validate, move into place, and only
    /// then take the same lines out of the old one-feature files (another user's line there stays).
    static func installScript(uid: uid_t, features: Set<PrivilegedFeature>) -> String? {
        let lines = rules(uid: uid, features: features)
        guard !lines.isEmpty else { return nil }
        var script = preamble(uid: uid, removal: false)
        script += [
            "/bin/mkdir -p -m 0755 \"$D\" || exit 2",
            "[ ! -L \"$F\" ] || exit 3",
            "[ ! -e \"$F\" ] || [ -f \"$F\" ] || exit 3",
            "T=$(/usr/bin/mktemp \"$D/tilvero.XXXXXX\") || exit 4",
            "if [ -f \"$F\" ]; then",
            "  /usr/bin/grep -v -x -F \(patterns(lines)) \"$F\" > \"$T\"",
            "  [ $? -le 1 ] || exit 5",
            "fi",
            "/usr/bin/printf '%s\\n' \(lines.map { "'\($0)'" }.joined(separator: " ")) >> \"$T\" || exit 5",
            "/usr/sbin/chown root:wheel \"$T\" && /bin/chmod 0440 \"$T\" || exit 6",
            "/usr/sbin/visudo -c -q -f \"$T\" || exit 7",
            "/bin/mv -f \"$T\" \"$F\" || exit 8",
            "T=",
        ]
        script += features.sorted().map { "keep_others \($0.legacyPath) \(patterns([rule(uid: uid, feature: $0)])) || exit $?" }
        return script.joined(separator: "\n")
    }

    /// The exact inverse: this user's lines of these features leave the merged file and the old files; every other
    /// line stays; a file left empty is deleted. Idempotent: running it again changes nothing.
    static func removalScript(uid: uid_t, removing features: Set<PrivilegedFeature>) -> String? {
        let lines = rules(uid: uid, features: features)
        guard !lines.isEmpty else { return nil }
        var script = preamble(uid: uid, removal: true)
        script.append("keep_others \(mergedPath) \(patterns(lines)) || exit $?")
        script += features.sorted().map { "keep_others \($0.legacyPath) \(patterns([rule(uid: uid, feature: $0)])) || exit $?" }
        return script.joined(separator: "\n")
    }

    static func script(for operation: PrivilegedOperation, uid: uid_t) -> String? {
        switch operation {
        case .install(let features): installScript(uid: uid, features: features)
        case .remove(let features): removalScript(uid: uid, removing: features)
        }
    }
}

/// The text of the `.command` file the Terminal route opens. Fixed text: the only variable parts are the root script
/// (built above from the numeric uid) and three of the app's own short messages, which contain no quote, backslash,
/// dollar or backtick (pinned by a test). What the window can show is exactly what Terminal runs.
enum TerminalCommandText {
    static let marker = "TILVERO"

    struct Messages: Equatable, Sendable {
        var header: String, password: String, done: String, failed: String
        @MainActor static func localized(removal: Bool) -> Messages {
            Messages(header: L10n.text(removal ? "firstRun.script.removeHeader" : "firstRun.script.header"),
                     password: L10n.text("firstRun.script.password"), done: L10n.text("firstRun.script.done"),
                     failed: L10n.text("firstRun.script.failed"))
        }
        var all: [String] { [header, password, done, failed] }
        /// Characters that could leave the single-quoted shell words.
        static func isSafe(_ text: String) -> Bool { !text.contains(where: { "'\\$`\n\r".contains($0) }) }
        /// Never fails at run time: anything unsafe is dropped (a test pins that the real messages need no dropping).
        var sanitized: Messages {
            func clean(_ text: String) -> String { String(text.filter { !"'\\$`\n\r".contains($0) }) }
            return Messages(header: clean(header), password: clean(password), done: clean(done), failed: clean(failed))
        }
    }

    static func text(rootScript: String, messages raw: Messages) -> String {
        let messages = raw.sanitized
        return [
            "#!/bin/sh",
            "# \(messages.header)",
            "# Only the lines between the two \(marker) markers run as root; sudo asks for your password first.",
            "cd / || exit 1",
            "printf '%s\\n' '\(messages.header)' '\(messages.password)' ''",
            "/usr/bin/sudo /bin/sh -s <<'\(marker)'",
            rootScript,
            marker,
            "code=$?",
            "printf '%s\\n' \"$code\" > \"${0%/*}/result\"",
            "if [ \"$code\" -eq 0 ]; then",
            "  printf '%s\\n' '' '\(messages.done)'",
            "else",
            "  printf '%s\\n' '' '\(messages.failed)'",
            "fi",
        ].joined(separator: "\n") + "\n"
    }
}

/// The private folder and the `.command` file of one Terminal run.
enum TerminalCommandFile {
    static let fileName = "Tilvero.command"
    static let resultName = "result"

    enum Failure: Error { case folder, write, readBack }

    /// A fresh `mkdtemp` folder (0700) under the user's own temporary folder, the file created exclusively (no link
    /// followed) with mode 0700, then read back and compared byte for byte with `text`.
    static func prepare(_ text: String, base: URL) throws -> URL {
        var template = Array(base.appendingPathComponent("tilvero-permission.XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else { throw Failure.folder }
        let folder = URL(fileURLWithPath: template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true)
        let file = folder.appendingPathComponent(fileName)
        let data = Data(text.utf8)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: folder); throw Failure.write }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, (try? Data(contentsOf: file)) == data else {
            try? FileManager.default.removeItem(at: folder); throw written == data.count ? Failure.readBack : Failure.write
        }
        return file
    }

    /// The exit status the script wrote next to itself, nil while there is none.
    static func readResult(in folder: URL) -> Int32? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(resultName), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Parses `sudo -n -l`: the commands the user may run without a password. Read-only: listing runs nothing.
enum SudoListing {
    static func passwordlessCommands(_ output: String) -> Set<String> {
        var result = Set<String>()
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("(") else { continue }
            var nopasswd = false
            for var piece in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if piece.hasPrefix("("), let close = piece.firstIndex(of: ")") {
                    let runas = piece[piece.index(after: piece.startIndex)..<close]
                    piece = String(piece[piece.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                    if !(runas.contains("root") || runas.contains("ALL")) { nopasswd = false; continue }
                }
                // Tags (`NOPASSWD:`, `PASSWD:`, `SETENV:` …) precede the command and stay in force for the rest.
                while let colon = piece.firstIndex(of: ":"), piece[..<colon].allSatisfy({ $0.isUppercase || $0 == "_" }), !piece[..<colon].isEmpty {
                    let tag = piece[..<colon]
                    if tag == "NOPASSWD" { nopasswd = true } else if tag == "PASSWD" { nopasswd = false }
                    piece = String(piece[piece.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                if nopasswd, !piece.isEmpty { result.insert(piece.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) }
            }
        }
        return result
    }

    static func features(in output: String) -> Set<PrivilegedFeature> {
        let commands = passwordlessCommands(output)
        if commands.contains("ALL") { return Set(PrivilegedFeature.allCases) }
        return Set(PrivilegedFeature.allCases.filter { $0.commands.allSatisfy(commands.contains) })
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
    /// `lstat` of every rule path: changes when a file appears, disappears or is replaced (rename gives a new inode).
    static func signature(lstat read: (String) -> (dev: Int64, ino: UInt64, size: Int64, mtime: Int)? = Self.lstatFile) -> String {
        SudoersRules.allPaths.map { path in read(path).map { "\($0.dev):\($0.ino):\($0.size):\($0.mtime)" } ?? "-" }.joined(separator: "|")
    }
    static func lstatFile(_ path: String) -> (dev: Int64, ino: UInt64, size: Int64, mtime: Int)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_dev), UInt64(info.st_ino), Int64(info.st_size), info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec)
    }
}

enum AdministratorScriptOutcome: Equatable, Sendable { case succeeded, cancelled, failed(Int32?) }

/// The only way the shared installer runs anything as root through the macOS dialog. Tests and the preview inject fakes.
protocol AdministratorScriptExecuting: Sendable {
    func run(script: String, prompt: String) async -> AdministratorScriptOutcome
}

/// `osascript` `do shell script … with administrator privileges`. macOS shows its own dialog (Touch ID or password);
/// the password goes to the system, never to the app. The script and the prompt are passed as `argv` items of a fixed
/// AppleScript, so no text is ever spliced into AppleScript source. Cancelling the calling task terminates osascript,
/// which dismisses the dialog.
struct OsascriptAdministratorExecutor: AdministratorScriptExecuting {
    static let source = ["on run argv", "do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)", "end run"]
    static func arguments(script: String, prompt: String) -> [String] {
        source.flatMap { ["-e", $0] } + [script, prompt]
    }

    func run(script: String, prompt: String) async -> AdministratorScriptOutcome {
        guard !Task.isCancelled else { return .cancelled }
        // The dialog attaches to the requesting process; an inactive menu bar app would open it behind other windows.
        await MainActor.run { NSApplication.shared.activate() }
        let result = await CancellableProcessRun.run(launch: CancellableProcessRun.process("/usr/bin/osascript", Self.arguments(script: script, prompt: prompt)))
        return Self.outcome(status: result.status, output: result.output, cancelled: Task.isCancelled)
    }
    /// osascript reports "User canceled. (-128)" when the dialog is dismissed, and "… (N)" with the script's exit status.
    static func outcome(status: Int32, output: String, cancelled: Bool) -> AdministratorScriptOutcome {
        if status == 0 && !cancelled { return .succeeded }
        if output.contains("(-128)") || cancelled || status == CancellableProcessRun.cancelledBeforeStart { return .cancelled }
        return .failed(scriptStatus(output))
    }
    static func scriptStatus(_ output: String) -> Int32? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        return Int32(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
    }
}

/// Which features may run without a password right now. Read-only.
protocol PrivilegedRuleProbing: Sendable {
    /// nil when it cannot be told (sudo missing or not answering).
    func passwordless() async -> Set<PrivilegedFeature>?
}

/// `sudo -n -l` lists the user's rules without running anything and never prompts (`-n`). With sudo's default
/// `listpw=any`, any NOPASSWD rule (ours) lets it list without a password; without one it fails, which correctly
/// means "none of ours". It is run only on a change of the rule files, when the app comes back to the front, and on
/// the explicit "Check" button: never on a timer by itself.
struct SudoListProbe: PrivilegedRuleProbing {
    func passwordless() async -> Set<PrivilegedFeature>? {
        let result = await CancellableProcessRun.run(launch: CancellableProcessRun.process("/usr/bin/sudo", ["-n", "-l"]), timeout: 5)
        if result.status < 0 { return nil }
        return result.status == 0 ? SudoListing.features(in: result.output) : []
    }
}

/// Opens a prepared `.command` file in Terminal.
@MainActor protocol TerminalScriptOpening {
    /// Writes `text` into a fresh private folder and opens it in Terminal; returns the folder, nil when that failed.
    func open(_ text: String) async -> URL?
}

/// Launch Services opens the file with Terminal (no Apple Events, so no automation consent). A file Tilvero writes
/// itself carries no quarantine attribute, so Gatekeeper does not hold it back.
@MainActor struct NativeTerminalOpener: TerminalScriptOpening {
    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    func open(_ text: String) async -> URL? {
        guard let file = try? TerminalCommandFile.prepare(text, base: FileManager.default.temporaryDirectory) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: Self.terminal, configuration: configuration)
            return file.deletingLastPathComponent()
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            return nil
        }
    }
}

/// Time for the Terminal wait; tests inject a virtual clock.
struct PermissionWaitClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void
    static let live = PermissionWaitClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

/// Runs a cancellable process whose continuation resumes exactly once: on exit, on a launch failure, on the timeout, or
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

/// One password for every chosen feature, on either route; the exact inverse for removal. The scripts keep every
/// line they cannot account for, so a request never drops a line the app does not know about.
@MainActor final class PrivilegedRuleInstaller {
    private let executor: any AdministratorScriptExecuting
    private let terminal: any TerminalScriptOpening
    private let probe: any PrivilegedRuleProbing
    private let defaults: UserDefaults
    let uid: uid_t
    private let fileExists: (String) -> Bool
    private let signature: () -> String
    private let clock: PermissionWaitClock
    /// Builds the `.command` text from the root script (the preview swaps in a harmless demo).
    private let commandBuilder: @MainActor (PrivilegedOperation, String) -> String
    let terminalTimeout: TimeInterval
    let pollInterval: Duration
    private var nudged = false

    init(executor: any AdministratorScriptExecuting, terminal: any TerminalScriptOpening, probe: any PrivilegedRuleProbing,
         defaults: UserDefaults, uid: uid_t = getuid(),
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         signature: @escaping () -> String = { PrivilegedRulePresence.signature() },
         clock: PermissionWaitClock = .live, terminalTimeout: TimeInterval = 600, pollInterval: Duration = .milliseconds(500),
         commandBuilder: @escaping @MainActor (PrivilegedOperation, String) -> String = PrivilegedRuleInstaller.realCommand) {
        self.executor = executor; self.terminal = terminal; self.probe = probe; self.defaults = defaults; self.uid = uid
        self.fileExists = fileExists; self.signature = signature; self.clock = clock
        self.terminalTimeout = terminalTimeout; self.pollInterval = pollInterval; self.commandBuilder = commandBuilder
    }

    static func native(defaults: UserDefaults = .standard) -> PrivilegedRuleInstaller {
        PrivilegedRuleInstaller(executor: OsascriptAdministratorExecutor(), terminal: NativeTerminalOpener(), probe: SudoListProbe(), defaults: defaults)
    }

    static func realCommand(_ operation: PrivilegedOperation, _ rootScript: String) -> String {
        TerminalCommandText.text(rootScript: rootScript, messages: .localized(removal: operation.isRemoval))
    }

    static func prompt(for operation: PrivilegedOperation) -> String {
        L10n.text(operation.isRemoval ? "Tilvero asks to remove its passwordless pmset rules."
                  : "Tilvero asks to allow narrow pmset commands without a password for the features you chose.")
    }

    /// The `.command` text the Terminal route would open for this operation (what the window shows).
    func commandText(_ operation: PrivilegedOperation) -> String? {
        SudoersRules.script(for: operation, uid: uid).map { commandBuilder(operation, $0) }
    }

    /// The Terminal wait checks again at once (the app came back to the front, or the user pressed "Check").
    func nudge() { nudged = true }

    func install(_ features: Set<PrivilegedFeature>, route: PermissionRoute = .systemPrompt) async -> PrivilegedOutcome {
        await run(.install(features), route: route)
    }

    func run(_ operation: PrivilegedOperation, route: PermissionRoute) async -> PrivilegedOutcome {
        guard let script = SudoersRules.script(for: operation, uid: uid) else { return .succeeded([]) }
        let before = signature()
        let outcome: PrivilegedOutcome
        switch route {
        case .systemPrompt: outcome = await viaSystemPrompt(operation, script: script, before: before)
        case .terminal: outcome = await viaTerminal(operation, script: script, before: before)
        }
        if case .succeeded(let features) = outcome { record(operation, features) }
        return outcome
    }

    /// Which features run without a password right now (read-only); also refreshes the hint the services read.
    func presence() async -> Set<PrivilegedFeature>? {
        guard let present = await probe.passwordless() else { return nil }
        PrivilegedRulePresence.record(fileExists(SudoersRules.mergedPath) ? present : [], in: defaults)
        return present
    }

    // MARK: Routes

    private func viaSystemPrompt(_ operation: PrivilegedOperation, script: String, before: String) async -> PrivilegedOutcome {
        let result = await executor.run(script: script, prompt: Self.prompt(for: operation))
        switch result {
        case .succeeded:
            // An install counts only with the merged file really in place.
            if !operation.isRemoval, !fileExists(SudoersRules.mergedPath) { return .failed(nil) }
            return .succeeded(operation.features)
        case .cancelled, .failed:
            // A prompt cancelled after the script already moved its file into place still changed the rules.
            if signature() != before, await confirmed(operation) { return .succeeded(operation.features) }
            if case .failed(let code) = result { return .failed(code) }
            return .cancelled
        }
    }

    private func viaTerminal(_ operation: PrivilegedOperation, script: String, before: String) async -> PrivilegedOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let folder = await terminal.open(commandBuilder(operation, script)) else { return .failed(nil) }
        defer { try? FileManager.default.removeItem(at: folder) }
        return await waitForTerminal(operation, folder: folder, before: before)
    }

    /// Polls cheaply (the result file next to the script and `lstat` of the rule files); asks sudo only when a rule
    /// file changed, after a nudge, or when the script reported success. Bounded by `terminalTimeout`.
    func waitForTerminal(_ operation: PrivilegedOperation, folder: URL, before: String) async -> PrivilegedOutcome {
        let start = clock.now()
        var lastSignature = before
        nudged = false
        while true {
            if Task.isCancelled { return .cancelled }
            if let code = TerminalCommandFile.readResult(in: folder) {
                return code == 0 ? .succeeded(operation.features) : .failed(code)
            }
            let current = signature()
            if current != lastSignature || nudged {
                nudged = false
                lastSignature = current
                if current != before, await confirmed(operation) { return .succeeded(operation.features) }
            }
            if clock.now().timeIntervalSince(start) >= terminalTimeout { return .timedOut }
            do { try await clock.sleep(pollInterval) } catch { return .cancelled }
        }
    }

    /// The rules now say what the operation wanted (all its features present, or none of them).
    private func confirmed(_ operation: PrivilegedOperation) async -> Bool {
        guard let present = await probe.passwordless() else { return false }
        return operation.isRemoval ? present.isDisjoint(with: operation.features) : operation.features.isSubset(of: present)
    }

    private func record(_ operation: PrivilegedOperation, _ features: Set<PrivilegedFeature>) {
        let recorded = PrivilegedRulePresence.recordedMergedFeatures(defaults)
        switch operation {
        case .install: PrivilegedRulePresence.record(fileExists(SudoersRules.mergedPath) ? recorded.union(features) : recorded, in: defaults)
        case .remove: PrivilegedRulePresence.record(recorded.subtracting(features), in: defaults)
        }
    }

    // MARK: One-feature entry points of the services (the switch in Sleep, the charge-by-time pill)

    static func runNative(_ operation: PrivilegedOperation) async -> Bool {
        if case .succeeded = await native().run(operation, route: .systemPrompt) { return true }
        return false
    }
}
