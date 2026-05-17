import XCTest
import SQLite3
@testable import Seminarly

final class DatabaseRecoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SeminarlyDBTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - performCheckpoint

    func testTruncateCheckpointDrainsWALWhileOtherConnectionHeld() throws {
        let storeURL = tempDir.appendingPathComponent("test.store")
        // Keep the seed connection OPEN through the test, otherwise sqlite3_close_v2
        // auto-checkpoints and the WAL is already empty before our code runs.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                       SQLITE_OK)
        defer { if db != nil { sqlite3_close_v2(db) } }
        try seed(db: db, meetingCount: 3)

        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let walSizeBefore = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(walSizeBefore, 0, "seed should produce a non-empty WAL")

        XCTAssertTrue(DatabaseCheckpoint.performCheckpoint(at: storeURL, mode: .truncate))

        let walSizeAfter = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int ?? -1
        XCTAssertEqual(walSizeAfter, 0, "TRUNCATE should zero the WAL file")

        XCTAssertEqual(DatabaseCheckpoint.meetingCount(at: storeURL), 3)
    }

    func testPassiveCheckpointPreservesRows() throws {
        let storeURL = tempDir.appendingPathComponent("test.store")
        try seedStoreAndClose(at: storeURL, meetingCount: 5)

        XCTAssertTrue(DatabaseCheckpoint.performCheckpoint(at: storeURL, mode: .passive))
        XCTAssertEqual(DatabaseCheckpoint.meetingCount(at: storeURL), 5)
    }

    func testCheckpointFailsGracefullyOnMissingFile() {
        let missing = tempDir.appendingPathComponent("no-such.store")
        let ok = DatabaseCheckpoint.performCheckpoint(at: missing, mode: .truncate)
        XCTAssertFalse(ok)
    }

    // MARK: - quarantineWAL

    func testQuarantineMovesSidecarsIntoTimestampedFolder() throws {
        let storeURL = tempDir.appendingPathComponent("test.store")
        try "".write(to: storeURL, atomically: true, encoding: .utf8)
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try "wal-bytes".write(to: walURL, atomically: true, encoding: .utf8)
        try "shm-bytes".write(to: shmURL, atomically: true, encoding: .utf8)

        guard let quarantineDir = DatabaseCheckpoint.quarantineWAL(storeURL: storeURL) else {
            XCTFail("Quarantine returned nil")
            return
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path),
                       "original WAL should be moved, not copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path),
                       "original SHM should be moved, not copied")

        let movedWAL = quarantineDir.appendingPathComponent("test.store-wal")
        let movedSHM = quarantineDir.appendingPathComponent("test.store-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedWAL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSHM.path))

        // Store file itself is untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testQuarantineReturnsNilWhenNoSidecars() throws {
        let storeURL = tempDir.appendingPathComponent("test.store")
        try "".write(to: storeURL, atomically: true, encoding: .utf8)
        XCTAssertNil(DatabaseCheckpoint.quarantineWAL(storeURL: storeURL))
    }

    // MARK: - meetingCount

    func testMeetingCountReadsRows() throws {
        let storeURL = tempDir.appendingPathComponent("test.store")
        try seedStoreAndClose(at: storeURL, meetingCount: 7)
        XCTAssertEqual(DatabaseCheckpoint.meetingCount(at: storeURL), 7)
    }

    func testMeetingCountReturnsNilOnMissingTable() throws {
        let storeURL = tempDir.appendingPathComponent("empty.store")
        // Create an empty but valid SQLite DB (no ZMEETING table)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                       SQLITE_OK)
        if db != nil { sqlite3_close_v2(db) }
        XCTAssertNil(DatabaseCheckpoint.meetingCount(at: storeURL))
    }

    func testMeetingCountReturnsNilOnMissingFile() {
        let missing = tempDir.appendingPathComponent("no-such.store")
        XCTAssertNil(DatabaseCheckpoint.meetingCount(at: missing))
    }

    // MARK: - DatabaseStore

    func testLegacyStoreMigratesIntoAppOwnedStore() throws {
        let legacyStore = tempDir.appendingPathComponent("default.store")
        let targetStore = tempDir
            .appendingPathComponent("Seminarly", isDirectory: true)
            .appendingPathComponent("default.store")
        try seedStoreAndClose(at: legacyStore, meetingCount: 2)

        let result = try DatabaseStore.migrateLegacyStoreIfNeeded(
            legacyStoreURL: legacyStore,
            targetStoreURL: targetStore
        )

        XCTAssertEqual(result, .migrated(meetingCount: 2))
        XCTAssertEqual(DatabaseCheckpoint.meetingCount(at: targetStore), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))
    }

    func testLegacyStoreMigrationSkipsEmptyStore() throws {
        let legacyStore = tempDir.appendingPathComponent("default.store")
        let targetStore = tempDir
            .appendingPathComponent("Seminarly", isDirectory: true)
            .appendingPathComponent("default.store")
        try seedStoreAndClose(at: legacyStore, meetingCount: 0)

        let result = try DatabaseStore.migrateLegacyStoreIfNeeded(
            legacyStoreURL: legacyStore,
            targetStoreURL: targetStore
        )

        XCTAssertEqual(result, .legacyStoreHasNoMeetings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetStore.path))
    }

    func testLegacyStoreMigrationSkipsWhenTargetAlreadyExists() throws {
        let legacyStore = tempDir.appendingPathComponent("default.store")
        let targetStore = tempDir
            .appendingPathComponent("Seminarly", isDirectory: true)
            .appendingPathComponent("default.store")
        try seedStoreAndClose(at: legacyStore, meetingCount: 2)
        try FileManager.default.createDirectory(
            at: targetStore.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try seedStoreAndClose(at: targetStore, meetingCount: 1)

        let result = try DatabaseStore.migrateLegacyStoreIfNeeded(
            legacyStoreURL: legacyStore,
            targetStoreURL: targetStore
        )

        XCTAssertEqual(result, .targetAlreadyExists)
        XCTAssertEqual(DatabaseCheckpoint.meetingCount(at: targetStore), 1)
    }

    func testLegacyStoreMigrationSkipsWhenLegacyStoreIsMissing() throws {
        let legacyStore = tempDir.appendingPathComponent("default.store")
        let targetStore = tempDir
            .appendingPathComponent("Seminarly", isDirectory: true)
            .appendingPathComponent("default.store")

        let result = try DatabaseStore.migrateLegacyStoreIfNeeded(
            legacyStoreURL: legacyStore,
            targetStoreURL: targetStore
        )

        XCTAssertEqual(result, .noLegacyStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetStore.path))
    }

    // MARK: - Backup hardening

    @MainActor
    func testBackupSkipsEmptyStores() throws {
        let storeURL = tempDir.appendingPathComponent("empty.store")
        let backupDir = tempDir.appendingPathComponent("Backups", isDirectory: true)
        try seedStoreAndClose(at: storeURL, meetingCount: 0)

        SeminarlyApp.backupDatabase(storeURL: storeURL, backupDirectory: backupDir)

        let backups = try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(backups?.isEmpty ?? true)
    }

    @MainActor
    func testRotateBackupsRetainsLatestNonEmptyOutsideWindow() throws {
        let backupDir = tempDir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let newestEmpty = try makeBackup(named: "newest-empty", meetingCount: 0, createdAt: 4, in: backupDir)
        let secondEmpty = try makeBackup(named: "second-empty", meetingCount: 0, createdAt: 3, in: backupDir)
        let staleEmpty = try makeBackup(named: "stale-empty", meetingCount: 0, createdAt: 2, in: backupDir)
        let latestNonEmpty = try makeBackup(named: "latest-non-empty", meetingCount: 1, createdAt: 1, in: backupDir)

        SeminarlyApp.rotateBackups(keeping: 2, in: backupDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: newestEmpty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondEmpty.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleEmpty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestNonEmpty.path))
    }

    // MARK: - Helpers

    /// Opens, seeds, and closes a WAL-mode SQLite DB. Closing auto-checkpoints so the
    /// WAL ends up empty — use this when you only care about `ZMEETING` contents.
    private func seedStoreAndClose(at storeURL: URL, meetingCount: Int) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
                       SQLITE_OK)
        try seed(db: db, meetingCount: meetingCount)
        if db != nil { sqlite3_close_v2(db) }
    }

    /// Seeds an already-open DB handle with a ZMEETING table in WAL mode.
    private func seed(db: OpaquePointer?, meetingCount: Int) throws {
        for sql in [
            "PRAGMA journal_mode=WAL;",
            "CREATE TABLE ZMEETING (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        for i in 0..<meetingCount {
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO ZMEETING (ZTITLE) VALUES ('m\(i)');", nil, nil, nil),
                SQLITE_OK
            )
        }
    }

    @discardableResult
    private func makeBackup(
        named name: String,
        meetingCount: Int,
        createdAt timestamp: TimeInterval,
        in backupDir: URL
    ) throws -> URL {
        let dir = backupDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedStoreAndClose(at: dir.appendingPathComponent("default.store"), meetingCount: meetingCount)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: timestamp)],
            ofItemAtPath: dir.path
        )
        return dir
    }
}
