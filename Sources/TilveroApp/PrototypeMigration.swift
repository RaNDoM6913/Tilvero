import Foundation
import CryptoKit
import Darwin
import PowerPersistence

/// A first-launch boundary, never a continuous merge. Neither the legacy defaults nor store is modified.
@MainActor enum PrototypeMigration {
    struct Receipt: Codable, Equatable {
        let version: Int
        let migrationID: UUID
        let completedAt: Date
        let importedHistory: Bool
        let storeIdentifier: String?
        let saltDigest: String?
    }
    enum MigrationResult: Equatable {
        case notNeeded, migrated(Receipt), needsPrototypeQuit, conflictingIdentity
    }
    enum Checkpoint: String, Codable, CaseIterable {
        case journalPrepared, storeStaged, storeInstalled, saltCommitted, receiptWritten
    }
    @MainActor struct Environment {
        var sourcePreferences: [String: Any]
        var destinationPreferences: UserDefaults
        var sourceStore: URL
        var destinationStore: URL
        var isPrototypeRunning: () -> Bool
        var copyStore: @MainActor (URL, URL) throws -> Void = BatteryHistoryStore.copyForPrototypeMigration
        /// Called only after each durable transition; also permits bounded interruption fixtures.
        var onCheckpoint: (Checkpoint) throws -> Void = { _ in }
    }
    enum MigrationError: Error { case invalidJournal, persistenceFailed, migrationAlreadyRunning }

    // Identity is handled separately from ordinary destination-wins preferences.
    private static let ordinaryKeys = ["language", "fahrenheit", "historyEnabled", "retentionDays",
        "menuBarTextSize", "menuBarIconScale", "menuBarDisplayStyle", "lastSection"]
    private struct Journal: Codable {
        let version: Int
        let id: UUID
        let sourcePath: String
        let destinationPath: String
        let salt: String?
        let importedHistory: Bool
        var storeIdentifier: String?
        var checkpoint: Checkpoint
    }

