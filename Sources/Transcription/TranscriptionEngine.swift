import Foundation
@preconcurrency import WhisperKit
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "Transcription")

@MainActor
final class TranscriptionEngine: ObservableObject {
    /// App-lifetime instance. The engine must outlive any single window: models
    /// take seconds to load, so closing and reopening a window must never throw
    /// a loaded model away.
    static let shared = TranscriptionEngine()

    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var liveText: String = ""
    @Published var segments: [TranscriptSegment] = []
    @Published var loadingProgress: String = ""
    @Published var downloadFraction: Double = 0
    @Published var isDownloading = false
    @Published var errorMessage: String?
    @Published var detectedLanguage: String?

    /// When set (e.g. "en", "zh"), forces WhisperKit to transcribe in this language.
    /// When nil, WhisperKit auto-detects per chunk.
    var selectedLanguage: String?

    /// Name of the currently loaded model variant; nil while unloaded/loading.
    private(set) var loadedModelName: String?

    private var whisperKit: WhisperKit?
    private var accumulatedAudio: [Float] = []
    private var transcriptionTask: Task<Void, Never>?
    private var hasDetectedLanguage = false
    private let chunkDuration: Double = 30.0 // Process in 30-second chunks
    private let sampleRate: Double = 16000.0

    // The load runs in an engine-owned task so a window closing mid-load (which
    // cancels the view's .task) cannot abort it; the next window joins it instead.
    private var loadTask: Task<Void, Never>?
    private var loadingModelName: String?

    func loadModel(name: String = TranscriptionSettings.defaultModel) async {
        if isModelLoaded && loadedModelName == name { return }

        // Join an in-flight load of the same model; supersede one of a different
        // model. Loop: by the time a superseded task drains, another caller may
        // have started a new one.
        while let inFlight = loadTask {
            if loadingModelName == name {
                await inFlight.value
                return
            }
            inFlight.cancel()
            await inFlight.value
            if loadTask == inFlight {
                loadTask = nil
                loadingModelName = nil
            }
        }

        if isModelLoaded && loadedModelName == name { return }

        loadingModelName = name
        let task = Task { await performLoad(name: name) }
        loadTask = task
        await task.value
        if loadTask == task {
            loadTask = nil
            loadingModelName = nil
        }
    }

