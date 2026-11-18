// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import CoreData

/// Before an older schema is upgraded in place, a consistent single-file copy of it is kept next to the store
/// (`History.pre-v3.sqlite`), so a rollback to the previous app version can restore it
/// (`scripts/restore-history-backup.sh`). Never overwritten; removed after 30 days or at the next schema change.
enum HistoryMigrationBackup {
    static let retention: TimeInterval = 30 * 86400

    static func url(for store: URL, version: Int = HistorySchema.currentVersion) -> URL {
        store.deletingLastPathComponent().appendingPathComponent(store.deletingPathExtension().lastPathComponent + ".pre-v\(version).sqlite")
    }

    /// Makes sure a backup of the `version` store exists before it is migrated. An existing backup is kept as it is,
    /// provided it holds an older schema; anything else (a failed copy, a full disk, an unreadable old backup) throws
    /// `.migrationBackupFailed`, and the caller leaves the store unmigrated for this launch.
    static func ensure(for store: URL, version: Int) throws {
        let backup = url(for: store)
        let manager = FileManager.default
        if manager.fileExists(atPath: backup.path) {
            guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: backup,
                      options: [NSReadOnlyPersistentStoreOption: true]),
                  let existing = HistorySchema.compatibleVersion(metadata), existing < HistorySchema.currentVersion else {
                throw HistoryStoreError.migrationBackupFailed
            }
            return
        }
        let staging = store.deletingLastPathComponent().appendingPathComponent(".\(backup.lastPathComponent).\(UUID().uuidString).partial")
        defer { for suffix in ["", "-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: staging.path + suffix) } }
        do {
            let model = HistorySchema.model(version: version)
            // Read-only snapshot of the live store, WAL contents included, written as one rollback-journal file.
            try NSPersistentStoreCoordinator(managedObjectModel: model).replacePersistentStore(at: staging,
                destinationOptions: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]], withPersistentStoreFrom: store,
                sourceOptions: [NSReadOnlyPersistentStoreOption: true], ofType: NSSQLiteStoreType)
            let detached = NSPersistentStoreCoordinator(managedObjectModel: model)
            try detached.remove(try detached.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: staging,
                options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]))
            guard !manager.fileExists(atPath: staging.path + "-wal") else { throw HistoryStoreError.migrationBackupFailed }
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: staging,
                options: [NSReadOnlyPersistentStoreOption: true])
            guard HistorySchema.compatibleVersion(metadata) == version else { throw HistoryStoreError.migrationBackupFailed }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            // moveItem never replaces an existing file: a backup that appeared meanwhile is kept.
            try manager.moveItem(at: staging, to: backup)
        } catch { throw HistoryStoreError.migrationBackupFailed }
    }

    /// Deletes backups of an older schema step and backups older than 30 days.
    static func removeExpired(for store: URL, now: Date = Date()) {
        let manager = FileManager.default
        let directory = store.deletingLastPathComponent()
        let prefix = store.deletingPathExtension().lastPathComponent + ".pre-v"
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".sqlite") {
            let path = directory.appendingPathComponent(name).path
            let version = Int(name.dropFirst(prefix.count).dropLast(".sqlite".count))
            let created = (try? manager.attributesOfItem(atPath: path))?[.creationDate] as? Date
            let expired = created.map { now.timeIntervalSince($0) > retention } ?? false
            guard version != HistorySchema.currentVersion || expired else { continue }
            for suffix in ["", "-wal", "-shm", "-journal"] { try? manager.removeItem(atPath: path + suffix) }
        }
    }
}
