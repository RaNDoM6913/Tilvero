import Foundation
import Darwin

/// Dedicated volatile-clamshell store. This never opens the production hardware journal.
public struct ClosedLidRecord: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var mechanism = ClosedLidLimits.mechanism
    public var bootID: String
    public var authorityEpoch: UUID
    public var controllerID: UUID
    public var controllerPID: Int32
    public var peer: ClosedLidPeer
    public var sessionToken: UUID
    public var revoked = false
    public var state = ClosedLidState()
    public var baseline: ClamshellBaselineWitness?
    public var applyReceipt: ClamshellCommandReceipt?
    public var restoreReceipt: ClamshellCommandReceipt?
    public var restoreAttempts = 0
    public var restoreIssuedAt: Double?
    public var restoreBoundarySequence: UInt64?
    public var restoreBoundaryObserverID: UUID?
    public var normalSleepIssuedAt: Double?
    public var normalSleepFailure: ClosedLidFailure?
    public var requestIDs: [UUID] = []
    public init(bootID: String, authorityEpoch: UUID, controllerID: UUID,
                peer: ClosedLidPeer, sessionToken: UUID, controllerPID: Int32 = getpid()) {
        self.bootID = bootID; self.authorityEpoch = authorityEpoch; self.controllerID = controllerID
        self.peer = peer; self.sessionToken = sessionToken; self.controllerPID = controllerPID
    }
    var needsNormalSleepDecision: Bool {
        state.restoreCommandAccepted && state.normalSleepRequestAttempted == nil
            && (state.phase == .restoreAcceptedAwaitingWitness || state.phase == .restored)
    }
    var needsRecovery: Bool {
        switch state.phase {
        case .prepared, .commandAccepted, .restorationRequired, .restoreAcceptedAwaitingWitness, .conflict: true
        default: false
        }
    }
}

struct ClosedLidGuardianPulse: Codable, Sendable {
    var schemaVersion = 1
    var role = "signed-closed-lid-guardian"
    let bootID: String
    let receivedAt: Double
    let processID: Int32
    let instanceID: UUID
}
private struct LidAuthority: Codable { var schemaVersion = 1; let epoch: UUID }

