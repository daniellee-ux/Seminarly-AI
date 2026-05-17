import Foundation

enum DatabaseStore {
    enum LegacyMigrationResult: Equatable {
        case migrated(meetingCount: Int)
        case targetAlreadyExists
        case noLegacyStore
        case legacyStoreHasNoMeetings
    }

    static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Seminarly", isDirectory: true)
    }

    static var storeURL: URL {
        appSupportDirectory.appendingPathComponent("default.store")
    }

    static var legacyStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("default.store")
    }

    static var backupDirectory: URL {
        appSupportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    static var quarantineDirectory: URL {
        appSupportDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    static func relatedFiles(for storeURL: URL) -> [URL] {
        let storePath = storeURL.path
        return [
            storeURL,
            URL(fileURLWithPath: storePath + "-shm"),
            URL(fileURLWithPath: storePath + "-wal"),
        ]
    }

    /// Copies data out of the old generic SwiftData default path into Seminarly's
    /// app-owned directory. The legacy store is left intact; this migration exists
    /// only to escape a path collision, not to mutate the old database.
    @discardableResult
    static func migrateLegacyStoreIfNeeded(
        fileManager fm: FileManager = .default,
        legacyStoreURL: URL = DatabaseStore.legacyStoreURL,
        targetStoreURL: URL = DatabaseStore.storeURL
    ) throws -> LegacyMigrationResult {
        let targetDirectory = targetStoreURL.deletingLastPathComponent()
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        guard !fm.fileExists(atPath: targetStoreURL.path) else {
            return .targetAlreadyExists
        }
        guard fm.fileExists(atPath: legacyStoreURL.path) else {
            return .noLegacyStore
        }

        let meetingCount = DatabaseCheckpoint.meetingCount(at: legacyStoreURL) ?? 0
        guard meetingCount > 0 else {
            return .legacyStoreHasNoMeetings
        }

        try copyStoreFiles(from: legacyStoreURL, to: targetStoreURL, fileManager: fm)
        return .migrated(meetingCount: meetingCount)
    }

    static func copyStoreFiles(
        from sourceStoreURL: URL,
        to targetStoreURL: URL,
        fileManager fm: FileManager = .default
    ) throws {
        try fm.createDirectory(at: targetStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceFiles = relatedFiles(for: sourceStoreURL)
        let targetFiles = relatedFiles(for: targetStoreURL)

        for target in targetFiles where fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }

        for (source, target) in zip(sourceFiles, targetFiles) where fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: target)
        }
    }
}
