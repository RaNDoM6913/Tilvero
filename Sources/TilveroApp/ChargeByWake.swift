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
    /// The older one-feature file (still read; new permissions go into the merged file, see `PrivilegedRuleInstaller`).
    static let rulePath = "/etc/sudoers.d/tilvero-wake"

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
    /// Is our wake for `date` in the output of `pmset -g sched`?
    static func schedulePresent(_ output: String, date: Date, timeZone: TimeZone = .current) -> Bool {
        let stamp = pmsetDate(date, timeZone: timeZone)
        return output.split(separator: "\n").contains { $0.contains("wake at " + stamp) && $0.contains("'" + owner + "'") }
    }

    /// The own `tilvero-wake` file or the merged `tilvero` file written with this feature (see `PrivilegedRuleInstaller`).
    var isPermitted: Bool { PrivilegedRulePresence.isPresent(.chargeByTime) }

    func schedule(_ date: Date) async -> Bool {
        guard isPermitted else { return false }
        let result = await ProcessRunner.run("/usr/bin/sudo", Self.scheduleArguments(date))
        guard result.status == 0 else { return false }
        let listed = await ProcessRunner.run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && Self.schedulePresent(listed.output, date: date)
    }
    func cancel(_ date: Date) async -> Bool {
        guard isPermitted else { return false }
        _ = await ProcessRunner.run("/usr/bin/sudo", Self.cancelArguments(date))
        let listed = await ProcessRunner.run("/usr/bin/pmset", ["-g", "sched"])
        return listed.status == 0 && !Self.schedulePresent(listed.output, date: date)
    }
    /// The shared installer: the wake line goes into the merged rule file (one validated root script, one dialog).
    func installPermission() async -> Bool { await PrivilegedRuleInstaller.runNative(.install([.chargeByTime])) && isPermitted }
}

/// Demo and monitoring-only launches never touch the system's wake schedule.
@MainActor final class DisabledWakeScheduler: WakeScheduling {
    var isPermitted: Bool { false }
    func schedule(_ date: Date) async -> Bool { false }
    func cancel(_ date: Date) async -> Bool { true }
    func installPermission() async -> Bool { false }
}
