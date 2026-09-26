import XCTest
@testable import Seminarly

final class DiarizationAudioTests: XCTestCase {
    func testSilentSystemAndMicrophoneOnlyTailUseMicrophoneSource() {
        let silence = [Float](repeating: 0, count: 10)
        let mic = [Float](repeating: 0.2, count: 20)
        XCTAssertEqual(DiarizationAudio.preferredSource(start: 0, end: 1, system: silence, microphone: mic, sampleRate: 10), .microphone)
        XCTAssertEqual(DiarizationAudio.preferredSource(start: 1, end: 2, system: silence, microphone: mic, sampleRate: 10), .microphone)
        XCTAssertEqual(DiarizationAudio.preferredSource(start: 0, end: 2, system: [], microphone: mic, sampleRate: 10), .microphone)
    }

    func testSilenceAndAttenuatedEchoDoNotBecomeLocalSpeech() {
        let remote = [Float](repeating: 0.5, count: 10)
        let echo = [Float](repeating: 0.05, count: 10)
        XCTAssertEqual(DiarizationAudio.preferredSource(start: 0, end: 1, system: remote, microphone: echo, sampleRate: 10), .system)
        XCTAssertNil(DiarizationAudio.preferredSource(start: 0, end: 1, system: [], microphone: [], sampleRate: 10))
        XCTAssertEqual(DiarizationAudio.energy(remote, start: .nan, end: .infinity, sampleRate: 10), 0)
    }

    private static let evidence = [
        SpeakerEmbedding(speakerId: "a", embedding: [1, 0], startTime: 0, endTime: 1, qualityScore: 1),
        SpeakerEmbedding(speakerId: "b", embedding: [0, 1], startTime: 1, endTime: 2, qualityScore: 1),
    ]

    @MainActor
    func testInitialMicrophoneOnlyMeetingDiarizesMultiplePeopleWithoutYou() async {
        let engine = NeuralDiarizationEngine { source, _ in
            XCTAssertEqual(source, .microphone)
            return Self.evidence
        }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Person A"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "Person B"),
        ]
        let result = await engine.diarize(segments: segments, systemSamples: [], micSamples: [Float](repeating: 0.2, count: 20), sampleRate: 10)
        XCTAssertEqual(Set(result.segments.compactMap(\.speaker)).count, 2)
        XCTAssertFalse(result.segments.contains { $0.speaker == "You" })
        XCTAssertTrue(result.speakerEmbeddings.allSatisfy { $0.source == .microphone })
        XCTAssertTrue(result.segments.allSatisfy { $0.audioSource == .microphone })
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor
    func testInitialHybridMeetingKeepsLocalAndRemoteIdentitiesDistinct() async throws {
        let engine = NeuralDiarizationEngine { _, _ in Self.evidence }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Remote", speaker: "You"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "In room"),
        ]
        let system: [Float] = [Float](repeating: 0.5, count: 10) + [Float](repeating: 0, count: 10)
        let mic: [Float] = [Float](repeating: 0.05, count: 10) + [Float](repeating: 0.5, count: 10)
        let result = await engine.diarize(segments: segments, systemSamples: system, micSamples: mic, sampleRate: 10)
        XCTAssertEqual(result.segments.map(\.audioSource), [.system, .microphone])
        XCTAssertNotEqual(result.segments[0].speakerID, result.segments[1].speakerID)
        XCTAssertFalse(result.segments.contains { $0.speaker == "You" })
        XCTAssertEqual(result.speakerEmbeddings.filter { $0.source == .microphone }.count, 1, "The attenuated microphone echo is excluded")

        let rediarized = try await engine.rediarize(segments: result.segments, systemSamples: system, micSamples: mic, numSpeakers: 2, sampleRate: 10)
        XCTAssertLessThanOrEqual(Set(rediarized.segments.compactMap(\.speaker)).count, 2)
        XCTAssertTrue(rediarized.speakerEmbeddings.contains { $0.source == .microphone })
    }

    @MainActor
    func testAudioProcessingErrorPropagatesInsteadOfPretendingSuccess() async {
        let engine = NeuralDiarizationEngine { _, _ in throw SpeakerAttributionError.noSpeech }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, text: "Keep me", speaker: "Speaker 3")
        do {
            _ = try await engine.rediarize(segments: [segment], systemSamples: [Float](repeating: 0.2, count: 10), micSamples: nil, numSpeakers: 2, sampleRate: 10)
            XCTFail("An audio failure must reach the caller")
        } catch {
            XCTAssertEqual(error.localizedDescription, SpeakerAttributionError.noSpeech.localizedDescription)
        }
    }

    @MainActor
    func testRawAudioTwoSpeakerLimitIncludesMicrophoneAlongsideTwoRemoteClusters() async throws {
        let engine = NeuralDiarizationEngine { source, _ in
            if source == .microphone {
                return [SpeakerEmbedding(speakerId: "c", embedding: [0, 0, 1], startTime: 2, endTime: 3, qualityScore: 1)]
            }
            return [
                SpeakerEmbedding(speakerId: "a", embedding: [1, 0, 0], startTime: 0, endTime: 1, qualityScore: 1),
                SpeakerEmbedding(speakerId: "b", embedding: [0, 1, 0], startTime: 1, endTime: 2, qualityScore: 1),
            ]
        }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "Remote A"),
            TranscriptSegment(startTime: 1, endTime: 2, text: "Remote B"),
            TranscriptSegment(startTime: 2, endTime: 3, text: "Local", speaker: "You"),
        ]
        let system = [Float](repeating: 0.5, count: 20) + [Float](repeating: 0, count: 10)
        let mic = [Float](repeating: 0, count: 20) + [Float](repeating: 0.5, count: 10)
        let result = try await engine.rediarize(segments: segments, systemSamples: system, micSamples: mic, numSpeakers: 2, sampleRate: 10)
        XCTAssertEqual(Set(result.segments.compactMap(\.speaker)).count, 2)
        XCTAssertFalse(result.segments.contains { $0.speaker == "You" }, "The old heuristic label is not evidence of identity when both tracks can be reprocessed")
        XCTAssertEqual(result.segments.map(\.text), segments.map(\.text))
        XCTAssertEqual(result.speakerEmbeddings.count, 3)
    }

    @MainActor
    func testBriefMicrophoneTurnIsNotLostInLongSilentRecording() async {
        let engine = NeuralDiarizationEngine { source, _ in
            XCTAssertEqual(source, .microphone)
            return Self.evidence
        }
        let result = await engine.diarize(
            segments: [TranscriptSegment(startTime: 0, endTime: 1, text: "Brief turn")],
            systemSamples: [], micSamples: [0.05] + [Float](repeating: 0, count: 10_000), sampleRate: 10
        )
        XCTAssertEqual(result.speakerEmbeddings.count, 1)
        XCTAssertNotNil(result.segments[0].speaker)
        XCTAssertNil(engine.errorMessage)
    }
}
