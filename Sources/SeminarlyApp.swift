import SwiftUI
import SwiftData
import AppKit
import os

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "Database")

@Observable
final class AppState {
    var isRecording = false
    var isPaused = false
    /// True only while RecordingView is mounted in its post-recording (saved)
    /// state, i.e. its `savedMeeting` is set. Lets ContentView tell a *finished*
    /// recording (rebuild fresh on the next "Record") apart from a setup,
    /// recording, or still-finalizing view (all of which must be preserved) —
    /// none of which are distinguishable from `isRecording`/`isPaused` alone.
    var recordingSaved = false
    var recordingElapsedTime: TimeInterval = 0
}

@Observable
final class DatabaseState {
    var error: DatabaseError?
    var isUsingInMemoryFallback = false

    enum DatabaseError {
        case failedToOpen(underlyingError: String)
        case recoveredByQuarantine(quarantineURL: URL)
    }

    var hasError: Bool { error != nil }
}

/// Exists solely to force a WAL checkpoint when the app quits. SwiftUI's `scenePhase`
/// does not reliably fire `.background` on macOS app termination, but
/// `NSApplicationDelegate.applicationWillTerminate` does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Path to the SwiftData store. We compute this from `FileManager` rather than
    /// `ModelConfiguration(...).url` because `ModelConfiguration` is `@MainActor`-isolated
    /// and this static needs to be reachable from nonisolated contexts (the raw SQLite
    /// checkpoint path).
    static let storeURL = DatabaseStore.storeURL

    func applicationWillTerminate(_ notification: Notification) {
        let success = DatabaseCheckpoint.performCheckpoint(at: Self.storeURL, mode: .truncate)
        logger.notice("applicationWillTerminate checkpoint success=\(success, privacy: .public)")
    }
}

