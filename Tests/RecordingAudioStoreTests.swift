import AVFoundation
import SwiftData
import XCTest
@testable import Seminarly

final class RecordingAudioStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testWAVPreservesEverySampleAcrossWriteBoundaries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = (0..<150_123).map { Float(sin(Double($0) * 0.137)) * 1.2 }
        let name = try XCTUnwrap(RecordingAudioStore.save(samples: samples, directory: directory))
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        var decoded: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            decoded.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(decoded.count, samples.count)
        XCTAssertTrue(decoded.elementsEqual(samples), "The WAV must preserve every Float32 sample")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [name])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEmptyRecordingDoesNotCreateAnAudioFile() throws {
        let directory = temporaryDirectory()
        XCTAssertNil(try RecordingAudioStore.save(samples: [], directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWriteFailurePropagatesWithoutPublishingAFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("occupied by a file".utf8).write(to: directory)
        XCTAssertThrowsError(try RecordingAudioStore.save(samples: [0.2], directory: directory))
        XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "occupied by a file")
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
