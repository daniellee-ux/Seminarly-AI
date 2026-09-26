import XCTest
@testable import Seminarly

final class LanguageAwareDiarizationTests: XCTestCase {

    // MARK: - isCJKLanguage Tests

    func testChineseSimplified() {
        XCTAssertTrue(NeuralDiarizationEngine.isCJKLanguage("zh"))
    }

    func testChineseHans() {
        XCTAssertTrue(NeuralDiarizationEngine.isCJKLanguage("zh-Hans"))
    }

    func testChineseHant() {
        XCTAssertTrue(NeuralDiarizationEngine.isCJKLanguage("zh-Hant"))
    }

    func testCantonese() {
        XCTAssertTrue(NeuralDiarizationEngine.isCJKLanguage("yue"))
    }

    func testChineseUppercase() {
        XCTAssertTrue(NeuralDiarizationEngine.isCJKLanguage("ZH"))
    }

    func testEnglish() {
        XCTAssertFalse(NeuralDiarizationEngine.isCJKLanguage("en"))
    }

    func testJapanese() {
        XCTAssertFalse(NeuralDiarizationEngine.isCJKLanguage("ja"))
    }

    func testNilLanguage() {
        XCTAssertFalse(NeuralDiarizationEngine.isCJKLanguage(nil))
    }

    func testEmptyString() {
        XCTAssertFalse(NeuralDiarizationEngine.isCJKLanguage(""))
    }

    // MARK: - Embedding Re-clustering for Chinese

    func testReclusterFromEmbeddingsProducesTwoSpeakers() throws {
        // Create two distinct embedding clusters (256D vectors)
        let clusterA = [Float](repeating: 1.0, count: 128) + [Float](repeating: 0.0, count: 128)
        let clusterB = [Float](repeating: 0.0, count: 128) + [Float](repeating: 1.0, count: 128)

        let embeddings = [
            SpeakerEmbedding(speakerId: "collapsed_0", embedding: clusterA, startTime: 0, endTime: 5, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "collapsed_0", embedding: clusterA, startTime: 5, endTime: 10, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "collapsed_0", embedding: clusterB, startTime: 10, endTime: 15, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "collapsed_0", embedding: clusterB, startTime: 15, endTime: 20, qualityScore: 0.9),
        ]

        let segments = [
            TranscriptSegment(startTime: 0, endTime: 5, text: "First speaker talking"),
            TranscriptSegment(startTime: 5, endTime: 10, text: "Still first speaker"),
            TranscriptSegment(startTime: 10, endTime: 15, text: "Second speaker now"),
            TranscriptSegment(startTime: 15, endTime: 20, text: "Still second speaker"),
        ]

        let result = try NeuralDiarizationEngine.rediarizeFromEmbeddings(
            segments: segments,
            speakerEmbeddings: embeddings,
            numSpeakers: 2
        )

        let speakers = Set(result.compactMap(\.speaker))
        XCTAssertEqual(speakers.count, 2, "Should produce 2 distinct speakers from 2 distinct embedding clusters")

        // First two segments should have same speaker, last two should have same speaker
        XCTAssertEqual(result[0].speaker, result[1].speaker)
        XCTAssertEqual(result[2].speaker, result[3].speaker)
        XCTAssertNotEqual(result[0].speaker, result[2].speaker)
    }

    func testReclusterPreservesYouLabels() throws {
        let clusterA = [Float](repeating: 1.0, count: 128) + [Float](repeating: 0.0, count: 128)
        let clusterB = [Float](repeating: 0.0, count: 128) + [Float](repeating: 1.0, count: 128)

        let embeddings = [
            SpeakerEmbedding(speakerId: "s0", embedding: clusterA, startTime: 0, endTime: 5, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "s0", embedding: clusterB, startTime: 5, endTime: 10, qualityScore: 0.9),
        ]

        let segments = [
            TranscriptSegment(startTime: 0, endTime: 5, text: "Me talking", speaker: "You", speakerConfidence: 0.9),
            TranscriptSegment(startTime: 5, endTime: 10, text: "Other person"),
        ]

        let result = try NeuralDiarizationEngine.rediarizeFromEmbeddings(
            segments: segments,
            speakerEmbeddings: embeddings,
            numSpeakers: 2
        )

        XCTAssertEqual(result[0].speaker, "You", "You labels should be preserved after re-clustering")
    }

    // MARK: - Requested Total Speaker Count (Legacy Recordings)

    func testRequestedTwoSpeakersIncludesPreservedYou() throws {
        let fixture = makeMixedSourceFixture()
        let result = try NeuralDiarizationEngine.rediarizeFromEmbeddings(
            segments: fixture.segments,
            speakerEmbeddings: fixture.embeddings,
            numSpeakers: 2
        )

        XCTAssertEqual(result.first?.speaker, "You")
        XCTAssertEqual(result.map(\.text), fixture.segments.map(\.text))
        let speakers = Set(result.compactMap(\.speaker))

        XCTAssertEqual(speakers.count, 2, "Requested 2 total speakers; got \(speakers.sorted())")
    }

    func testRequestedOneSpeakerDoesNotAddYouOnTop() throws {
        let fixture = makeMixedSourceFixture()
        let result = try NeuralDiarizationEngine.rediarizeFromEmbeddings(
            segments: fixture.segments,
            speakerEmbeddings: fixture.embeddings,
            numSpeakers: 1
        )

        XCTAssertEqual(result.map(\.text), fixture.segments.map(\.text))
        let speakers = Set(result.compactMap(\.speaker))

        XCTAssertEqual(speakers.count, 1, "Requested 1 total speaker; got \(speakers.sorted())")
    }

    private func makeMixedSourceFixture() -> (segments: [TranscriptSegment], embeddings: [SpeakerEmbedding]) {
        let clusterA = [Float](repeating: 1.0, count: 128) + [Float](repeating: 0.0, count: 128)
        let clusterB = [Float](repeating: 0.0, count: 128) + [Float](repeating: 1.0, count: 128)

        // Embeddings come from system audio only; the mic-only turn has none.
        // Both remote clusters retain transcript turns after You is preserved.
        let embeddings = [
            SpeakerEmbedding(speakerId: "s0", embedding: clusterA, startTime: 5, endTime: 10, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "s0", embedding: clusterA, startTime: 10, endTime: 15, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "s1", embedding: clusterB, startTime: 15, endTime: 20, qualityScore: 0.9),
            SpeakerEmbedding(speakerId: "s1", embedding: clusterB, startTime: 20, endTime: 25, qualityScore: 0.9),
        ]
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 5, text: "Local microphone turn", speaker: "You", speakerConfidence: 0.9),
            TranscriptSegment(startTime: 5, endTime: 10, text: "Remote turn A"),
            TranscriptSegment(startTime: 10, endTime: 15, text: "Remote turn A continued"),
            TranscriptSegment(startTime: 15, endTime: 20, text: "Remote turn B"),
            TranscriptSegment(startTime: 20, endTime: 25, text: "Remote turn B continued"),
        ]
        return (segments, embeddings)
    }
}
