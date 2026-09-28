import AVFoundation
import Foundation
import QwenASR
@preconcurrency import WhisperKit
import XCTest
@testable import Seminarly

/// Opt-in checks exercise real weights via foreign, read-only cache layouts.
/// No downloader may be invoked by the Qwen test; both require local fixtures.
final class ModelDiscoveryInferenceTests: XCTestCase {
    private enum TestError: Error { case unexpectedDownload }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func audio() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["SEMINARLY_QWEN_SMOKE_AUDIO"] else {
            throw XCTSkip("Set SEMINARLY_QWEN_SMOKE_AUDIO to a short local 16 kHz WAV")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    }

    @MainActor
    func testQwenReadOnlyHubSnapshotLoadsAndTranscribesWithoutCopyingWeights() async throws {
        guard let path = ProcessInfo.processInfo.environment["SEMINARLY_QWEN_SMOKE_MODEL"] else {
            throw XCTSkip("Set SEMINARLY_QWEN_SMOKE_MODEL to the pinned local model")
        }
        let samples = try audio()
        let root = try root()
        let hub = root.appendingPathComponent("hub")
        let snapshot = hub.appendingPathComponent("models--moona3k--mlx-qwen3-asr-0.6b-4bit/snapshots/" + QwenModelStore.revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for file in QwenModelStore.files {
            try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(file.name),
                withDestinationURL: URL(fileURLWithPath: path).appendingPathComponent(file.name))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.path) }
        let discovery = LocalModelDiscovery(swiftCacheRoot: root.appendingPathComponent("swift"), hubCacheRoots: [hub])
        let owned = root.appendingPathComponent("owned")
        let selected = try await QwenModelStore.prepare(at: owned,
            candidates: discovery.repositoryDirectories(QwenModelStore.modelID, preferredRevision: QwenModelStore.revision),
            download: { _, _ in throw TestError.unexpectedDownload }, progress: { _ in })
        XCTAssertEqual(selected.path, snapshot.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        let runtime = QwenASRRuntime()
        let tokenizerCache = root.appendingPathComponent("tokenizers")
        try await runtime.load(from: selected, tokenizerCacheRoot: tokenizerCache)
        let result = try await runtime.transcribe(samples: samples, language: nil)
        await runtime.unload()
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.language, "Chinese")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.path).count, QwenModelStore.files.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("tokenizer.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tokenizerCache.path), [])
        print("DISCOVERY_QWEN text=\(result.text)")
    }

    @MainActor
    func testWhisperHubSnapshotWithSeparateTokenizerLoadsAndTranscribes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SEMINARLY_WHISPER_SMOKE_MODEL"],
              let tokenizerPath = env["SEMINARLY_WHISPER_SMOKE_TOKENIZER"] else {
            throw XCTSkip("Set SEMINARLY_WHISPER_SMOKE_MODEL and SEMINARLY_WHISPER_SMOKE_TOKENIZER")
        }
        let samples = try audio()
        let root = try root()
        let hub = root.appendingPathComponent("hub")
        let revision = String(repeating: "a", count: 40)
        let variant = "openai_whisper-large-v3-v20240930_turbo"
        let repo = hub.appendingPathComponent("models--argmaxinc--whisperkit-coreml/snapshots/" + revision)
        let token = hub.appendingPathComponent("models--openai--whisper-large-v3/snapshots/" + revision)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: token.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent(variant), withDestinationURL: URL(fileURLWithPath: modelPath))
        try FileManager.default.createSymbolicLink(at: token, withDestinationURL: URL(fileURLWithPath: tokenizerPath))
        let owned = root.appendingPathComponent("owned")
        let found = try XCTUnwrap(LocalModelDiscovery(swiftCacheRoot: owned, hubCacheRoots: [hub])
            .whisperInstallations(for: variant).first)
        XCTAssertEqual(found.model.path, repo.appendingPathComponent(variant).path)
        try LocalModelDiscovery.cacheWhisperTokenizer(from: try XCTUnwrap(found.tokenizer), repo: "openai/whisper-large-v3", cacheRoot: owned)
        let kit = try await WhisperKit(modelFolder: found.model.path, tokenizerFolder: owned,
            verbose: false, logLevel: .none, download: false)
        XCTAssertEqual(kit.modelVariant, .largev3)
        let result = try await kit.transcribe(audioArray: samples, decodeOptions: TranscriptionEngine.whisperDecodingOptions(language: nil))
        let text = result.map(\.text).joined()
        await kit.unloadModels()
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathComponent("models/argmaxinc").path))
        print("DISCOVERY_WHISPER text=\(text)")
    }
}