@main
struct SeminarlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    static let schema = Schema([Meeting.self, Transcript.self, StructuredNote.self])

    let modelContainer: ModelContainer
    let databaseState = DatabaseState()
    let appState = AppState()

    init() {
        do {
            let migrationResult = try DatabaseStore.migrateLegacyStoreIfNeeded()
            if case .migrated(let meetingCount) = migrationResult {
                logger.notice("Migrated \(meetingCount, privacy: .public) meetings from legacy global store to \(DatabaseStore.storeURL.path, privacy: .public)")
            }
        } catch {
            logger.error("Legacy store migration failed: \(error.localizedDescription, privacy: .public)")
        }

        let storeURL = DatabaseStore.storeURL
        let config = ModelConfiguration(schema: SeminarlyApp.schema, url: storeURL)

        // Try to open. On failure, quarantine `-wal`/`-shm` (moved, not deleted) and retry
        // once. Quarantine preserves the committed-but-not-checkpointed rows so they can
        // be forensically recovered later instead of being permanently lost.
        do {
            modelContainer = try ModelContainer(
                for: SeminarlyApp.schema,
                migrationPlan: SeminarlyMigrationPlan.self,
                configurations: [config]
            )
            // Backup only after a known-good open. Backing up before an attempt (the
            // prior implementation) preserved corrupted states and overwrote good ones.
            SeminarlyApp.backupDatabase(storeURL: storeURL)
            SeminarlyApp.rotateBackups(keeping: 30)
        } catch {
            logger.error("ModelContainer open failed: \(error.localizedDescription)")

            if let quarantineURL = DatabaseCheckpoint.quarantineWAL(storeURL: storeURL) {
                do {
                    modelContainer = try ModelContainer(
                        for: SeminarlyApp.schema,
                        migrationPlan: SeminarlyMigrationPlan.self,
                        configurations: [config]
                    )
                    logger.notice("Recovered after quarantining WAL to \(quarantineURL.path, privacy: .public)")
                    databaseState.error = .recoveredByQuarantine(quarantineURL: quarantineURL)
                    SeminarlyApp.backupDatabase(storeURL: storeURL)
                    SeminarlyApp.rotateBackups(keeping: 30)
                    return
                } catch {
                    logger.error("Retry after quarantine failed: \(error.localizedDescription)")
                }
            }

            // Both attempts failed. Fall through to an in-memory container so the UI
            // can render a blocking error screen with Restore / Start Fresh / Quit.
            // On-disk files (including the quarantined WAL) are preserved.
            logger.error("Falling back to in-memory container — on-disk data NOT deleted")
            databaseState.error = .failedToOpen(underlyingError: error.localizedDescription)
            databaseState.isUsingInMemoryFallback = true

            let inMemoryConfig = ModelConfiguration(schema: SeminarlyApp.schema, isStoredInMemoryOnly: true)
            do {
                modelContainer = try ModelContainer(for: SeminarlyApp.schema, configurations: [inMemoryConfig])
            } catch {
                fatalError("Failed to create even in-memory ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(SeminarlyColors.accent)
                .environment(databaseState)
                .environment(appState)
        }
        .defaultSize(width: 1000, height: 650)
        .modelContainer(modelContainer)
        .commands {
            // Sits right under "About Seminarly" in the app menu — the conventional
            // spot for "Check for Updates…". Manual checks report every outcome.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates(mode: .manual)
                }
            }
        }

        MenuBarExtra("Seminarly", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(appState)
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Backup management

    static var backupDirectory: URL {
        DatabaseStore.backupDirectory
    }

    static func backupDatabase(storeURL: URL, backupDirectory: URL = DatabaseStore.backupDirectory) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return }
        let meetingCount = DatabaseCheckpoint.meetingCount(at: storeURL) ?? 0
        guard meetingCount > 0 else {
            logger.notice("Skipping database backup because store has no meetings: \(storeURL.path, privacy: .public) meetings=\(meetingCount, privacy: .public)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamped = backupDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fm.createDirectory(at: timestamped, withIntermediateDirectories: true)
            for file in DatabaseStore.relatedFiles(for: storeURL) where fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: file, to: timestamped.appendingPathComponent(file.lastPathComponent))
            }
            logger.info("Database backed up to \(timestamped.path, privacy: .public) meetings=\(meetingCount, privacy: .public)")
        } catch {
            logger.error("Backup failed: \(error.localizedDescription)")
        }
    }

    static func rotateBackups(keeping maxCount: Int, in backupDirectory: URL = DatabaseStore.backupDirectory) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = contents.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return aDate > bDate
        }

        guard sorted.count > maxCount else { return }
        var retained = Set(sorted.prefix(maxCount))
        if let latestNonEmpty = sorted.first(where: { candidate in
            let candidateStore = candidate.appendingPathComponent("default.store")
            return (DatabaseCheckpoint.meetingCount(at: candidateStore) ?? 0) > 0
        }) {
            retained.insert(latestNonEmpty)
        }

        for stale in sorted where !retained.contains(stale) {
            try? fm.removeItem(at: stale)
        }
    }

    /// Restore the most recent backup whose store file contains at least one meeting,
    /// falling back to the most recent backup if none are non-empty. Returns true if
    /// any files were copied into place.
    static func restoreLatestBackup(to storeURL: URL, from backupDirectory: URL = DatabaseStore.backupDirectory) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return false }

        let sorted = contents.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return aDate > bDate
        }
        guard !sorted.isEmpty else { return false }

        let backupToRestore: URL = sorted.first { candidate in
            let candidateStore = candidate.appendingPathComponent("default.store")
            return (DatabaseCheckpoint.meetingCount(at: candidateStore) ?? 0) > 0
        } ?? sorted[0]

        for file in DatabaseStore.relatedFiles(for: storeURL) {
            try? fm.removeItem(at: file)
        }

        do {
            let backupFiles = try fm.contentsOfDirectory(at: backupToRestore, includingPropertiesForKeys: nil)
            for file in backupFiles {
                try fm.copyItem(at: file, to: storeURL.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent))
            }
            logger.info("Restored backup from \(backupToRestore.lastPathComponent, privacy: .public)")
            return true
        } catch {
            logger.error("Restore failed: \(error.localizedDescription)")
            return false
        }
    }

    static func deleteStoreAndRestart(storeURL: URL) {
        let fm = FileManager.default
        for file in DatabaseStore.relatedFiles(for: storeURL) {
            try? fm.removeItem(at: file)
        }
        logger.info("Database deleted by user request — restarting")
    }
}
