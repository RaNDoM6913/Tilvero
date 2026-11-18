// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import SQLite3

/// File-level SQLite work Core Data has no API for: page accounting, incremental vacuum, checkpoints, a full VACUUM.
/// Only called from inside the store's private queue, while its Core Data connection is idle; a busy database makes
/// a step fail quietly (it is retried at the next maintenance), never block.
enum HistorySQLiteFile {
    struct Pages: Equatable {
        let pageSize: Int64
        let pageCount: Int64
        let freePages: Int64
        let walBytes: Int64
        let databaseBytes: Int64
        /// Database plus write-ahead log, as Finder would count them.
        var fileBytes: Int64 { databaseBytes + walBytes }
        /// Pages holding data. `page_count` already includes pages that live only in the WAL, so the log is not added
        /// again; freed pages wait in the freelist until an (incremental) vacuum returns them.
        var usedBytes: Int64 { max(0, pageCount - freePages) * pageSize }
    }

    static func fileBytes(_ url: URL) -> Int64 { size(url.path) + size(url.path + "-wal") }

    static func size(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func pages(_ url: URL) -> Pages? {
        withConnection(url) { db in
            guard let pageSize = integer(db, "PRAGMA page_size"), let pageCount = integer(db, "PRAGMA page_count"),
                  let free = integer(db, "PRAGMA freelist_count") else { return nil }
            return Pages(pageSize: pageSize, pageCount: pageCount, freePages: free, walBytes: size(url.path + "-wal"),
                         databaseBytes: size(url.path))
        } ?? nil
    }

    static func autoVacuumMode(_ url: URL) -> Int64? { withConnection(url) { integer($0, "PRAGMA auto_vacuum") } ?? nil }

    /// Returns up to `pages` freed pages to the file system (all of them when nil), then truncates the WAL.
    @discardableResult static func incrementalVacuum(_ url: URL, pages: Int64?) -> Bool {
        withConnection(url) { db in
            let statement = pages.map { "PRAGMA incremental_vacuum(\(max(1, $0)))" } ?? "PRAGMA incremental_vacuum"
            guard drain(db, statement) else { return false }
            return drain(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        } ?? false
    }

    /// Rewrites the whole file. Converts a store whose auto_vacuum is not INCREMENTAL on the way.
    @discardableResult static func vacuum(_ url: URL) -> Bool {
        withConnection(url) { db in
            guard drain(db, "PRAGMA auto_vacuum = INCREMENTAL"), drain(db, "VACUUM") else { return false }
            return drain(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        } ?? false
    }

    private static func withConnection<T>(_ url: URL, _ body: (OpaquePointer) -> T) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        return body(db)
    }

    private static func integer(_ db: OpaquePointer, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { sqlite3_finalize(statement); return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    /// Steps a statement to completion (pragmas like incremental_vacuum return rows while they work).
    private static func drain(_ db: OpaquePointer, _ sql: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { sqlite3_finalize(statement); return false }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: continue
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }
}
