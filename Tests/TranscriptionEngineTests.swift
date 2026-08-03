import Foundation
import XCTest
@testable import Seminarly

final class TranscriptionEngineStateTests: XCTestCase {

    @MainActor
    func testSetupResetPreservesBlockingModelLoadFailure() {
        let engine = TranscriptionEngine()
        engine.failure = .modelLoad("Model unavailable")
        engine.liveText = "stale transcript"
        engine.segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "stale transcript")
        ]

        engine.reset()

        XCTAssertEqual(engine.failure, .modelLoad("Model unavailable"))
        XCTAssertEqual(engine.errorMessage, "Model unavailable")
        XCTAssertTrue(engine.liveText.isEmpty)
        XCTAssertTrue(engine.segments.isEmpty)
        XCTAssertTrue(engine.canRetryModelLoad)
    }

    @MainActor
    func testSetupResetClearsPreviousTranscriptionFailure() {
        let engine = TranscriptionEngine()
        engine.failure = .transcription("Decode failed")

        engine.reset()

        XCTAssertNil(engine.failure)
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor
    func testBeginSessionClearsNonblockingFailedSwitchWarning() {
        let engine = TranscriptionEngine()
        engine.failure = .modelLoad("Switch failed")
        engine.isModelLoaded = true

        engine.beginSession()
        defer { engine.endSession() }

        XCTAssertNil(engine.failure)
        XCTAssertTrue(engine.isSessionActive)
        XCTAssertFalse(engine.canRetryModelLoad)
    }

    @MainActor
    func testBeginSessionPreservesBlockingFailureWithoutUsableModel() {
        let engine = TranscriptionEngine()
        engine.failure = .modelLoad("Initial load failed")

        engine.beginSession()
        defer { engine.endSession() }

        XCTAssertEqual(engine.failure, .modelLoad("Initial load failed"))
        XCTAssertTrue(engine.canRetryModelLoad)
    }

    @MainActor
    func testClearFailureClearsMessageAndKindTogether() {
        let engine = TranscriptionEngine()
        engine.failure = .modelLoad("Failed")

        engine.clearFailure()

        XCTAssertNil(engine.failure)
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor
    func testDeferredSwitchIsDiscardedAfterPersistedSelectionChanges() async {
        let settings = TranscriptionSettings.shared
        let originalModel = settings.whisperModel
        defer { settings.whisperModel = originalModel }

        let engine = TranscriptionEngine()
        engine.isModelLoaded = true
        engine.beginSession()

        let deferredModel = "test-deferred-model"
        settings.whisperModel = deferredModel
        await engine.loadModel(name: deferredModel)

        engine.endSession()
        settings.whisperModel = "test-newer-model"

        // endSession dispatches the deferred request in a new task. Keeping all
        // mutations before this yield makes the ordering deterministic.
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(engine.isModelLoaded)
        XCTAssertTrue(engine.loadingProgress.isEmpty)
        XCTAssertFalse(engine.isDownloading)
        XCTAssertNil(engine.failure)
    }
}

final class TranscriptionEngineCacheTests: XCTestCase {
    private let requiredBundles = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    func testCompleteTurboCacheIsEligibleForLocalFastPath() throws {
        let cacheBase = try makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: cacheBase) }

        let variant = "openai_whisper-large-v3-v20240930_turbo"
        let folder = try createModelBundles(for: variant, in: cacheBase)
        try createTokenizer(repo: "openai/whisper-large-v3", in: cacheBase)

        XCTAssertEqual(
            TranscriptionEngine.installedModelFolder(for: variant, cacheBase: cacheBase),
            folder
        )
    }

    func testEachRequiredModelBundleMissingRejectsLocalFastPath() throws {
        let variant = "openai_whisper-small"

        for missingBundle in requiredBundles {
            let cacheBase = try makeTemporaryCache()
            defer { try? FileManager.default.removeItem(at: cacheBase) }
            _ = try createModelBundles(for: variant, in: cacheBase, omitting: missingBundle)
            try createTokenizer(repo: "openai/whisper-small", in: cacheBase)

            XCTAssertNil(
                TranscriptionEngine.installedModelFolder(for: variant, cacheBase: cacheBase),
                "Missing \(missingBundle) must reject the local fast path"
            )
        }
    }

    func testEitherTokenizerFileMissingRejectsLocalFastPath() throws {
        let variant = "openai_whisper-base"

        for missingFile in ["tokenizer.json", "tokenizer_config.json"] {
            let cacheBase = try makeTemporaryCache()
            defer { try? FileManager.default.removeItem(at: cacheBase) }
            _ = try createModelBundles(for: variant, in: cacheBase)
            try createTokenizer(repo: "openai/whisper-base", in: cacheBase, omitting: missingFile)

            XCTAssertNil(
                TranscriptionEngine.installedModelFolder(for: variant, cacheBase: cacheBase),
                "Missing \(missingFile) must reject the local fast path"
            )
        }
    }

    func testSupportedVariantsUseExpectedTokenizerRepository() throws {
        let cases = [
            ("openai_whisper-large-v3-v20240930_turbo", "openai/whisper-large-v3"),
            ("openai_whisper-large-v3-v20240930", "openai/whisper-large-v3"),
            ("distil-whisper_distil-large-v3_turbo", "openai/whisper-large-v3"),
            ("openai_whisper-small", "openai/whisper-small"),
            ("openai_whisper-base", "openai/whisper-base"),
            ("openai_whisper-tiny", "openai/whisper-tiny"),
        ]

        for (variant, tokenizerRepo) in cases {
            let cacheBase = try makeTemporaryCache()
            defer { try? FileManager.default.removeItem(at: cacheBase) }
            let folder = try createModelBundles(for: variant, in: cacheBase)
            try createTokenizer(repo: tokenizerRepo, in: cacheBase)

            XCTAssertEqual(
                TranscriptionEngine.installedModelFolder(for: variant, cacheBase: cacheBase),
                folder,
                "\(variant) should use tokenizer repo \(tokenizerRepo)"
            )
        }
    }

    func testUnknownVariantRejectsLocalFastPath() throws {
        let cacheBase = try makeTemporaryCache()
        defer { try? FileManager.default.removeItem(at: cacheBase) }

        let variant = "custom-whisper-model"
        _ = try createModelBundles(for: variant, in: cacheBase)

        XCTAssertNil(TranscriptionEngine.installedModelFolder(for: variant, cacheBase: cacheBase))
    }

    private func makeTemporaryCache() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seminarly-TranscriptionEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func createModelBundles(
        for variant: String,
        in cacheBase: URL,
        omitting omittedBundle: String? = nil
    ) throws -> URL {
        let folder = cacheBase.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(variant)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bundle in requiredBundles where bundle != omittedBundle {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(bundle, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return folder
    }

    private func createTokenizer(
        repo: String,
        in cacheBase: URL,
        omitting omittedFile: String? = nil
    ) throws {
        let folder = cacheBase.appendingPathComponent("models/\(repo)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["tokenizer.json", "tokenizer_config.json"] where file != omittedFile {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: folder.appendingPathComponent(file).path,
                    contents: Data()
                )
            )
        }
    }
}
