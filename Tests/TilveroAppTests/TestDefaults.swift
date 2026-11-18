// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import XCTest

/// Preference suites for tests. Every suite is named `TilveroTests-<label>-<UUID>`, and removing one removes both the
/// domain and its `~/Library/Preferences/<suite>.plist` (removing the domain alone leaves the file behind). Each suite
/// is removed when its test ends; any suite this process created and did not remove yet goes when the process exits.
enum TestDefaults {
    static let prefix = "TilveroTests-"

    /// A fresh suite name; nothing is created yet.
    static func name(_ label: String = "") -> String {
        prefix + (label.isEmpty ? "" : label + "-") + UUID().uuidString
    }

    /// The suite called `name` (it must start with `prefix`), remembered for the removal at exit.
    static func defaults(_ name: String) -> UserDefaults {
        precondition(name.hasPrefix(prefix), "Test preference suites must start with \(prefix)")
        Registry.shared.insert(name)
        return UserDefaults(suiteName: name)!
    }

    /// A fresh suite and its name. The caller removes it with `remove(_:)`; `XCTestCase.makeTestDefaults` does that itself.
    static func make(_ label: String = "") -> (name: String, defaults: UserDefaults) {
        let name = name(label)
        return (name, defaults(name))
    }

    /// Removes the domain and deletes its preference file. Safe to call more than once.
    static func remove(_ name: String) {
        guard name.hasPrefix(prefix) else { return }
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: plistURL(name))
        Registry.shared.remove(name)
    }

    static func plistURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(name + ".plist")
    }

    /// Suites created and not yet removed; the rest go at process exit (a test that never reached its teardown).
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var names: Set<String> = []
        private init() { atexit { TestDefaults.removeRemaining() } }
        func insert(_ name: String) { lock.withLock { _ = names.insert(name) } }
        func remove(_ name: String) { lock.withLock { _ = names.remove(name) } }
        func drain() -> Set<String> { lock.withLock { defer { names = [] }; return names } }
    }

    fileprivate static func removeRemaining() {
        for name in Registry.shared.drain() { remove(name) }
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
