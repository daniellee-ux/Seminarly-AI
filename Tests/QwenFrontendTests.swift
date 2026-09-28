import Foundation
import MLX
import QwenASR
import XCTest

final class QwenFrontendTests: XCTestCase {
    func testFeatureLengthsMatchWhisperExtractorIncludingPartialHop() {
        let model = Qwen3ASRModel(Qwen3ASRConfig())
        for count in [16000, 16001, 16217, 24000, 108480, 117760, 128000, 480000] {
            let audio = MLXArray.zeros([count])
            let (features, mask, tokenCount) = model.preprocessAudio(audio)
            XCTAssertEqual(features.shape, [1, 128, count / 160])
            XCTAssertEqual(mask.shape, [1, count / 160])
            let frames = count / 160
            // Independent reference: each complete 100-frame conv chunk has
            // 13 tokens; only ceil(tail / 8) tokens from a padded tail are valid.
            let expectedTokens = (frames / 100) * 13 + (frames % 100 + 7) / 8
            XCTAssertEqual(tokenCount, expectedTokens, "samples=\(count)")
        }
    }

    func testLogMelMatchesIndependentReferenceAtBoundariesAndAcrossBands() throws {
        struct Fixture: Decodable {
            struct Value: Decodable { let mel: Int; let frame: Int; let value: Float }
            let samples: Int
            let shape: [Int]
            let values: [Value]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "qwen-frontend-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let signal = (0..<fixture.samples).map { Float(($0 * 17) % 257 - 128) / 256 }
        let features = computeMelSpectrogram(audio: MLXArray(signal), sampleRate: 16000,
            nFft: 400, hopLength: 160, nMels: 128, melScale: .slaney,
            hannPeriodic: true, dropLastFrame: true).transposed(1, 0)
        XCTAssertEqual(features.shape, fixture.shape)
        for value in fixture.values {
            XCTAssertEqual(features[value.mel, value.frame].item(Float.self), value.value, accuracy: 0.00005,
                           "mel=\(value.mel) frame=\(value.frame)")
        }
    }

    func testFrontendCoefficientsMatchReferencePrecision() throws {
        struct Fixture: Decodable {
            struct Hann: Decodable { let index: Int; let value: Float }
            struct Filter: Decodable { let mel: Int; let frequency: Int; let value: Float }
            let hann: [Hann]
            let filters: [Filter]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "qwen-frontend-coefficients", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let hann = hanningWindow(size: 400, periodic: true)
        let filters = melFilters(sampleRate: 16000, nFft: 400, nMels: 128, melScale: .slaney)
        for value in fixture.hann {
            XCTAssertEqual(hann[value.index].item(Float.self), value.value, accuracy: 0.000000001)
        }
        for value in fixture.filters {
            XCTAssertEqual(filters[value.frequency, value.mel].item(Float.self), value.value, accuracy: 0.000000001)
        }
    }

}
