import XCTest
@testable import Seminarly

final class DiarizationEngineTests: XCTestCase {

    @MainActor
    func testEmptySegmentsReturnsEmpty() async {
        let engine = DiarizationEngine()
        let result = await engine.diarize(segments: [], audioSamples: [])
        XCTAssertTrue(result.isEmpty)
    }

    @MainActor
    func testSingleSegmentLabeledSpeaker1() async {
        let engine = DiarizationEngine()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 5, text: "Hello")
        ]
        let samples = makeSineWave(frequency: 440, sampleRate: 16000, duration: 5.0)

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Speaker 1")
        XCTAssertNotNil(result[0].speakerConfidence)
    }

    @MainActor
    func testUniformAudioSameSpeaker() async {
        // Same sine wave throughout → all segments should be same speaker
        let engine = DiarizationEngine()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 3, text: "First speaker talking"),
            TranscriptSegment(startTime: 5, endTime: 8, text: "Same speaker continues"),
        ]
        let samples = makeSineWave(frequency: 440, sampleRate: 16000, duration: 8.0)

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        XCTAssertGreaterThanOrEqual(result.count, 2)
        // All result segments should be the same speaker
        let speakers = Set(result.compactMap(\.speaker))
        XCTAssertEqual(speakers.count, 1, "Uniform audio should be classified as same speaker")
    }

    @MainActor
    func testAllSegmentsGetSpeakerLabels() async {
        let engine = DiarizationEngine()
        let totalDuration: Double = 50.0
        let segments = (0..<5).map { i in
            TranscriptSegment(
                startTime: Double(i) * 10,
                endTime: Double(i) * 10 + 5,
                text: "Segment \(i)"
            )
        }
        let samples = makeSineWave(frequency: 440, sampleRate: 16000, duration: totalDuration)

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        XCTAssertGreaterThanOrEqual(result.count, 5)
        for segment in result {
            XCTAssertNotNil(segment.speaker, "Every segment should have a speaker label")
            XCTAssertNotNil(segment.speakerConfidence, "Every segment should have confidence")
        }
    }

    @MainActor
    func testAllSegmentsHaveConfidenceScores() async {
        let engine = DiarizationEngine()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 2, text: "Hello"),
            TranscriptSegment(startTime: 3, endTime: 5, text: "World"),
        ]
        let samples = makeSineWave(frequency: 440, sampleRate: 16000, duration: 5.0)

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        for segment in result {
            if let confidence = segment.speakerConfidence {
                XCTAssertGreaterThanOrEqual(confidence, 0.0)
                XCTAssertLessThanOrEqual(confidence, 1.0)
            }
        }
    }

    @MainActor
    func testShortSegmentGetsSpeakerLabel() async {
        // A very short segment (<0.5s) should get a speaker label (from nearest window)
        let engine = DiarizationEngine()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 3, text: "Long segment"),
            TranscriptSegment(startTime: 3.1, endTime: 3.4, text: "Uh"),
        ]
        let samples = makeSineWave(frequency: 440, sampleRate: 16000, duration: 4.0)

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        XCTAssertGreaterThanOrEqual(result.count, 2)
        // Short segment should have a speaker label
        let shortSegment = result.first(where: { $0.text.contains("Uh") })
        XCTAssertNotNil(shortSegment?.speaker, "Short segment should have a speaker label")
    }

    @MainActor
    func testChannelSeparatedDiarizationFallsBackWhenNoMic() async {
        let engine = DiarizationEngine()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 3, text: "System audio only"),
        ]
        let systemSamples = makeSineWave(frequency: 440, sampleRate: 16000, duration: 3.0)

        let result = await engine.diarize(
            segments: segments,
            systemSamples: systemSamples,
            micSamples: nil
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Speaker 1")
    }

    // MARK: - Windowed Analysis Tests

    func testWindowedEmbeddingExtraction() {
        let sampleRate: Double = 16000
        let duration: Double = 5.0
        let samples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: duration)

        let windows = DiarizationEngine.extractWindowedEmbeddings(from: samples, sampleRate: sampleRate)

        // 5s of audio with 3.0s windows and 1.5s hop should give ~2 windows
        XCTAssertGreaterThan(windows.count, 0, "Should extract at least one window")

        for window in windows {
            XCTAssertEqual(window.embedding.count, MFCCExtractor.embeddingDimension)
            XCTAssertGreaterThanOrEqual(window.startTime, 0)
            XCTAssertLessThanOrEqual(window.endTime, duration + 0.1)
        }
    }

    func testWindowedEmbeddingSkipsSilence() {
        let sampleRate: Double = 16000
        // Create audio: 3s of tone + 3s of silence
        let toneSamples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: 3.0)
        let silentSamples = [Float](repeating: 0.0, count: Int(sampleRate * 3.0))
        let samples = toneSamples + silentSamples

        let windows = DiarizationEngine.extractWindowedEmbeddings(from: samples, sampleRate: sampleRate)

        // Windows in the silent section should be skipped
        // Tone is in [0, 3), silence in [3, 6)
        let silentWindows = windows.filter { $0.startTime >= 3.0 }
        XCTAssertEqual(silentWindows.count, 0, "Silent windows should be skipped")
    }

    @MainActor
    func testTwoDistinctTonesGetTwoSpeakers() async {
        let engine = DiarizationEngine()
        let sampleRate: Double = 16000

        // Create audio with two very different tones to simulate two speakers
        // Low tone (200 Hz) for 6s + silence gap + high tone (2000 Hz) for 6s
        // Using longer segments (>3s window) to ensure multiple windows per speaker
        let lowTone = makeSineWave(frequency: 200, sampleRate: sampleRate, duration: 6.0)
        let gap = [Float](repeating: 0.0, count: Int(sampleRate * 1.0))
        let highTone = makeSineWave(frequency: 2000, sampleRate: sampleRate, duration: 6.0)

        let samples = lowTone + gap + highTone

        let segments = [
            TranscriptSegment(startTime: 0, endTime: 6, text: "First speaker talking here"),
            TranscriptSegment(startTime: 7.0, endTime: 13.0, text: "Second speaker responding now"),
        ]

        let result = await engine.diarize(segments: segments, audioSamples: samples)

        // Should detect at least 2 segments
        XCTAssertGreaterThanOrEqual(result.count, 2)

        // Get unique speakers — with normalized embeddings and fixed clustering,
        // two very different frequencies should produce 2 distinct speakers
        let speakers = Set(result.compactMap(\.speaker))
        XCTAssertGreaterThanOrEqual(speakers.count, 2, "Two very different tones should be classified as different speakers")
    }

    // MARK: - Mic Echo Tests

    @MainActor
    func testMicEchoNotLabeledYou() async {
        // Simulates speaker echo: mic picks up attenuated system audio (-20dB → ratio ~0.1).
        // The mic/sys ratio is well below 2.0, so it should NOT be labeled "You".
        let engine = DiarizationEngine()
        let sampleRate: Double = 16000
        let duration: Double = 3.0
        let systemSamples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: duration)
        // Echo at -20dB attenuation (factor 0.1)
        let micSamples = systemSamples.map { $0 * 0.1 }

        let segments = [
            TranscriptSegment(startTime: 0, endTime: duration, text: "Remote speaker talking")
        ]

        let result = await engine.diarize(
            segments: segments,
            systemSamples: systemSamples,
            micSamples: micSamples
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNotEqual(result[0].speaker, "You", "Attenuated echo should NOT be labeled 'You'")
    }

    @MainActor
    func testDirectMicSpeechLabeledYou() async {
        // Simulates local user speaking: mic is much louder than system audio.
        // mic/sys ratio > 2.0 → should be labeled "You".
        let engine = DiarizationEngine()
        let sampleRate: Double = 16000
        let duration: Double = 3.0
        // Quiet system audio (remote speaker not talking)
        let systemSamples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: duration).map { $0 * 0.05 }
        // Strong mic input (local user speaking)
        let micSamples = makeSineWave(frequency: 300, sampleRate: sampleRate, duration: duration)

        let segments = [
            TranscriptSegment(startTime: 0, endTime: duration, text: "Local user speaking")
        ]

        let result = await engine.diarize(
            segments: segments,
            systemSamples: systemSamples,
            micSamples: micSamples
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "You", "Strong mic + weak system should be labeled 'You'")
    }

    // MARK: - Helpers

    private func makeSineWave(frequency: Double, sampleRate: Double, duration: Double) -> [Float] {
        let count = Int(sampleRate * duration)
        return (0..<count).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate)) * 0.5
        }
    }
}
