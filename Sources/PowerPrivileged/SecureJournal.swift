import Foundation
import Darwin
import PowerCore

public enum JournalPhase: String, Codable, Sendable { case prepared, applied, recovering, unresolved, restored }
public struct FanOriginalState: Codable, Sendable, Equatable {
    public let targetRPM: Int
    public let automatic: Bool
    public init(targetRPM: Int, automatic: Bool) { self.targetRPM = targetRPM; self.automatic = automatic }
}
public struct FanJournalStep: Codable, Sendable, Equatable {
    public let register: FanRegister
    public let original: FanRegisterValue
    public let intended: FanRegisterValue
    public var applied: FanRegisterValue?
    public var previous: FanRegisterValue?
    public var phase: JournalPhase = .prepared
    public init(register: FanRegister, original: FanRegisterValue, intended: FanRegisterValue, previous: FanRegisterValue? = nil) {
        self.register = register; self.original = original; self.intended = intended
        self.previous = previous
    }
}
public struct JournalEntry: Codable, Sendable, Equatable {
    public let original: HardwareSetting
    public var intended: HardwareSetting
    public var applied: HardwareSetting?
    public var phase: JournalPhase = .prepared
    public var recoveryAttempts = 0
    public var failure: String?
    public var fanOriginals: [String: FanOriginalState] = [:]
    public var fanSteps: [FanJournalStep] = []
    public init(original: HardwareSetting, intended: HardwareSetting) { self.original = original; self.intended = intended }
}
public struct OwnershipJournal: Codable, Sendable {
    public let schemaVersion: Int
    public let bootID: String
    public var generation: UInt64
    public let ownerToken: UUID
    public let ownerUserID: UInt32
    public var heartbeat: Double
    public var leaseDeadline: Double
    public var ownerRevoked: Bool = false
    public var entries: [OwnedResource: JournalEntry] = [:]
    public init(bootID: String, generation: UInt64, ownerToken: UUID, ownerUserID: UInt32, heartbeat: Double, leaseDeadline: Double) {
        schemaVersion = 1; self.bootID = bootID; self.generation = generation; self.ownerToken = ownerToken; self.ownerUserID = ownerUserID
        self.heartbeat = heartbeat; self.leaseDeadline = leaseDeadline
    }
}
private struct AuthorityEpoch: Codable {
    let schemaVersion: Int
    let epoch: UUID
}
public final class JournalLock: @unchecked Sendable {
    fileprivate let descriptor: Int32
    fileprivate let directoryPath: String
    fileprivate init(descriptor: Int32, directoryPath: String) { self.descriptor = descriptor; self.directoryPath = directoryPath }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// Root-owned production storage. Tests use an isolated temporary directory owned by the test user.
public struct SecureJournal: Sendable {
    public static let productionDirectory = URL(fileURLWithPath: "/Library/Application Support/Tilvero", isDirectory: true)
    public let directory: URL
    private let expectedOwner: uid_t
    public init(directory: URL = productionDirectory, expectedOwner: uid_t = 0) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw PrivilegeError.insecureStorage }
        self.directory = directory; self.expectedOwner = expectedOwner
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw PrivilegeError.insecureStorage }
        try verifyDirectory()
    }
    private func verifyDirectory() throws {
        // Inspect every existing path component; no symlink may redirect a privileged journal.
        var path = ""
        for component in directory.pathComponents where component != "/" {
            path += "/" + component
            var info = stat(); guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw PrivilegeError.insecureStorage }
            if path == directory.path {
                guard info.st_uid == expectedOwner, info.st_mode & 0o077 == 0 else { throw PrivilegeError.insecureStorage }
            } else if expectedOwner == 0 {
                guard info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw PrivilegeError.insecureStorage }
            }
        }
    }
    public func acquireLock() throws -> JournalLock {
        try verifyDirectory()
        let fd = open(directory.appendingPathComponent("hardware.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivilegeError.insecureStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == expectedOwner, info.st_mode & 0o077 == 0, info.st_nlink == 1, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw PrivilegeError.insecureStorage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PrivilegeError.locked }
        return JournalLock(descriptor: fd, directoryPath: directory.path)
    }
    public func read(lock: JournalLock) throws -> OwnershipJournal? {
        guard let data = try readData(named: "ownership.json", maximumBytes: 65_536, lock: lock) else { return nil }
        guard let record = try? JSONDecoder().decode(OwnershipJournal.self, from: data), record.schemaVersion == 1,
              record.entries.count <= 4, record.heartbeat.isFinite, record.leaseDeadline.isFinite, record.generation < UInt64.max else { throw PrivilegeError.corruptJournal }
        return record
    }
    /// An authenticated session captures this epoch once. It outlives ownership
    /// records, so later acquire/release cycles cannot revive a revoked session.
    func authorityEpoch(lock: JournalLock) throws -> UUID {
        guard let data = try readData(named: "authority.json", maximumBytes: 256, lock: lock) else {
            return try writeNewAuthorityEpoch(lock: lock)
        }
        guard let record = try? JSONDecoder().decode(AuthorityEpoch.self, from: data), record.schemaVersion == 1 else { throw PrivilegeError.corruptJournal }
        return record.epoch
    }
    @discardableResult func revokeAuthority(lock: JournalLock) throws -> UUID {
        // Corrupt or redirected authority storage must fail closed, never turn
        // into an implicit reset when the guardian attempts recovery.
        _ = try authorityEpoch(lock: lock)
        return try writeNewAuthorityEpoch(lock: lock)
    }
    private func writeNewAuthorityEpoch(lock: JournalLock) throws -> UUID {
        let epoch = UUID()
        try writeData(JSONEncoder().encode(AuthorityEpoch(schemaVersion: 1, epoch: epoch)), named: "authority.json", maximumBytes: 256, lock: lock)
        return epoch
    }
    private func readData(named filename: String, maximumBytes: Int, lock: JournalLock) throws -> Data? {
        guard lock.directoryPath == directory.path else { throw PrivilegeError.insecureStorage }; try verifyDirectory()
        let fd = open(directory.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw PrivilegeError.insecureStorage }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == expectedOwner, info.st_mode & 0o077 == 0, info.st_nlink == 1, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw PrivilegeError.insecureStorage }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            guard count > 0 else { throw PrivilegeError.corruptJournal }; offset += count
        }
        return Data(bytes)
    }
    public func write(_ record: OwnershipJournal, lock: JournalLock) throws {
        try writeData(JSONEncoder().encode(record), named: "ownership.json", maximumBytes: 65_536, lock: lock)
    }
    private func writeData(_ data: Data, named filename: String, maximumBytes: Int, lock: JournalLock) throws {
        guard lock.directoryPath == directory.path else { throw PrivilegeError.insecureStorage }; try verifyDirectory()
        guard data.count <= maximumBytes else { throw PrivilegeError.corruptJournal }
        let temporary = directory.appendingPathComponent(".journal-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivilegeError.insecureStorage }
        defer { close(fd); unlink(temporary.path) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            guard written > 0 else { throw PrivilegeError.insecureStorage }; offset += written
        }
        guard fsync(fd) == 0, rename(temporary.path, directory.appendingPathComponent(filename).path) == 0 else { throw PrivilegeError.insecureStorage }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw PrivilegeError.insecureStorage }; defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw PrivilegeError.insecureStorage }
    }
    public func removeVerifiedEmpty(lock: JournalLock) throws {
        guard let record = try read(lock: lock), record.entries.isEmpty else { throw PrivilegeError.recoveryRequired }
        guard unlink(directory.appendingPathComponent("ownership.json").path) == 0 else { throw PrivilegeError.insecureStorage }
    }
}
