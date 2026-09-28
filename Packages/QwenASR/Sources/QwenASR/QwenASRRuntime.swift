import Foundation
import MLX
import MLXNN
import Tokenizers

public struct QwenASRResult: Sendable {
    public let text: String
    public let language: String?
}

/// Owns all MLX arrays; neither models nor arrays cross the actor boundary.
public actor QwenASRRuntime {
    private var model: Qwen3ASRModel?

    public init() {}

    public func load(from directory: URL, tokenizerCacheRoot: URL? = nil) async throws {
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(Qwen3ASRConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let quantization = try JSONDecoder().decode(MixedQuantization.self,
            from: Data(contentsOf: directory.appendingPathComponent("quantization_config.json")))
        guard quantization.bits == 4, quantization.audioTowerBits == 8,
              quantization.groupSize == 64, config.textConfig.tieWordEmbeddings else {
            throw RuntimeError.unsupportedQuantization
        }
        let candidate = Qwen3ASRModel(config)
        let root = tokenizerCacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.seminarly/QwenTokenizers")
        // Each load owns its tokenizer workspace; concurrent test/production
        // processes cannot mix generated files from different model sources.
        let tokenizerDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tokenizerDirectory) }
        try Qwen3ASRModel.generateTokenizerJSON(in: directory, outputDirectory: tokenizerDirectory)
        candidate.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
        try Task.checkCancellation()
        let weights = Qwen3ASRModel.sanitize(weights: try MLX.loadArrays(
            url: directory.appendingPathComponent("weights.safetensors")))
        // Unlike upstream's decoder-only loader, this artifact also quantizes
        // encoder Linear layers. Floating conv/norm/bias tensors stay FP16.
        quantize(model: candidate) { path, _ in
            guard weights["\(path).scales"] != nil else { return nil }
            return (groupSize: quantization.groupSize,
                    bits: path.hasPrefix("audio_tower.") ? quantization.audioTowerBits : quantization.bits,
                    mode: .affine)
        }
        try candidate.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(candidate)
        try Task.checkCancellation()
        self.model = candidate
        Memory.clearCache()
    }

    public func transcribe(samples: [Float], language: String?) throws -> QwenASRResult {
        try Task.checkCancellation()
        guard let model else { throw RuntimeError.notLoaded }
        guard !samples.isEmpty else { return QwenASRResult(text: "", language: nil) }
        // The frontend's reflect padding requires at least 200 samples.
        var input = samples
        if input.count < 16000 { input += Array(repeating: 0, count: 16000 - input.count) }
        defer { Memory.clearCache() }
        let result = try model.generateSingleChunk(audio: MLXArray(input), maxTokens: 512,
            temperature: 0, context: "", language: language)
        try Task.checkCancellation()
        return QwenASRResult(text: result.text, language: result.language)
    }

    public func unload() {
        model = nil
        Memory.clearCache()
    }

    private struct MixedQuantization: Decodable {
        let bits: Int
        let groupSize: Int
        let audioTowerBits: Int
        enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
            case audioTowerBits = "audio_tower_bits"
        }
    }

    private enum RuntimeError: LocalizedError {
        case unsupportedQuantization, notLoaded
        var errorDescription: String? {
            switch self {
            case .unsupportedQuantization: return "Expected Qwen 0.6B with a 4-bit decoder and 8-bit encoder."
            case .notLoaded: return "The Qwen transcription model is not loaded."
            }
        }
    }
}
