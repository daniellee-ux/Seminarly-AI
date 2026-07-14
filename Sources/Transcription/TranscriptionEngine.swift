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

    /// True from the moment a recording claims the engine until its post-stop
    /// finalization pipeline has read everything it needs. The engine is shared
    /// app-wide, and `appState.isRecording` goes false at stop time — several
    /// seconds before finalization finishes — so this is the only signal that
    /// covers the whole window in which a reset or model swap would corrupt or
    /// lose a recording's transcript.
    @Published private(set) var isSessionActive = false

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
    // Model switch requested while a recording session held the engine —
    // applied by endSession() once the session releases it.
    private var pendingModelName: String?

    func loadModel(name: String = TranscriptionSettings.defaultModel) async {
        if isModelLoaded && loadedModelName == name {
            // The latest request matches the loaded model — cancel any switch
            // still queued from earlier in the session (A→B→A must end on A).
            // Deliberately NOT clearing errorMessage here: a failed switch
            // reverts the persisted selection, which re-enters this path, and
            // the failure banner must survive that (it doesn't block recording;
            // recordingReadiness only blocks when no model is loaded).
            pendingModelName = nil
            return
        }

        // Never swap models while a recording session is using the engine — a
        // new window's .task or a Settings change must not tear the model out
        // from under a live recording or its finalization. Queue the request;
        // endSession() applies it.
        if isSessionActive && isModelLoaded {
            pendingModelName = name
            return
        }

        // Join an in-flight load of the same model; supersede one of a different
        // model. Loop: by the time a superseded task drains, another caller may
        // have started a new one.
        while let inFlight = loadTask {
            // A cancelled task is already superseded — never join it (its result
            // will be discarded); fall through to drain and restart.
            if loadingModelName == name, !inFlight.isCancelled {
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

        // This request is being served now — it supersedes any queued switch.
        pendingModelName = nil
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
        // Re-check: a recording may have claimed the engine between loadModel's
        // guard and this task's first turn on the MainActor — never tear the
        // model out from under it. Queue the swap for endSession() instead.
        if isSessionActive && whisperKit != nil {
            pendingModelName = name
            return
        }

        errorMessage = nil
        // Block new recordings during the swap, but keep the old instance alive
        // until the replacement has loaded — a failed switch must not strand
        // the user with no model at all. Cost: both models are transiently
        // resident during a (rare, user-initiated) switch.
        let previousKit = whisperKit
        let previousName = loadedModelName
        isModelLoaded = false
        loadedModelName = nil

        do {
            // Offline-first: a fully installed model loads straight from disk with
            // zero network. WhisperKit.download always hits huggingface.co before
            // touching the cache, so an unreachable network (offline, blocked, or a
            // stalled system proxy) would otherwise hang or fail the load even
            // though the model is already installed.
            if let localFolder = Self.installedModelFolder(for: name) {
                do {
                    try Task.checkCancellation()
                    loadingProgress = "Preparing transcription model..."
                    try await loadWhisperKit(from: localFolder, name: name)
                    logger.notice("Loaded \(name, privacy: .public) from local cache")
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("Local load of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — falling back to download")
                }
            }

            try Task.checkCancellation()

            // Step 1: Download with progress
            isDownloading = true
            downloadFraction = 0
            loadingProgress = "Downloading \(name)..."
            let modelFolder = try await WhisperKit.download(
                variant: name,
                downloadBase: Self.modelCacheBase
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
            try await loadWhisperKit(from: modelFolder, name: name)
            logger.notice("Loaded \(name, privacy: .public) after download")
        } catch {
            loadingProgress = ""
            isDownloading = false
            // The old model is still alive (previousKit) — put it back so a
            // failed switch keeps working instead of stranding the user with
            // no model at all. Also roll back the persisted selection when it
            // still names the failed model: otherwise the next launch retries
            // the uninstalled model and blocks recording despite a working
            // installed one. (Skipped when a newer request already changed the
            // setting again — the guard below only matches this load's name.)
            if let previousKit {
                whisperKit = previousKit
                loadedModelName = previousName
                isModelLoaded = true
                if let previousName, TranscriptionSettings.shared.whisperModel == name {
                    TranscriptionSettings.shared.whisperModel = previousName
                }
            }
            // A superseded load (model switched mid-download) is not an error.
            if error is CancellationError || Task.isCancelled {
                logger.notice("Load of \(name, privacy: .public) cancelled")
                return
            }
            logger.error("Failed to load model \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    private func loadWhisperKit(from folder: URL, name: String) async throws {
        whisperKit = try await WhisperKit(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .none,
            download: false
        )
        loadedModelName = name
        isModelLoaded = true
        loadingProgress = ""
    }

    // MARK: - Recording session lifecycle

    /// Claim the engine for a recording: clears per-session state and blocks
    /// resets/model swaps from other windows until `endSession()`.
    func beginSession() {
        reset()
        isSessionActive = true
    }

    /// Release the engine after the post-stop pipeline has consumed its output
    /// (or after the recording view died mid-recording and no pipeline will run),
    /// then apply any model switch that was requested during the session.
    func endSession() {
        isSessionActive = false
        if let pending = pendingModelName {
            pendingModelName = nil
            if pending != loadedModelName {
                Task { await loadModel(name: pending) }
            }
        }
    }

    // MARK: - Local model cache

    /// App-pinned Hugging Face cache root. Passed to `WhisperKit.download` and
    /// used for local lookups, so the app — not the library default — fixes
    /// where models live. Matches HubApi's historical default on non-sandboxed
    /// macOS (~/Documents/huggingface), where existing installs already are.
    nonisolated static var modelCacheBase: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface")
    }

    /// The folder `WhisperKit.download` would produce for this variant, or nil
    /// unless the model looks installed AND its tokenizer is cached (both are
    /// needed for a zero-network load): <modelCacheBase>/models/argmaxinc/whisperkit-coreml/<variant>.
    /// A partial download that slips past this check still fails the WhisperKit
    /// init, which then falls back to the download path.
    nonisolated static func installedModelFolder(for variant: String) -> URL? {
        let fm = FileManager.default
        guard let base = modelCacheBase else { return nil }
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
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
        guard let base = modelCacheBase else { return false }
        let dir = base.appendingPathComponent("models/\(repo)")
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
