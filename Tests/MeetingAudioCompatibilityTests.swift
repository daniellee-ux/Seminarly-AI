import SwiftData
import XCTest
@testable import Seminarly

final class MeetingAudioCompatibilityTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @MainActor
    func testAudioReferencePersistsAndLegacySourceTracksRemainIndependent() throws {
        let directory = temporaryDirectory()
        // SwiftData may keep its SQLite connections alive beyond this scope;
        // leave this unique temporary store for OS cleanup.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: SeminarlyApp.schema,
                                               url: directory.appendingPathComponent("test.store"))
        let container = try ModelContainer(for: SeminarlyApp.schema, migrationPlan: SeminarlyMigrationPlan.self, configurations: [configuration])
        let meeting = Meeting(title: "Audio reference fixture")
        XCTAssertNil(meeting.transcriptionAudioURL)
        meeting.transcriptionAudioPath = "fixture.transcription.wav"
        container.mainContext.insert(meeting)
        try container.mainContext.save()
        let reread = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Meeting>()).first)
        XCTAssertEqual(reread.transcriptionAudioURL, Meeting.audioDirectory.appendingPathComponent("fixture.transcription.wav"))
        XCTAssertNil(reread.systemAudioPath)
        XCTAssertNil(reread.micAudioPath)
        XCTAssertFalse(reread.hasRediarizationData)
        XCTAssertTrue(reread.hasAudioData)
        reread.transcriptionAudioPath = "../outside.wav"
        XCTAssertNil(reread.transcriptionAudioURL)
    }

    @MainActor
    func testPreviousAppDatabaseMigratesWithoutLosingSessions() throws {
        guard let path = ProcessInfo.processInfo.environment["SEMINARLY_AUDIO_MIGRATION_FIXTURE"] else {
            throw XCTSkip("Set SEMINARLY_AUDIO_MIGRATION_FIXTURE to an expendable copy of the previous app database")
        }
        let url = URL(fileURLWithPath: path)
        let count = try XCTUnwrap(DatabaseCheckpoint.meetingCount(at: url))
        XCTAssertGreaterThan(count, 0)
        let configuration = ModelConfiguration(schema: SeminarlyApp.schema, url: url)
        let container = try ModelContainer(for: SeminarlyApp.schema, migrationPlan: SeminarlyMigrationPlan.self, configurations: [configuration])
        let meetings = try container.mainContext.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, count)
        XCTAssertTrue(meetings.allSatisfy { $0.transcriptionAudioPath == nil })
        XCTAssertTrue(meetings.contains { $0.transcript != nil })
    }
}