    static func prepare(environment e: Environment) throws -> MigrationResult {
        let fm = FileManager.default
        let directory = e.destinationStore.deletingLastPathComponent()
        let journalURL = directory.appendingPathComponent("PrototypeMigration.journal.json")
        let receiptURL = directory.appendingPathComponent("PrototypeMigration.receipt.json")
        let hasJournal = fm.fileExists(atPath: journalURL.path)
        let hasReceipt = fm.fileExists(atPath: receiptURL.path)
        let hasDestination = fm.fileExists(atPath: e.destinationStore.path)
        let hasSource = fm.fileExists(atPath: e.sourceStore.path)
        let destinationSalt = e.destinationPreferences.object(forKey: "identitySalt")
        let legacySalt = validSalt(e.sourcePreferences["identitySalt"])

        guard e.sourceStore.resolvingSymlinksInPath().standardizedFileURL != e.destinationStore.resolvingSymlinksInPath().standardizedFileURL else {
            throw MigrationError.invalidJournal
        }
        if hasSource && hasDestination {
            let sourceAttributes = try fm.attributesOfItem(atPath: e.sourceStore.path)
            let destinationAttributes = try fm.attributesOfItem(atPath: e.destinationStore.path)
            if sourceAttributes[.systemNumber] as? NSNumber == destinationAttributes[.systemNumber] as? NSNumber,
               sourceAttributes[.systemFileNumber] as? NSNumber == destinationAttributes[.systemFileNumber] as? NSNumber {
                throw MigrationError.invalidJournal
            }
        }
        if !hasJournal && !hasReceipt && !hasDestination {
            if destinationSalt != nil && validSalt(destinationSalt) == nil { return .conflictingIdentity }
            if hasSource && (legacySalt == nil || (destinationSalt != nil && destinationSalt as? String != legacySalt)) {
                return .conflictingIdentity
            }
            if !hasSource, let legacySalt, destinationSalt != nil && destinationSalt as? String != legacySalt {
                return .conflictingIdentity
            }
            guard hasSource || legacySalt != nil || ordinaryKeys.contains(where: { e.sourcePreferences[$0] != nil }) else { return .notNeeded }
            // Do not create destination defaults, a directory or a journal while the prototype runs.
            guard !e.isPrototypeRunning() else { return .needsPrototypeQuit }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent(".prototype-migration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw MigrationError.persistenceFailed }
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MigrationError.migrationAlreadyRunning }

        // Re-read after lock acquisition; another launch may have completed first.
        if !fm.fileExists(atPath: journalURL.path), !fm.fileExists(atPath: receiptURL.path),
           fm.fileExists(atPath: e.destinationStore.path) {
            // Never reinterpret a pre-existing production store under the prototype's salt.
            guard validSalt(e.destinationPreferences.object(forKey: "identitySalt")) != nil else { return .conflictingIdentity }
            return .notNeeded
        }
        if !fm.fileExists(atPath: journalURL.path), fm.fileExists(atPath: receiptURL.path) {
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.version == 1,
                  receipt.saltDigest == digest(validSalt(e.destinationPreferences.object(forKey: "identitySalt"))) else {
                return .conflictingIdentity
            }
            if receipt.importedHistory {
                guard fm.fileExists(atPath: e.destinationStore.path),
                      try BatteryHistoryStore.persistentStoreIdentifier(at: e.destinationStore) == receipt.storeIdentifier else {
                    return .conflictingIdentity
                }
            }
            return .notNeeded
        }
        var journal: Journal
        if fm.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard journal.version == 1, journal.sourcePath == e.sourceStore.standardizedFileURL.path,
                  journal.destinationPath == e.destinationStore.standardizedFileURL.path,
                  !journal.importedHistory || validSalt(journal.salt) != nil else { throw MigrationError.invalidJournal }
        } else {
            // A store which appeared since the pre-lock check is not ours to replace.
            guard !fm.fileExists(atPath: e.destinationStore.path) else { return .conflictingIdentity }
            guard !e.isPrototypeRunning() else { return .needsPrototypeQuit }
            journal = Journal(version: 1, id: UUID(), sourcePath: e.sourceStore.standardizedFileURL.path,
                destinationPath: e.destinationStore.standardizedFileURL.path, salt: legacySalt ?? validSalt(destinationSalt) ?? UUID().uuidString,
                importedHistory: hasSource, storeIdentifier: nil, checkpoint: .journalPrepared)
            try write(journal, to: journalURL)
            try e.onCheckpoint(.journalPrepared)
        }
        if let existing = e.destinationPreferences.object(forKey: "identitySalt"), let salt = journal.salt,
           existing as? String != salt { return .conflictingIdentity }
        let stagingDirectory = directory.appendingPathComponent(".prototype-import-\(journal.id.uuidString)")
        let stagingStore = stagingDirectory.appendingPathComponent("History.sqlite")

        if !journal.importedHistory && fm.fileExists(atPath: e.destinationStore.path) { return .conflictingIdentity }
        if journal.checkpoint == .journalPrepared {
            guard !e.isPrototypeRunning() else { return .needsPrototypeQuit }
            guard !fm.fileExists(atPath: e.destinationStore.path) else { return .conflictingIdentity }
            if fm.fileExists(atPath: stagingDirectory.path) { try fm.removeItem(at: stagingDirectory) }
            if journal.importedHistory {
                try e.copyStore(e.sourceStore, stagingStore)
                journal.storeIdentifier = try BatteryHistoryStore.persistentStoreIdentifier(at: stagingStore)
                let stagedFile = try FileHandle(forWritingTo: stagingStore)
                defer { try? stagedFile.close() }
                try stagedFile.synchronize()
                try synchronizeDirectory(stagingDirectory)
            }
            journal.checkpoint = .storeStaged
            try write(journal, to: journalURL)
            try e.onCheckpoint(.storeStaged)
        }
        if journal.checkpoint == .storeStaged {
            if journal.importedHistory {
                if fm.fileExists(atPath: e.destinationStore.path) {
                    // Covers a crash after rename but before advancing the journal.
                    guard try BatteryHistoryStore.persistentStoreIdentifier(at: e.destinationStore) == journal.storeIdentifier else {
                        return .conflictingIdentity
                    }
                } else {
                    guard !e.isPrototypeRunning() else { return .needsPrototypeQuit }
                    guard try BatteryHistoryStore.persistentStoreIdentifier(at: stagingStore) == journal.storeIdentifier else {
                        throw MigrationError.invalidJournal
                    }
                    try fm.moveItem(at: stagingStore, to: e.destinationStore)
                    try synchronizeDirectory(directory)
                }
            }
            journal.checkpoint = .storeInstalled
            try write(journal, to: journalURL)
            try e.onCheckpoint(.storeInstalled)
        }
        if journal.importedHistory {
            guard fm.fileExists(atPath: e.destinationStore.path),
                  try BatteryHistoryStore.persistentStoreIdentifier(at: e.destinationStore) == journal.storeIdentifier else {
                return .conflictingIdentity
            }
        }
        if journal.checkpoint == .storeInstalled {
            if let salt = journal.salt { e.destinationPreferences.set(salt, forKey: "identitySalt") }
            guard e.destinationPreferences.synchronize() else { throw MigrationError.persistenceFailed }
            journal.checkpoint = .saltCommitted
            try write(journal, to: journalURL)
            try e.onCheckpoint(.saltCommitted)
        }
        // Recovery never exposes a store whose committed salt has been removed or changed.
        guard journal.salt == nil || e.destinationPreferences.string(forKey: "identitySalt") == journal.salt else {
            return .conflictingIdentity
        }
        for key in ordinaryKeys where e.destinationPreferences.object(forKey: key) == nil {
            if let value = e.sourcePreferences[key] { e.destinationPreferences.set(value, forKey: key) }
        }
        guard e.destinationPreferences.synchronize() else { throw MigrationError.persistenceFailed }
        let receipt: Receipt
        if fm.fileExists(atPath: receiptURL.path) {
            receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.migrationID == journal.id, receipt.storeIdentifier == journal.storeIdentifier,
                  receipt.saltDigest == digest(journal.salt) else { throw MigrationError.invalidJournal }
        } else {
            receipt = Receipt(version: 1, migrationID: journal.id, completedAt: Date(), importedHistory: journal.importedHistory,
                storeIdentifier: journal.storeIdentifier, saltDigest: digest(journal.salt))
            try write(receipt, to: receiptURL)
        }
        try e.onCheckpoint(.receiptWritten)
        if fm.fileExists(atPath: stagingDirectory.path) { try fm.removeItem(at: stagingDirectory) }
        try fm.removeItem(at: journalURL)
        try synchronizeDirectory(directory)
        return .migrated(receipt)
    }

    private static func validSalt(_ value: Any?) -> String? {
        guard let salt = value as? String, UUID(uuidString: salt) != nil else { return nil }
        return salt
    }
    private static func digest(_ salt: String?) -> String? {
        salt.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }
    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MigrationError.persistenceFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MigrationError.persistenceFailed }
    }
}
