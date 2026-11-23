// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
import XCTest

/// Preference suites for tests. Every suite is named `TilveroTests-<label>-<UUID>`, and removing one removes both the
/// domain and its `~/Library/Preferences/<suite>.plist` (removing the domain alone leaves the file behind). Each suite
/// is removed when its test ends; any suite this process created and did not remove yet goes when the process exits.
///
/// cfprefsd writes a domain to disk on its own schedule (measured: about ten seconds after the change or after the
/// process exited), so an emptied domain can come back as an empty plist after its file was deleted. The file is
/// therefore deleted again 15 s later, and at exit a detached shell deletes exactly this process's suite files once
/// more 20 s after the process is gone (no globbing, nothing else).
enum TestDefaults {
    static let prefix = "TilveroTests-"

    /// A fresh suite name; nothing is created yet.
    static func name(_ label: String = "") -> String {
        prefix + (label.isEmpty ? "" : label + "-") + UUID().uuidString
    }

    /// The suite called `name` (it must start with `prefix`), remembered for the removal at exit.
    static func defaults(_ name: String) -> UserDefaults {
        precondition(name.hasPrefix(prefix), "Test preference suites must start with \(prefix)")
        Registry.shared.created(name)
        return UserDefaults(suiteName: name)!
    }

    /// A fresh suite and its name. The caller removes it with `remove(_:)`; `XCTestCase.makeTestDefaults` does that itself.
    static func make(_ label: String = "") -> (name: String, defaults: UserDefaults) {
        let name = name(label)
        return (name, defaults(name))
    }

    /// Removes the domain and deletes its preference file (again 15 s later). Safe to call more than once.
    static func remove(_ name: String) {
        guard name.hasPrefix(prefix) else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        deleteFile(name)
        Registry.shared.removed(name)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { deleteFile(name) }
    }

    static func plistURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(name + ".plist")
    }
    private static func deleteFile(_ name: String) { try? FileManager.default.removeItem(at: plistURL(name)) }

    /// Every suite this process created, and those not removed yet.
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var all: Set<String> = []
        private var open: Set<String> = []
        private init() { atexit { TestDefaults.sweep() } }
        func created(_ name: String) { lock.withLock { _ = all.insert(name); _ = open.insert(name) } }
        func removed(_ name: String) { lock.withLock { _ = open.remove(name) } }
        var snapshot: (all: Set<String>, open: Set<String>) { lock.withLock { (all, open) } }
    }

    /// At exit: removes suites a test never removed, deletes every created suite's file, and leaves the late copies
    /// cfprefsd may still write to a detached shell that deletes exactly these files after the process is gone.
    fileprivate static func sweep() {
        let (all, open) = Registry.shared.snapshot
        for name in open {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
        }
        for name in all { deleteFile(name) }
        guard !all.isEmpty else { return }
        deleteLater(all.map { plistURL($0).path }, afterSeconds: 20)
    }

    /// `/bin/sh` in its own session with no inherited output (a test runner never waits for it), running only
    /// `/bin/sleep` and `/bin/rm -f` on the given absolute paths.
    private static func deleteLater(_ paths: [String], afterSeconds seconds: Int) {
        let script = "/bin/sleep \(seconds); for f in \"$@\"; do /bin/rm -f -- \"$f\"; done"
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes); posix_spawn_file_actions_init(&actions)
        defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments = ["/bin/sh", "-c", script, "tilvero-test-defaults-sweep"] + paths
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        _ = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &cArguments, &environment)
    }
}

extension XCTestCase {
    /// A fresh `TilveroTests-` suite that is removed (domain and file) when the current test ends.
    func makeTestDefaults(_ label: String = "") -> (name: String, defaults: UserDefaults) {
        let name = TestDefaults.name(label)
        addTeardownBlock { TestDefaults.remove(name) }
        return (name, TestDefaults.defaults(name))
    }
}