    private func performLoad(name: String) async {
        errorMessage = nil
        isModelLoaded = false
        loadedModelName = nil
        whisperKit = nil

        // Offline-first: a fully installed model loads straight from disk with
        // zero network. WhisperKit.download always hits huggingface.co before
        // touching the cache, so an unreachable network (offline, blocked, or a
        // stalled system proxy) would otherwise hang or fail the load even
        // though the model is already installed.
        if let localFolder = Self.installedModelFolder(for: name) {
            loadingProgress = "Preparing transcription model..."
            do {
                whisperKit = try await WhisperKit(
                    modelFolder: localFolder.path,
                    verbose: false,
                    logLevel: .none,
                    download: false
                )
                loadedModelName = name
                isModelLoaded = true
                loadingProgress = ""
                logger.notice("Loaded \(name, privacy: .public) from local cache")
                return
            } catch {
                logger.error("Local load of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — falling back to download")
            }
        }

        do {
            try Task.checkCancellation()

            // Step 1: Download with progress
            isDownloading = true
            downloadFraction = 0
            loadingProgress = "Downloading \(name)..."
            let modelFolder = try await WhisperKit.download(
                variant: name
            ) { @Sendable [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadFraction = progress.fractionCompleted
                    let pct = Int(progress.fractionCompleted * 100)
                    self.loadingProgress = "Downloading \(name)... \(pct)%"
                }
            }
            isDownloading = false
            try Task.checkCancellation()

            // Step 2: Load model from downloaded folder
            loadingProgress = "Preparing transcription model..."
            whisperKit = try await WhisperKit(
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .none,
                download: false
            )
            loadedModelName = name
            isModelLoaded = true
            loadingProgress = ""
            logger.notice("Loaded \(name, privacy: .public) after download")
        } catch {
            loadingProgress = ""
            isDownloading = false
            // A superseded load (model switched mid-download) is not an error.
            if error is CancellationError || Task.isCancelled {
                logger.notice("Load of \(name, privacy: .public) cancelled")
                return
            }
            logger.error("Failed to load model \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    /// The folder `WhisperKit.download` would produce for this variant, or nil
    /// unless the model looks installed AND its tokenizer is cached (both are
    /// needed for a zero-network load). Mirrors HubApi's default layout:
    /// ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>.
    /// A partial download that slips past this check still fails the WhisperKit
    /// init, which then falls back to the download path.
    nonisolated static func installedModelFolder(for variant: String) -> URL? {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let folder = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(variant)")
        // WhisperKit requires exactly these three compiled bundles; the prefill
        // bundle and the *.json files are optional.
        for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            guard fm.fileExists(atPath: folder.appendingPathComponent(bundle).path) else { return nil }
        }
        guard isTokenizerCached(for: variant) else { return nil }
        return folder
    }

    /// WhisperKit resolves the tokenizer repo from the loaded model's dims and
    /// fetches it from the network when not cached — even with download:false.
    /// Both files must exist locally for a fully-offline load; this mirrors
    /// WhisperKit's variant→tokenizer mapping for the variants Seminarly offers.
    nonisolated static func isTokenizerCached(for variant: String) -> Bool {
        let repo: String
        if variant.contains("large-v3") {
            repo = "openai/whisper-large-v3"
        } else if variant.contains("small") {
            repo = "openai/whisper-small"
        } else if variant.contains("base") {
            repo = "openai/whisper-base"
        } else if variant.contains("tiny") {
            repo = "openai/whisper-tiny"
        } else {
            return false // unknown variant — use the download path
        }
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let dir = documents.appendingPathComponent("huggingface/models/\(repo)")
        return ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    func appendAudio(_ samples: [Float]) {
        accumulatedAudio.append(contentsOf: samples)

        // Trigger transcription when we have enough audio
        let chunkSamples = Int(chunkDuration * sampleRate)
        if accumulatedAudio.count >= chunkSamples && !isTranscribing {
            processAccumulatedAudio()
        }
    }

    func processAccumulatedAudio() {
        guard !isTranscribing, !accumulatedAudio.isEmpty else { return }

        let audioToProcess = accumulatedAudio
        accumulatedAudio = []

        transcriptionTask = Task {
            await transcribe(audioToProcess)
        }
    }

    func finalizeTranscription() async -> [TranscriptSegment] {
        let inFlightTranscription = transcriptionTask
        transcriptionTask = nil
        await inFlightTranscription?.value

        if !accumulatedAudio.isEmpty {
            let remaining = accumulatedAudio
            accumulatedAudio = []
            await transcribe(remaining)
        }
        return segments
    }

    private func transcribe(_ audio: [Float]) async {
        guard let whisperKit else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Calculate offset ONCE per chunk — WhisperKit segment timestamps
            // are relative to the start of the audio array passed in.
            let timeOffset = totalTranscribedDuration()
            let options = DecodingOptions(language: selectedLanguage, wordTimestamps: true)
            let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
            for result in results {
                for segment in result.segments {
                    let cleanedText = Self.stripWhisperTokens(segment.text)
                    let newSegment = TranscriptSegment(
                        startTime: timeOffset + Double(segment.start),
                        endTime: timeOffset + Double(segment.end),
                        text: cleanedText
                    )
                    if !newSegment.text.isEmpty {
                        segments.append(newSegment)
                        liveText += newSegment.text + " "
                    }
                }
            }
        } catch {
            errorMessage = "Transcription error: \(error.localizedDescription)"
        }
    }

    /// Remove WhisperKit special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect spoken language using WhisperKit's acoustic analysis (first 30s of audio).
    /// Independent of transcription output — correctly identifies Chinese even if
    /// the model transcribes it as English text.
    func detectLanguage(_ audio: [Float]) async {
        guard !hasDetectedLanguage, let whisperKit else { return }
        hasDetectedLanguage = true
        do {
            let (language, probabilities) = try await whisperKit.detectLangauge(audioArray: audio)
            detectedLanguage = language
            let top3 = probabilities.sorted { $0.value > $1.value }.prefix(3)
            logger.info("Language detection: \(language) — \(top3.map { "\($0.key): \(String(format: "%.1f%%", $0.value * 100))" }.joined(separator: ", "))")
        } catch {
            logger.warning("Language detection failed: \(error.localizedDescription)")
        }
    }

    private func totalTranscribedDuration() -> Double {
        segments.last?.endTime ?? 0
    }

    func reset() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        accumulatedAudio = []
        segments = []
        liveText = ""
        isTranscribing = false
        errorMessage = nil
        detectedLanguage = nil
        hasDetectedLanguage = false
        selectedLanguage = nil
    }
}