public final class ClosedLidOperationLock: @unchecked Sendable {
    private let descriptor: Int32
    fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// A root-owned directory in deployment; explicit temporary, current-user directories in fixtures.
/// Separate writer and metadata locks let revocation persist while a kernel call is outstanding.
public final class ClosedLidJournal: @unchecked Sendable {
    public static let productionDirectory = URL(fileURLWithPath: "/Library/Application Support/TilveroClosedLidLab", isDirectory: true)
    public let directory: URL
    public let requiredOwner: UInt32
    private let device: dev_t
    private let inode: ino_t
    public init(directory: URL, requiredOwner: UInt32 = geteuid()) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains(".."),
              directory.standardizedFileURL.path == directory.path else { throw ClosedLidFailure.insecureStorage }
        self.directory = directory; self.requiredOwner = requiredOwner
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw ClosedLidFailure.insecureStorage }
        try Self.verifyPath(directory, owner: requiredOwner)
        var info = stat(); guard lstat(directory.path, &info) == 0 else { throw ClosedLidFailure.insecureStorage }
        device = info.st_dev; inode = info.st_ino
    }
    private static func verifyPath(_ directory: URL, owner: UInt32) throws {
        var path = ""
        for component in directory.pathComponents where component != "/" {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ClosedLidFailure.insecureStorage }
            if path == directory.path {
                guard info.st_uid == owner, info.st_mode & 0o777 == 0o700 else { throw ClosedLidFailure.insecureStorage }
            } else if owner == 0 {
                guard info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw ClosedLidFailure.insecureStorage }
            }
        }
    }
    private func directoryFD() throws -> Int32 {
        try Self.verifyPath(directory, owner: requiredOwner)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClosedLidFailure.insecureStorage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode else {
            close(fd); throw ClosedLidFailure.insecureStorage
        }
        return fd
    }
    private func verifyFile(_ fd: Int32, maximum: Int) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == requiredOwner, info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw ClosedLidFailure.insecureStorage }
        return info
    }
    private func lock(named name: String, directoryFD: Int32) throws -> ClosedLidOperationLock {
        let fd = openat(directoryFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ClosedLidFailure.insecureStorage }
        do { _ = try verifyFile(fd, maximum: 0) } catch { close(fd); throw error }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ClosedLidFailure.locked }
        return ClosedLidOperationLock(fd)
    }
    public func acquireOperation() throws -> ClosedLidOperationLock {
        let dfd = try directoryFD(); defer { close(dfd) }
        return try lock(named: "writer.lock", directoryFD: dfd)
    }
    private func read(_ name: String, maximum: Int, directoryFD: Int32) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw ClosedLidFailure.insecureStorage }
        defer { close(fd) }
        let info = try verifyFile(fd, maximum: maximum)
        guard info.st_size > 0 else { throw ClosedLidFailure.corruptJournal }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size)); var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClosedLidFailure.corruptJournal }; offset += count
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw ClosedLidFailure.corruptJournal }
        return Data(bytes)
    }
    private func write(_ data: Data, named name: String, maximum: Int, directoryFD: Int32) throws {
        guard !data.isEmpty, data.count <= maximum else { throw ClosedLidFailure.corruptJournal }
        // Refuse to replace redirected or insecure existing destinations.
        _ = try read(name, maximum: maximum, directoryFD: directoryFD)
        let temporary = ".closed-lid-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClosedLidFailure.insecureStorage }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ClosedLidFailure.insecureStorage }; offset += count
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0,
              fsync(directoryFD) == 0 else { throw ClosedLidFailure.insecureStorage }
    }
    private func validate(_ record: ClosedLidRecord) throws {
        guard record.schemaVersion == 1, record.mechanism == ClosedLidLimits.mechanism,
              record.state.mechanism == ClosedLidLimits.mechanism, !record.bootID.isEmpty, record.bootID.utf8.count <= 128,
              record.state.generation < UInt64.max, record.requestIDs.count <= 128,
              Set(record.requestIDs).count == record.requestIDs.count, (0...3).contains(record.restoreAttempts),
              record.state.reason.map({ $0.utf8.count <= 2048 }) ?? true,
              [record.state.leaseDeadline, record.state.sessionDeadline, record.restoreIssuedAt, record.normalSleepIssuedAt].allSatisfy({ $0?.isFinite ?? true })
        else { throw ClosedLidFailure.corruptJournal }
        if record.state.normalSleepRequestAttempted != nil {
            guard record.state.restoreCommandAccepted, record.restoreReceipt?.disabled == false else { throw ClosedLidFailure.corruptJournal }
        }
        if record.state.normalSleepRequestAccepted != nil {
            guard record.state.normalSleepRequestAttempted == true else { throw ClosedLidFailure.corruptJournal }
        }
        if record.needsRecovery {
            guard record.state.sessionID != nil, record.state.ownerUserID == record.peer.userID,
                  record.state.sessionDeadline != nil, record.state.leaseDeadline != nil,
                  let baseline = record.baseline, baseline.bootID == record.bootID,
                  baseline.sleepAllowed, baseline.notificationBits & 2 != 0, baseline.notificationBits <= 3,
                  baseline.sequence > 0, baseline.receivedAt.isFinite, baseline.receivedAt >= 0,
                  baseline.source == "IOPM native clamshell-state notification" else { throw ClosedLidFailure.corruptJournal }
        }
        for receipt in [record.applyReceipt, record.restoreReceipt].compactMap({ $0 }) {
            guard receipt.acceptedAt.isFinite else { throw ClosedLidFailure.corruptJournal }
        }
    }
    @discardableResult public func transaction<T>(_ body: (inout ClosedLidRecord?, inout UUID) throws -> T) throws -> T {
        let dfd = try directoryFD(); defer { close(dfd) }
        let lock = try lock(named: "metadata.lock", directoryFD: dfd)
        return try withExtendedLifetime(lock) {
            let originalEpoch: UUID
            if let data = try read("authority.json", maximum: 512, directoryFD: dfd) {
                guard let authority = try? JSONDecoder().decode(LidAuthority.self, from: data), authority.schemaVersion == 1 else { throw ClosedLidFailure.corruptJournal }
                originalEpoch = authority.epoch
            } else {
                // Missing authority alongside ownership is corruption, never implicit reauthorization.
                guard try read("ownership.json", maximum: 65_536, directoryFD: dfd) == nil else { throw ClosedLidFailure.corruptJournal }
                originalEpoch = UUID()
                try write(JSONEncoder().encode(LidAuthority(epoch: originalEpoch)), named: "authority.json", maximum: 512, directoryFD: dfd)
            }
            var record: ClosedLidRecord?
            if let data = try read("ownership.json", maximum: 65_536, directoryFD: dfd) {
                guard let decoded = try? JSONDecoder().decode(ClosedLidRecord.self, from: data) else { throw ClosedLidFailure.corruptJournal }
                try validate(decoded); record = decoded
            }
            let original = record; var epoch = originalEpoch
            let result = try body(&record, &epoch)
            if let record { try validate(record) }
            guard original == nil || record != nil else { throw ClosedLidFailure.recoveryRequired }
            if epoch != originalEpoch { try write(JSONEncoder().encode(LidAuthority(epoch: epoch)), named: "authority.json", maximum: 512, directoryFD: dfd) }
            if let record, record != original { try write(JSONEncoder().encode(record), named: "ownership.json", maximum: 65_536, directoryFD: dfd) }
            return result
        }
    }
    public func load() throws -> ClosedLidRecord? { try transaction { record, _ in record } }
    func writePulse(_ pulse: ClosedLidGuardianPulse) throws {
        let dfd = try directoryFD(); defer { close(dfd) }
        let lock = try lock(named: "pulse.lock", directoryFD: dfd)
        try withExtendedLifetime(lock) { try write(JSONEncoder().encode(pulse), named: "guardian.json", maximum: 1024, directoryFD: dfd) }
    }
    func guardianReady(bootID: String, now: Double) throws -> Bool {
        let dfd = try directoryFD(); defer { close(dfd) }
        guard let data = try read("guardian.json", maximum: 1024, directoryFD: dfd) else { return false }
        guard let pulse = try? JSONDecoder().decode(ClosedLidGuardianPulse.self, from: data), pulse.schemaVersion == 1,
              pulse.role == "signed-closed-lid-guardian", pulse.receivedAt.isFinite else { throw ClosedLidFailure.corruptJournal }
        return pulse.bootID == bootID && now >= pulse.receivedAt && now - pulse.receivedAt <= ClosedLidLimits.guardianMaximumAge
            && pulse.processID > 0 && kill(pulse.processID, 0) == 0
            && (requiredOwner != 0 || pulse.processID != getpid())
    }
}
