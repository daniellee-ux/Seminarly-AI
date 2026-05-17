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

    func testReclusterFromEmbeddingsProducesTwoSpeakers() {
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

        let result = NeuralDiarizationEngine.rediarizeFromEmbeddings(
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

    func testReclusterPreservesYouLabels() {
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

        let result = NeuralDiarizationEngine.rediarizeFromEmbeddings(
            segments: segments,
            speakerEmbeddings: embeddings,
            numSpeakers: 2
        )

        XCTAssertEqual(result[0].speaker, "You", "You labels should be preserved after re-clustering")
    }
}
