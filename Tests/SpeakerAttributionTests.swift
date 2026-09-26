import XCTest
@testable import Seminarly

final class SpeakerAttributionTests: XCTestCase {
    private func fixture(source: SpeakerAudioSource? = .microphone) -> ([TranscriptSegment], [SpeakerEmbedding]) {
        let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        let segments = (0..<6).map {
            TranscriptSegment(startTime: Double($0), endTime: Double($0 + 1), text: "Turn \($0)", audioSource: source)
        }
        let embeddings = (0..<6).map {
            SpeakerEmbedding(speakerId: "s\($0 / 2)", embedding: vectors[$0 / 2],
                startTime: Float($0), endTime: Float($0 + 1), qualityScore: 0.9, source: source)
        }
        return (segments, embeddings)
    }

    func testSharedMicrophoneKeepsThreePeopleAndDoesNotGuessYou() throws {
        let (segments, embeddings) = fixture()
        let result = try SpeakerAttribution.recluster(segments: segments, embeddings: embeddings, totalSpeakers: 3)
        XCTAssertEqual(Set(result.compactMap(\.speaker)).count, 3)
        XCTAssertFalse(result.contains { $0.speaker == "You" })
        XCTAssertEqual(result[0].speaker, result[1].speaker)
        XCTAssertNotEqual(result[0].speaker, result[2].speaker)
        XCTAssertNotEqual(result[2].speaker, result[4].speaker)
    }

    func testEveryRequestedCountIncludesAllSourcesAndConfirmedYou() throws {
        var (segments, embeddings) = fixture()
        for i in 2..<6 { segments[i].audioSource = .system; embeddings[i].source = .system }
        let original = try SpeakerAttribution.assignOriginal(segments: segments, embeddings: embeddings)
        let identified = SpeakerAttribution.identifyUser(in: original, speakerID: original[0].speakerID)
        for count in 1...6 {
            let result = try SpeakerAttribution.recluster(segments: identified, embeddings: embeddings, totalSpeakers: count)
            XCTAssertLessThanOrEqual(Set(result.compactMap(\.speakerID)).count, count)
            XCTAssertEqual(Set(result.compactMap(\.speakerID)).count, Set(result.compactMap(\.speaker)).count)
            XCTAssertEqual(result.map(\.text), segments.map(\.text))
            XCTAssertEqual(result.map(\.startTime), segments.map(\.startTime))
            XCTAssertEqual(result.map(\.endTime), segments.map(\.endTime))
        }
    }

    func testIdentifyingAndClearingYouOnlyRenamesOneIdentity() throws {
        let (segments, embeddings) = fixture()
        let original = try SpeakerAttribution.assignOriginal(segments: segments, embeddings: embeddings)
        let identified = SpeakerAttribution.identifyUser(in: original, speakerID: original[2].speakerID)
        XCTAssertEqual(identified.map(\.speakerID), original.map(\.speakerID))
        XCTAssertEqual(identified.filter { $0.speaker == "You" }.map(\.text), ["Turn 2", "Turn 3"])
        XCTAssertEqual(Set(identified.compactMap(\.speaker)).count, 3)
        let cleared = SpeakerAttribution.identifyUser(in: identified, speakerID: nil)
        XCTAssertFalse(cleared.contains { $0.speaker == "You" })
        XCTAssertTrue(cleared.allSatisfy { $0.isUser == false })
        XCTAssertEqual(cleared.map(\.speakerID), original.map(\.speakerID))
    }

    func testRepeatedClusteringPreservesConfirmedIdentityWithoutExtraLabels() throws {
        let (segments, embeddings) = fixture()
        let original = try SpeakerAttribution.assignOriginal(segments: segments, embeddings: embeddings)
        let identified = SpeakerAttribution.identifyUser(in: original, speakerID: original[2].speakerID)
        let once = try SpeakerAttribution.recluster(segments: identified, embeddings: embeddings, totalSpeakers: 3)
        let twice = try SpeakerAttribution.recluster(segments: once, embeddings: embeddings, totalSpeakers: 3)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(twice.filter { $0.speaker == "You" }.map(\.text), ["Turn 2", "Turn 3"])
    }

    func testOnePersonMergeDoesNotRenameOtherKnownPeopleYou() throws {
        let (segments, embeddings) = fixture()
        let original = try SpeakerAttribution.assignOriginal(segments: segments, embeddings: embeddings)
        let identified = SpeakerAttribution.identifyUser(in: original, speakerID: original[0].speakerID)
        let merged = try SpeakerAttribution.recluster(segments: identified, embeddings: [], totalSpeakers: 1)
        XCTAssertEqual(Set(merged.compactMap(\.speaker)), ["Speaker 1"])
        XCTAssertEqual(merged.map(\.isUser), identified.map(\.isUser))
    }

