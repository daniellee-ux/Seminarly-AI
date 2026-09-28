import XCTest
import AVFoundation
import QwenASR
@testable import Seminarly

final class QwenASRTests: XCTestCase {
    func testChunkBoundariesCoverEverySampleOnceIncludingShortTail() {
        for count in [0, 1, 200, 16000, 8 * 16000, 30 * 16000 + 137] {
            let samples = (0..<count).map { Float($0 % 19) / 100 }
            let ranges = QwenAudioChunks.ranges(in: samples)
            XCTAssertEqual(ranges.first?.lowerBound ?? 0, 0)
            XCTAssertEqual(ranges.last?.upperBound ?? 0, count)
            XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, count)
            for (left, right) in zip(ranges, ranges.dropFirst()) {
                XCTAssertEqual(left.upperBound, right.lowerBound)
            }
            XCTAssertTrue(ranges.allSatisfy { !$0.isEmpty && $0.count <= 8 * 16000 })
        }
    }

    func testChunkCutPrefersPauseNearBoundary() {
        var samples = [Float](repeating: 0.1, count: 12 * 16000)
        samples.replaceSubrange(7 * 16000..<(7 * 16000 + 320), with: repeatElement(0, count: 320))
        XCTAssertEqual(QwenAudioChunks.ranges(in: samples).first?.upperBound, 7 * 16000 + 320)
    }

    func testSilenceDoesNotBecomeAPlaceholderTranscript() {
        XCTAssertFalse(QwenAudioChunks.hasSignal([Float](repeating: 0, count: 100)[...]))
        XCTAssertTrue(QwenAudioChunks.hasSignal([Float(0), 0.002, 0][...]))
    }

    func testLanguageNamesAndUnsupportedLanguageAreExplicit() {
        XCTAssertEqual(TranscriptionLanguage.zh.qwenName, "Chinese")
        XCTAssertEqual(TranscriptionLanguage.yue.qwenName, "Cantonese")
        XCTAssertEqual(TranscriptionLanguage.ja.qwenName, "Japanese")
        XCTAssertNil(TranscriptionLanguage.auto.qwenName)
        XCTAssertNil(TranscriptionLanguage.no.qwenName)
        XCTAssertEqual(TranscriptionLanguage.fromQwen("cantonese"), .yue)
        XCTAssertEqual(TranscriptionLanguage.fromQwen("Chinese"), .zh)
        XCTAssertNil(TranscriptionLanguage.fromQwen("unknown"))
        XCTAssertEqual(TranscriptionLanguage.codeFromQwen("Chinese"), "zh")
        XCTAssertEqual(TranscriptionLanguage.codeFromQwen("Indonesian"), "id")
        XCTAssertEqual(TranscriptionLanguage.codeFromQwen("Filipino"), "tl")
        XCTAssertNil(TranscriptionLanguage.codeFromQwen("unknown"))
    }

    func testCacheRejectsPartialAndSameLengthCorruptedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weights.safetensors")
        let file = QwenModelStore.File(name: "weights.safetensors", size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertFalse(try QwenModelStore.isValid(url, file: file))
        try Data("ab".utf8).write(to: url)
        XCTAssertFalse(try QwenModelStore.isValid(url, file: file))
        try Data("abd".utf8).write(to: url)
        XCTAssertFalse(try QwenModelStore.isValid(url, file: file))
        try Data("abc".utf8).write(to: url)
        XCTAssertTrue(try QwenModelStore.isValid(url, file: file))
    }

    @MainActor
    func testEngineKeepsSilenceInTimeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SEMINARLY_QWEN_SMOKE_ENGINE"] == "1",
              let audioPath = environment["SEMINARLY_QWEN_SMOKE_AUDIO"] else {
            throw XCTSkip("Set SEMINARLY_QWEN_SMOKE_ENGINE=1 with an installed Qwen model to test the engine.")
        }
        // Fail before calling the downloader if the opt-in cache is incomplete.
        for file in QwenModelStore.files {
            guard try QwenModelStore.isValid(QwenModelStore.directory.appendingPathComponent(file.name), file: file) else {
                XCTFail("Install the pinned Qwen files before running the engine smoke test")
                return
            }
        }
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: input)
        let converter = try AudioFormatConverter(sourceFormat: audio.processingFormat)
        let output = try XCTUnwrap(converter.convert(input))
        let samples = try XCTUnwrap(AudioFormatConverter.extractFloatSamples(from: output))
        let engine = TranscriptionEngine()
        await engine.loadModel(name: QwenModelStore.modelID)
        XCTAssertTrue(engine.isModelLoaded, engine.errorMessage ?? "Model was not loaded")
        XCTAssertTrue(engine.usesQwen)
        engine.beginSession()
        defer { engine.endSession() }
        engine.appendAudio([Float](repeating: 0, count: 30 * 16000))
        let silence = await engine.finalizeTranscription()
        XCTAssertTrue(silence.isEmpty)
        engine.appendAudio(samples)
        let transcript = await engine.finalizeTranscription()
        let first = try XCTUnwrap(transcript.first)
        XCTAssertEqual(first.startTime, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(transcript.last).endTime,
                       30 + Double(samples.count) / 16000, accuracy: 0.001)
        XCTAssertNil(engine.failure)
        XCTAssertNotNil(engine.detectedLanguage)
        print("QWEN_ENGINE language=\(engine.detectedLanguage ?? "unknown") start=\(first.startTime) text=\(engine.liveText)")
    }

    /// Opt-in real inference; no network or model download is initiated by tests.
    /// Set TEST_RUNNER_SEMINARLY_QWEN_SMOKE_MODEL and _AUDIO for xcodebuild.
    func testLocalMixedQuantizationInference() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["SEMINARLY_QWEN_SMOKE_MODEL"],
              let audioPath = environment["SEMINARLY_QWEN_SMOKE_AUDIO"] else {
            throw XCTSkip("Set SEMINARLY_QWEN_SMOKE_MODEL and SEMINARLY_QWEN_SMOKE_AUDIO for local inference.")
        }
        guard QwenModelStore.isSupported else { throw XCTSkip("Apple Silicon required") }
        let directory = URL(fileURLWithPath: modelPath)
        for file in QwenModelStore.files {
            XCTAssertTrue(try QwenModelStore.isValid(directory.appendingPathComponent(file.name), file: file))
        }
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: input)
        let converter = try AudioFormatConverter(sourceFormat: audio.processingFormat)
        let output = try XCTUnwrap(converter.convert(input))
        let samples = try XCTUnwrap(AudioFormatConverter.extractFloatSamples(from: output))
        let runtime = QwenASRRuntime()
        let start = Date()
        try await runtime.load(from: directory)
        print("QWEN_SMOKE load_seconds=\(Date().timeIntervalSince(start))")
        let decodeStart = Date()
        var texts: [String] = []
        for range in QwenAudioChunks.ranges(in: samples) {
            let result = try await runtime.transcribe(samples: Array(samples[range]), language: nil)
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertFalse(result.text.contains("<|"))
            texts.append(result.text)
            print("QWEN_SMOKE language=\(result.language ?? "unknown") text=\(result.text)")
        }
        print("QWEN_SMOKE audio_seconds=\(Double(samples.count) / 16000) decode_seconds=\(Date().timeIntervalSince(decodeStart))")
        XCTAssertFalse(texts.isEmpty)
        // Ensure a cancelled job cannot emit another transcript after reset.
        let cancelled = Task {
            return try await runtime.transcribe(samples: samples, language: nil)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled inference should not succeed")
        } catch is CancellationError {}
        await runtime.unload()
    }
}
