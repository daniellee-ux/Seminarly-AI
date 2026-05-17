import Foundation
import SQLite3
import os

/// Low-level SQLite operations SwiftData doesn't expose.
///
/// SwiftData uses SQLite in WAL mode. Committed rows live in the `-wal` sidecar file
/// until a checkpoint flushes them into the main `.store` file. If the process is
/// killed (Xcode ⌘., hard reboot) before a checkpoint, the WAL contains real data
/// that a subsequent open must recover. Any logic that *deletes* the WAL in a recovery
/// path destroys those rows. This type provides the primitives to (1) force checkpoints
/// while the app runs and at quit time, and (2) move a WAL aside non-destructively when
/// an open attempt fails.
enum DatabaseCheckpoint {
    private static let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "Checkpoint")

    enum Mode {
        case passive
        case full
        case truncate

        var pragma: String {
            switch self {
            case .passive:  return "PRAGMA wal_checkpoint(PASSIVE);"
            case .full:     return "PRAGMA wal_checkpoint(FULL);"
            case .truncate: return "PRAGMA wal_checkpoint(TRUNCATE);"
            }
        }
    }

    /// Force a WAL checkpoint on the store at `storeURL`. Safe to call while SwiftData
    /// has the same file open — SQLite's WAL mode allows multiple connections.
    /// `.passive` is non-blocking; `.truncate` blocks until the WAL is drained and zeroed.
    @discardableResult
    static func performCheckpoint(at storeURL: URL, mode: Mode = .passive) -> Bool {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { if db != nil { sqlite3_close_v2(db) } }

        guard openResult == SQLITE_OK, let db else {
            logger.error("Checkpoint open failed (\(openResult)) for \(storeURL.path)")
            return false
        }

        var errMsg: UnsafeMutablePointer<CChar>?
        let execResult = sqlite3_exec(db, mode.pragma, nil, nil, &errMsg)
        if let errMsg {
            let message = String(cString: errMsg)
            sqlite3_free(errMsg)
            logger.error("Checkpoint exec failed: \(message)")
            return false
        }
        return execResult == SQLITE_OK
    }

    /// Move `-wal` and `-shm` sidecars into a timestamped folder under `Quarantine/`.
    /// Non-destructive: the original data is moved, never deleted. Returns the
    /// quarantine directory if anything was moved, or nil if there were no sidecars
    /// to move.
    @discardableResult
    static func quarantineWAL(storeURL: URL) -> URL? {
        let fm = FileManager.default
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")

        let hasWAL = fm.fileExists(atPath: walURL.path)
        let hasSHM = fm.fileExists(atPath: shmURL.path)
        guard hasWAL || hasSHM else { return nil }

        let quarantineRoot = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Quarantine", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dest = quarantineRoot.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if hasWAL {
                try fm.moveItem(at: walURL, to: dest.appendingPathComponent(walURL.lastPathComponent))
            }
            if hasSHM {
                try fm.moveItem(at: shmURL, to: dest.appendingPathComponent(shmURL.lastPathComponent))
            }
            logger.notice("Quarantined WAL to \(dest.path)")
            return dest
        } catch {
            logger.error("Quarantine failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Read-only meeting count in the given store file. Returns nil if the file can't
    /// be opened or `ZMEETING` is missing. Used by the Restore flow to pick the most
    /// recent *non-empty* backup rather than blindly taking the latest one.
    static func meetingCount(at storeURL: URL) -> Int? {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { if db != nil { sqlite3_close_v2(db) } }

        guard openResult == SQLITE_OK, let db else { return nil }

        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZMEETING;", -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }

        guard prepResult == SQLITE_OK, let stmt else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
