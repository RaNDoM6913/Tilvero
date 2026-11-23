// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import AppKit

/// One scheduled system wake, so the app is alive at the moment the charge limit has to be lifted while the Mac sleeps.
@MainActor protocol WakeScheduling: AnyObject {
    /// The passwordless permission is in place.
    var isPermitted: Bool { get }
    /// Schedules the wake and reads it back from `pmset -g sched`. Returns the exact date string the entry was made
    /// with (keep it: cancelling needs the same string even after a time-zone or DST change); nil when it is not there.
    func schedule(_ date: Date) async -> String?
    /// Removes the entry made with `stamp` (idempotent: an entry that is not there counts as removed). A nil or malformed
    /// stamp (a plan saved before stamps were kept) falls back to formatting the date in the current time zone.
    func cancel(_ date: Date, stamp: String?) async -> Bool
    /// Administrator prompt that installs the permission (one rule, two narrow commands).
    func installPermission() async -> Bool
}

/// The only place that runs `sudo -n pmset schedule`. Never exercised by default tests (they inject the runner).
@MainActor final class NativeWakeScheduler: WakeScheduling {
    static let owner = "Tilvero"
    /// The older one-feature file (still read; new permissions go into the merged file, see `PrivilegedRuleInstaller`).
    static let rulePath = "/etc/sudoers.d/tilvero-wake"
    typealias Runner = @Sendable (_ path: String, _ arguments: [String]) async -> (status: Int32, output: String)

    private let run: Runner
    private let timeZone: () -> TimeZone
    private let permitted: () -> Bool
    init(run: @escaping Runner = { await ProcessRunner.run($0, $1) }, timeZone: @escaping () -> TimeZone = { .current },
         permitted: @escaping () -> Bool = { PrivilegedRulePresence.isPresent(.chargeByTime) }) {
        self.run = run; self.timeZone = timeZone; self.permitted = permitted
    }

    /// `pmset schedule` takes the date in the local time zone, in this exact shape (it is also how `pmset -g sched` prints it).
    static func pmsetDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }
    /// Exactly the shape `pmsetDate` makes (MM/dd/yyyy HH:mm:ss, ASCII digits) and a real calendar date. A stored stamp
    /// is checked with this before it can reach `sudo -n pmset schedule cancel wake`.
    static func isValidStamp(_ stamp: String) -> Bool {
        let shape = Array("00/00/0000 00:00:00".utf8), bytes = Array(stamp.utf8)
        guard bytes.count == shape.count, zip(bytes, shape).allSatisfy({ byte, pattern in
            pattern == UInt8(ascii: "0") ? (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) : byte == pattern
        }) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"; formatter.isLenient = false
        return formatter.date(from: stamp).map { formatter.string(from: $0) == stamp } ?? false
    }
    static func scheduleArguments(stamp: String) -> [String] {
        ["-n", "/usr/bin/pmset", "schedule", "wake", stamp, owner]
    }
    static func cancelArguments(stamp: String) -> [String] {
        ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", stamp, owner]
    }
    /// Granted by uid (see the lid rule). Only scheduling and cancelling a wake, nothing else.
    static func rule(uid: uid_t) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"
    }
    /// Does `pmset -g sched` still list a Tilvero wake entry made with exactly this date string?
    static func schedulePresent(_ output: String, stamp: String) -> Bool {
        output.split(separator: "\n").contains { $0.contains("wake") && $0.contains(" at " + stamp) && $0.contains("'" + owner + "'") }
    }

    /// The own `tilvero-wake` file or the merged `tilvero` file written with this feature (see `PrivilegedRuleInstaller`).
    var isPermitted: Bool { permitted() }

    func schedule(_ date: Date) async -> String? {
        guard isPermitted else { return nil }
        let stamp = Self.pmsetDate(date, timeZone: timeZone())
        let result = await run("/usr/bin/sudo", Self.scheduleArguments(stamp: stamp))
        guard result.status == 0 else { return nil }
        let listed = await run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && Self.schedulePresent(listed.output, stamp: stamp) ? stamp : nil
    }
    func cancel(_ date: Date, stamp: String?) async -> Bool {
        guard isPermitted else { return false }
        let stamp = stamp.flatMap { Self.isValidStamp($0) ? $0 : nil } ?? Self.pmsetDate(date, timeZone: timeZone())
        _ = await run("/usr/bin/sudo", Self.cancelArguments(stamp: stamp))
        let listed = await run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && !Self.schedulePresent(listed.output, stamp: stamp)
    }
    /// The shared installer: the wake line goes into the merged rule file (one validated root script, one dialog).
    func installPermission() async -> Bool { await PrivilegedRuleInstaller.runNative(.install([.chargeByTime])) && isPermitted }
}

/// Demo and monitoring-only launches never touch the system's wake schedule.
@MainActor final class DisabledWakeScheduler: WakeScheduling {
    var isPermitted: Bool { false }
    func schedule(_ date: Date) async -> String? { nil }
    func cancel(_ date: Date, stamp: String?) async -> Bool { true }
    func installPermission() async -> Bool { false }
}
