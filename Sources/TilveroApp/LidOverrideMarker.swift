// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
import PowerCore

/// What is on disk at the marker path.
enum LidOverrideMarkerReading: Equatable, Sendable {
    case absent
    case marker(LidOverrideMarker)
    /// Something is there but it is not a readable version-1 marker: present, owner unknown.
    case unreadable

    var isPresent: Bool { self != .absent }

    /// The watchdog's view: only its own token is "own"; anything else that is present is foreign.
    func ownership(of token: String) -> LidWatchdogMarkerOwnership {
        switch self {
        case .absent: .absent
        case .marker(let marker): marker.token == token ? .own : .foreign
        case .unreadable: .foreign
        }
    }
}

/// The closed-lid override's intent marker (`lid-override.json`) and its lock (`lid-override.lock`), next to the
/// history store of the running identity. The marker is written before `pmset disablesleep 1` and removed only after
/// a confirmed `0`; the token in it is what a lid watchdog checks before it acts. Mode 0600, atomic write with fsync.
/// The lock (`flock`) serialises the app's enable, restore and launch recovery with every watchdog's act step.
struct LidOverrideMarkerStore: Sendable {
    static let markerName = "lid-override.json"
    static let lockName = "lid-override.lock"
    /// Anything larger is not a marker this app wrote.
    static let maximumSize = 64 * 1024

    let directory: URL
    var markerURL: URL { directory.appendingPathComponent(Self.markerName, isDirectory: false) }
    var lockURL: URL { directory.appendingPathComponent(Self.lockName, isDirectory: false) }

    enum Failure: Error, Equatable { case posix(Int32), encoding }

    func read() -> LidOverrideMarkerReading {
        var info = stat()
        guard lstat(markerURL.path, &info) == 0 else {
            // No file, or a path component that is not a directory: nothing can be there.
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maximumSize,
              let data = FileManager.default.contents(atPath: markerURL.path),
              let marker = LidOverrideMarker.decode(data) else { return .unreadable }
        return .marker(marker)
    }

    /// Temporary file (0600, exclusive create), full write, fsync, rename over the marker, fsync of the directory.
    /// A reader never sees a half-written marker.
    func write(_ marker: LidOverrideMarker) throws {
        guard let data = try? marker.encoded() else { throw Failure.encoding }
        try prepareDirectory()
        let temporary = directory.appendingPathComponent(".lid-override.\(UUID().uuidString).tmp", isDirectory: false)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.posix(errno) }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw Failure.posix(errno) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw Failure.posix(errno) }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw Failure.posix(errno) }
        }
        guard rename(temporary.path, markerURL.path) == 0 else { throw Failure.posix(errno) }
        renamed = true
        syncDirectory()
    }

    /// Removes the marker; a marker that is not there counts as removed.
    func delete() throws {
        guard unlink(markerURL.path) == 0 || errno == ENOENT || errno == ENOTDIR else { throw Failure.posix(errno) }
        syncDirectory()
    }

    /// Compare-token-and-delete (the caller holds the lock): only a marker that still carries `token` is removed.
    @discardableResult func deleteIfOwned(by token: String) -> Bool {
        guard read().ownership(of: token) == .own else { return false }
        return (try? delete()) != nil
    }

    /// Non-blocking: the lock, or nil when another process holds it (or the lock file cannot be opened).
    func tryLock() -> LidOverrideLock? {
        try? prepareDirectory()
        // Close-on-exec: a child (pmset, sudo, the watchdog itself) must never inherit and keep the lock.
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return LidOverrideLock(fd: fd)
    }

    /// Blocking with a deadline (the watchdog, off the main thread).
    func lock(timeout: TimeInterval, pollInterval: TimeInterval = 0.05) -> LidOverrideLock? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let lock = tryLock() { return lock }
            if Date() >= deadline { return nil }
            usleep(useconds_t(max(0.001, pollInterval) * 1_000_000))
        }
    }

    private func prepareDirectory() throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw Failure.posix(EIO) }
    }

    private func syncDirectory() {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd); close(fd)
    }

    /// `kern.bootsessionuuid`: recorded in the marker for diagnostics.
    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

/// One held `flock`. Released by `unlock()` or when the process ends (the kernel drops it with the descriptor).
final class LidOverrideLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(fd: Int32) { self.fd = fd }
    func unlock() {
        lock.withLock {
            guard fd >= 0 else { return }
            _ = flock(fd, LOCK_UN); close(fd); fd = -1
        }
    }
    deinit { unlock() }
}

/// The app's side of the lock: one `flock` for the whole process, shared by overlapping operations (an enable that
/// ends in a restore, a launch recovery that restores), acquired by polling so the main actor never blocks.
@MainActor final class LidOverrideLockHolder {
    private let store: LidOverrideMarkerStore
    private var held: LidOverrideLock?
    private var depth = 0
    init(store: LidOverrideMarkerStore) { self.store = store }

    var isHeld: Bool { held != nil }

    /// true when this process now holds the lock; every true must be paired with one `release()`.
    func acquire(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if held != nil { depth += 1; return true }
            if let fresh = store.tryLock() { held = fresh; depth = 1; return true }
            guard clock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
    }

    func release() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { held?.unlock(); held = nil }
    }
}
