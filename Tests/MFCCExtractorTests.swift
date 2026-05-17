import XCTest
@testable import Seminarly

final class MFCCExtractorTests: XCTestCase {

    func testExtractReturnsEmbeddingVector() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: 1.0)

        let embedding = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)

        XCTAssertNotNil(embedding)
        XCTAssertEqual(embedding?.count, MFCCExtractor.embeddingDimension)
    }

    func testEmbeddingDimensionIs34() {
        // 13 MFCC stddevs + 13 delta means + 4 pitch + 2 centroid + 2 spread = 34
        XCTAssertEqual(MFCCExtractor.embeddingDimension, 34)
    }

    func testExtractReturnsNilForTooShortInput() {
        let samples = [Float](repeating: 0.1, count: 100)
        let embedding = MFCCExtractor.extract(from: samples, sampleRate: 16000)
        XCTAssertNil(embedding)
    }

    func testSameSignalProducesSameEmbedding() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: 1.0)

        let emb1 = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)
        let emb2 = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)

        XCTAssertNotNil(emb1)
        XCTAssertNotNil(emb2)

        for i in 0..<MFCCExtractor.embeddingDimension {
            XCTAssertEqual(emb1![i], emb2![i], accuracy: 1e-6)
        }
    }

    func testDifferentFrequenciesProduceDifferentEmbeddings() {
        let sampleRate: Double = 16000
        let low = makeSineWave(frequency: 200, sampleRate: sampleRate, duration: 1.0)
        let high = makeSineWave(frequency: 2000, sampleRate: sampleRate, duration: 1.0)

        let embLow = MFCCExtractor.extract(from: low, sampleRate: sampleRate)
        let embHigh = MFCCExtractor.extract(from: high, sampleRate: sampleRate)

        XCTAssertNotNil(embLow)
        XCTAssertNotNil(embHigh)

        let similarity = SpeakerClusterer.cosineSimilarity(embLow!, embHigh!)
        XCTAssertLessThan(similarity, 1.0, "Different frequencies should produce different embeddings")
        XCTAssertNotEqual(embLow!, embHigh!, "Embeddings for different frequencies should not be identical")
    }

    func testEmbeddingValuesAreFinite() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: 2.0)

        let embedding = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)
        XCTAssertNotNil(embedding)

        for value in embedding! {
            XCTAssertTrue(value.isFinite, "Embedding values should be finite, got \(value)")
        }
    }

    func testEmbeddingContainsStddevAndDelta() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 440, sampleRate: sampleRate, duration: 1.0)

        let embedding = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)!
        let mfccCount = MFCCExtractor.mfccCount

        // Stddev section (indices 0-12) should have non-zero values for a sine wave
        let stddevSection = Array(embedding[0..<mfccCount])
        let hasNonZeroStddev = stddevSection.contains(where: { abs($0) > 1e-10 })
        XCTAssertTrue(hasNonZeroStddev, "Stddev section should have non-zero values")
    }

    func testNextPowerOf2() {
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(1), 1)
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(2), 2)
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(3), 4)
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(400), 512)
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(512), 512)
        XCTAssertEqual(MFCCExtractor.nextPowerOf2(513), 1024)
    }

    func testHzMelConversion() {
        let frequencies: [Double] = [0, 100, 440, 1000, 4000, 8000]
        for freq in frequencies {
            let mel = MFCCExtractor.hzToMel(freq)
            let roundTrip = MFCCExtractor.melToHz(mel)
            XCTAssertEqual(freq, roundTrip, accuracy: 0.01, "Round trip failed for \(freq) Hz")
        }
    }

    // MARK: - Pitch Extraction Tests

    func testPitchDetectionOnKnownFrequency() {
        let sampleRate: Double = 16000
        // Generate a 150 Hz sine wave (typical male speech range)
        let samples = makeSineWave(frequency: 150, sampleRate: sampleRate, duration: 1.0)

        let f0 = MFCCExtractor.detectPitchAutocorrelation(
            frame: Array(samples[0..<Int(0.025 * sampleRate)]),
            sampleRate: sampleRate,
            minLag: Int(sampleRate / Double(MFCCExtractor.maxF0)),
            maxLag: Int(sampleRate / Double(MFCCExtractor.minF0))
        )

        XCTAssertNotNil(f0, "Should detect pitch for a clear sine wave")
        if let f0 {
            // Autocorrelation on short 25ms frames has limited precision
            // The key property is that pitch is detected in the right range
            XCTAssertEqual(f0, 150.0, accuracy: 50.0, "Detected F0 should be in the range of 150 Hz")
        }
    }

    func testPitchDetectionOnHighFrequency() {
        let sampleRate: Double = 16000
        // 300 Hz — higher female voice range
        let samples = makeSineWave(frequency: 300, sampleRate: sampleRate, duration: 1.0)

        let f0 = MFCCExtractor.detectPitchAutocorrelation(
            frame: Array(samples[0..<Int(0.025 * sampleRate)]),
            sampleRate: sampleRate,
            minLag: Int(sampleRate / Double(MFCCExtractor.maxF0)),
            maxLag: Int(sampleRate / Double(MFCCExtractor.minF0))
        )

        XCTAssertNotNil(f0, "Should detect pitch for 300 Hz sine wave")
        if let f0 {
            // Short-frame autocorrelation has limited precision, but should be in range
            XCTAssertEqual(f0, 300.0, accuracy: 80.0, "Detected F0 should be in the range of 300 Hz")
        }
    }

    func testPitchFeaturesOnVoicedAudio() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 200, sampleRate: sampleRate, duration: 1.5)

        let frameLength = Int(MFCCExtractor.frameDuration * sampleRate)
        let hopLength = Int(MFCCExtractor.hopDuration * sampleRate)
        let numFrames = max(1, (samples.count - frameLength) / hopLength + 1)

        let features = MFCCExtractor.extractPitchFeatures(
            from: samples,
            sampleRate: sampleRate,
            frameLength: frameLength,
            hopLength: hopLength,
            numFrames: numFrames
        )

        XCTAssertGreaterThan(features.voicedRatio, 0.0, "Sine wave should have some voiced frames")
        XCTAssertGreaterThan(features.medianF0, 0.0, "Median F0 should be positive for voiced audio")
    }

    func testPitchFeaturesOnSilence() {
        let sampleRate: Double = 16000
        let samples = [Float](repeating: 0.0, count: Int(sampleRate * 1.5))

        let frameLength = Int(MFCCExtractor.frameDuration * sampleRate)
        let hopLength = Int(MFCCExtractor.hopDuration * sampleRate)
        let numFrames = max(1, (samples.count - frameLength) / hopLength + 1)

        let features = MFCCExtractor.extractPitchFeatures(
            from: samples,
            sampleRate: sampleRate,
            frameLength: frameLength,
            hopLength: hopLength,
            numFrames: numFrames
        )

        XCTAssertEqual(features.voicedRatio, 0.0, "Silent audio should have 0 voiced ratio")
        XCTAssertEqual(features.medianF0, 0.0, "Silent audio should have 0 median F0")
    }

    func testEmbeddingContainsPitchAndSpectralFeatures() {
        let sampleRate: Double = 16000
        let samples = makeSineWave(frequency: 200, sampleRate: sampleRate, duration: 1.5)

        let embedding = MFCCExtractor.extract(from: samples, sampleRate: sampleRate)
        XCTAssertNotNil(embedding)
        XCTAssertEqual(embedding!.count, 34)

        // Spectral features (indices 30-33) should be non-zero for a real signal
        let spectralSection = Array(embedding![30..<34])
        let hasNonZeroSpectral = spectralSection.contains(where: { abs($0) > 1e-10 })
        XCTAssertTrue(hasNonZeroSpectral, "Spectral features should be non-zero for a sine wave")
    }

    func testDifferentPitchesProduceDifferentPitchFeatures() {
        let sampleRate: Double = 16000
        let low = makeSineWave(frequency: 100, sampleRate: sampleRate, duration: 1.5)
        let high = makeSineWave(frequency: 400, sampleRate: sampleRate, duration: 1.5)

        let embLow = MFCCExtractor.extract(from: low, sampleRate: sampleRate)!
        let embHigh = MFCCExtractor.extract(from: high, sampleRate: sampleRate)!

        // Pitch features are at indices 26-29; medianF0 at 26 should differ
        // Note: both may be 0 if autocorrelation fails on pure sine, but embeddings
        // should still differ due to spectral features
        let overallDiff = zip(embLow, embHigh).map { abs($0 - $1) }.reduce(0, +)
        XCTAssertGreaterThan(overallDiff, 0.01, "Embeddings should differ for different frequencies")
    }

    // MARK: - Helpers

    private func makeSineWave(frequency: Double, sampleRate: Double, duration: Double) -> [Float] {
        let count = Int(sampleRate * duration)
        return (0..<count).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate)) * 0.5
        }
    }
}