    func testUnknownTurnIsNotSilentlyAssignedToSpeakerOne() throws {
        var (segments, embeddings) = fixture()
        segments.append(TranscriptSegment(startTime: 20, endTime: 21, text: "No evidence", speaker: "Speaker 7"))
        let result = try SpeakerAttribution.recluster(segments: segments, embeddings: embeddings, totalSpeakers: 3)
        XCTAssertNil(result.last?.speaker)
        XCTAssertNil(result.last?.speakerID)
        XCTAssertNil(result.last?.speakerConfidence)
    }

    func testSourcePreventsEchoEmbeddingFromWinningTimeOverlap() throws {
        let segment = TranscriptSegment(startTime: 0, endTime: 1, text: "Remote voice", audioSource: .system)
        let embeddings = [
            SpeakerEmbedding(speakerId: "remote", embedding: [1, 0], startTime: 0, endTime: 1, qualityScore: 1, source: .system),
            SpeakerEmbedding(speakerId: "echo", embedding: [0, 1], startTime: 0, endTime: 1, qualityScore: 1, source: .microphone),
        ]
        let result = try SpeakerAttribution.assignOriginal(segments: [segment], embeddings: embeddings)
        XCTAssertEqual(result[0].speakerID, "remote")
    }

    func testMissingAndMalformedEvidenceThrowsInsteadOfReturningStaleLabels() {
        let (segments, embeddings) = fixture()
        XCTAssertThrowsError(try SpeakerAttribution.recluster(segments: segments, embeddings: [], totalSpeakers: 2))
        XCTAssertThrowsError(try SpeakerAttribution.recluster(segments: segments, embeddings: embeddings, totalSpeakers: 0))
        for vector: [Float] in [[], [Float.nan, 0, 0], [0, 0, 0], [1, 0]] {
            let bad = SpeakerEmbedding(speakerId: "bad", embedding: vector, startTime: 0, endTime: 1, qualityScore: 1)
            XCTAssertThrowsError(try SpeakerAttribution.recluster(segments: segments, embeddings: embeddings + [bad], totalSpeakers: 2))
        }
    }

    func testLegacyPayloadsDecodeWithoutNewMetadata() throws {
        let oldEmbedding = Data(#"{"speakerId":"s0","embedding":[1,0],"startTime":0,"endTime":1,"qualityScore":0.9}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SpeakerEmbedding.self, from: oldEmbedding).source)
        let oldSegment = Data(#"{"startTime":0,"endTime":1,"text":"Old turn","speaker":"You"}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: oldSegment)
        XCTAssertEqual(decoded.speaker, "You")
        XCTAssertNil(decoded.speakerID)
        XCTAssertNil(decoded.audioSource)
        XCTAssertNil(decoded.isUser)
    }

    func testNewMetadataSurvivesCodableRoundTrip() throws {
        var (segments, embeddings) = fixture()
        segments[0].speakerID = "local-a"
        segments[0].isUser = true
        XCTAssertEqual(try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(segments)), segments)
        let restored = try JSONDecoder().decode([SpeakerEmbedding].self, from: JSONEncoder().encode(embeddings))
        XCTAssertEqual(restored.map(\.source), embeddings.map(\.source))
    }

    @MainActor
    func testLegacyTwoOneTwoUsesOriginalEvidenceAndPreservesYouConfidence() throws {
        let (remote, embeddings) = fixture(source: nil)
        let local = TranscriptSegment(startTime: 10, endTime: 11, text: "Local", speaker: "You", speakerConfidence: 0.87)
        let original = [local] + remote
        let meeting = Meeting(title: "Legacy")
        meeting.transcript = Transcript(segments: original)
        meeting.originalSegmentsData = meeting.transcript?.segmentsData
        meeting.speakerEmbeddings = embeddings
        for count in [2, 1, 2] {
            meeting.transcript?.segments = try SpeakerAttribution.recluster(
                segments: meeting.rediarizationSegments, embeddings: embeddings, totalSpeakers: count
            )
        }
        let result = try XCTUnwrap(meeting.transcript?.segments)
        XCTAssertEqual(result[0].speaker, "You")
        XCTAssertEqual(result[0].speakerConfidence, 0.87)
        XCTAssertEqual(Set(result.compactMap(\.speaker)).count, 2)
        XCTAssertTrue(meeting.hasLegacySpeakerEvidence)
    }

    @MainActor
    func testConfirmedIdentitySurvivesMergeThenSplitFromOriginalEvidence() throws {
        let (segments, embeddings) = fixture()
        let original = try SpeakerAttribution.assignOriginal(segments: segments, embeddings: embeddings)
        let meeting = Meeting()
        meeting.transcript = Transcript(segments: original)
        meeting.originalSegmentsData = meeting.transcript?.segmentsData
        meeting.transcript?.segments = SpeakerAttribution.identifyUser(in: original, speakerID: original[2].speakerID)
        for count in [1, 3] {
            meeting.transcript?.segments = try SpeakerAttribution.recluster(
                segments: meeting.rediarizationSegments, embeddings: embeddings, totalSpeakers: count
            )
        }
        XCTAssertEqual(meeting.transcript?.segments.filter { $0.speaker == "You" }.map(\.text), ["Turn 2", "Turn 3"])
    }
}
