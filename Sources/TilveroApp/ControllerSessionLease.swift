import Foundation
import Darwin

/// All updated variants hold the same process lease through restoration. Legacy
/// binaries do not honor it; launch-time sibling observation is not a race proof.
final class ControllerSessionLease {
    enum Availability: Equatable { case available, occupied, unknown }
    static func inspect(directory: URL? = nil) -> Availability {
        guard let directory = try? directory ?? sharedDirectory() else { return .unknown }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return errno == ENOENT ? .available : .unknown }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { return .unknown }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return .unknown }
        defer { close(parent) }
        let probe = openat(parent, "controller.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard probe >= 0 else { return errno == ENOENT ? .available : .unknown }
        defer { close(probe) }
        guard fstat(probe, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { return .unknown }
        guard flock(probe, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK ? .occupied : .unknown }
        flock(probe, LOCK_UN)
        return .available
    }
    enum Failure: Error { case unavailable, unsafePath, occupied }
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) } // Never unlink a lock another process may already have opened.

    static func acquire(directory: URL? = nil) throws -> ControllerSessionLease {
        let directory = try directory ?? sharedDirectory()
        let path = directory.path
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
        let parent = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsafePath }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        let descriptor = openat(parent, "controller.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        do {
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  info.st_nlink == 1 else { throw Failure.unsafePath }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw errno == EWOULDBLOCK ? Failure.occupied : Failure.unavailable
            }
            return ControllerSessionLease(descriptor: descriptor)
        } catch { close(descriptor); throw error }
    }

    private static func sharedDirectory() throws -> URL {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { throw Failure.unavailable }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else { throw Failure.unavailable }
        let root = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        return root.appendingPathComponent("TilveroController", isDirectory: true)
    }
}
