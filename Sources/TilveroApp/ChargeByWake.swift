// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import AppKit

/// One scheduled system wake, so the app is alive at the moment the charge limit has to be lifted while the Mac sleeps.
@MainActor protocol WakeScheduling: AnyObject {
    /// The passwordless permission is in place.
    var isPermitted: Bool { get }
    /// Schedules the wake and reads it back from `pmset -g sched`; true only when the entry is really there.
    func schedule(_ date: Date) async -> Bool
    /// Removes the entry (idempotent: an entry that is not there counts as removed).
    func cancel(_ date: Date) async -> Bool
    /// Administrator prompt that installs the permission (one rule, two narrow commands).
    func installPermission() async -> Bool
}

/// The only place that runs `sudo -n pmset schedule`. Never exercised by default tests.
@MainActor final class NativeWakeScheduler: WakeScheduling {
    static let owner = "Tilvero"
    static let rulePath = "/etc/sudoers.d/tilvero-wake"
    static let tempRulePath = "/etc/sudoers.d/tilvero-wake.tmp"

    /// `pmset schedule` takes the date in the local time zone, in this exact shape (it is also how `pmset -g sched` prints it).
    static func pmsetDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
    static func scheduleArguments(_ date: Date, timeZone: TimeZone = .current) -> [String] {
        ["-n", "/usr/bin/pmset", "schedule", "wake", pmsetDate(date, timeZone: timeZone), owner]
    }
    static func cancelArguments(_ date: Date, timeZone: TimeZone = .current) -> [String] {
        ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", pmsetDate(date, timeZone: timeZone), owner]
    }
    /// Granted by uid (see the lid rule). Only scheduling and cancelling a wake, nothing else.
    static func rule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"
    }
    static func installCommand(uid: uid_t) -> String {
        "mkdir -p /etc/sudoers.d && echo '\(rule(uid: uid))' > \(tempRulePath) && chmod 0440 \(tempRulePath) && /usr/sbin/visudo -c -f \(tempRulePath) && mv \(tempRulePath) \(rulePath) || { rm -f \(tempRulePath); exit 1; }"
    }
    /// Is our wake for `date` in the output of `pmset -g sched`?
    static func schedulePresent(_ output: String, date: Date, timeZone: TimeZone = .current) -> Bool {
        let stamp = pmsetDate(date, timeZone: timeZone)
        return output.split(separator: "\n").contains { $0.contains("wake at " + stamp) && $0.contains("'" + owner + "'") }
    }

    var isPermitted: Bool { FileManager.default.fileExists(atPath: Self.rulePath) }

    func schedule(_ date: Date) async -> Bool {
        guard isPermitted else { return false }
        let result = await Self.run("/usr/bin/sudo", Self.scheduleArguments(date))
        guard result.status == 0 else { return false }
        let listed = await Self.run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && Self.schedulePresent(listed.output, date: date)
    }
    func cancel(_ date: Date) async -> Bool {
        guard isPermitted else { return false }
        _ = await Self.run("/usr/bin/sudo", Self.cancelArguments(date))
        let listed = await Self.run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && !Self.schedulePresent(listed.output, date: date)
    }
    func installPermission() async -> Bool {
        let prompt = L10n.text("Tilvero asks to allow scheduling one wake, so a Mac asleep overnight can start charging on time.")
        let literal = "\"" + Self.installCommand(uid: getuid()).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let promptLiteral = "\"" + prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        NSApplication.shared.activate()
        let result = await Self.run("/usr/bin/osascript", ["-e", "do shell script \(literal) with administrator privileges with prompt \(promptLiteral)"], timeout: 600)
        return result.status == 0 && isPermitted
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            let once = Once()
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if once.take() { continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self))) }
            }
            do { try process.run() } catch { if once.take() { continuation.resume(returning: (-1, "")) }; return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                if once.take() { continuation.resume(returning: (-2, "")) }
            }
        }
    }
}

/// Demo and monitoring-only launches never touch the system's wake schedule.
@MainActor final class DisabledWakeScheduler: WakeScheduling {
    var isPermitted: Bool { false }
    func schedule(_ date: Date) async -> Bool { false }
    func cancel(_ date: Date) async -> Bool { true }
    func installPermission() async -> Bool { false }
}
