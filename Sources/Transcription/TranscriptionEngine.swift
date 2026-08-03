import Foundation
@preconcurrency import WhisperKit
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "Transcription")

@MainActor
final class TranscriptionEngine: ObservableObject {
    enum Failure: Equatable {
        case modelLoad(String)
        case transcription(String)

        var message: String {
            switch self {
            case .modelLoad(let message), .transcription(let message):
                return message
            }
        }
    }

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
    @Published var failure: Failure?
    @Published var detectedLanguage: String?

    var errorMessage: String? { failure?.message }

    var canRetryModelLoad: Bool {
        guard !isModelLoaded else { return false }
        if case .some(.modelLoad(_)) = failure { return true }
        return false
    }

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
    // Guards published state against delayed download callbacks and Core ML
    // initializers that return after their load was superseded. Core ML model
    // loading is not cooperatively cancellable inside WhisperKit 0.18.
    private var loadGeneration = 0
    // Model switch requested while a recording session held the engine —
    // applied by endSession() once the session releases it.
    private var pendingModelName: String?
    // Records user intent when a request enters the engine. A deferred switch
    // must not become "latest" merely because its unstructured task happens to
    // run after a newer picker request.
    private var desiredModelName: String?

    func loadModel(name: String = TranscriptionSettings.defaultModel) async {
        // Settings cancels superseded picker requests before they reach this
        // actor. A cancelled caller must not clear a newer pending selection or
        // start its own replacement after waiting for an older load to drain.
        guard !Task.isCancelled else { return }
        desiredModelName = name
        await loadDesiredModel(name: name)
    }

    private func loadDesiredModel(name: String) async {
        // The wrapper above can yield when entering this async function. If a
        // newer request got the actor first, this older request is already stale.
        guard !Task.isCancelled, desiredModelName == name else { return }

        // Same-model callers join the engine-owned task without invalidating it.
        if let inFlight = loadTask,
           loadingModelName == name,
           !inFlight.isCancelled
        {
            await inFlight.value
            return
        }

        // Fast paths are safe only when no different engine task is queued. If
        // one exists but has not begun performLoad yet, the latest selection must
        // still invalidate and drain it before returning or queueing a session
        // switch; otherwise that stale task could commit after this return.
        if loadTask == nil {
            if isModelLoaded && loadedModelName == name {
                // The latest request matches the loaded model — cancel any switch
                // still queued from earlier in the session (A→B→A must end on A).
                // Deliberately NOT clearing failure here: a failed switch
                // reverts the persisted selection, which re-enters this path, and
                // the failure banner must survive that (it doesn't block recording;
                // recordingReadiness only blocks when no model is loaded).
                pendingModelName = nil
                return
            }

            // Never swap models while a recording session is using the engine —
            // queue the latest request for endSession().
            if isSessionActive && isModelLoaded {
                pendingModelName = name
                return
            }
        }

        // Claim latest-request identity before awaiting a non-cooperatively
        // cancellable Core ML load. This immediately invalidates the old task's
        // delayed progress callbacks; a still-newer request invalidates this one
        // while it waits for the old task to drain.
        loadGeneration &+= 1
        let generation = loadGeneration
        clearModelLoadStatus(generation: generation)

        // Supersede an in-flight load of a different model. Loop because a newer
        // request may start another task while this caller is suspended.
        while let inFlight = loadTask {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            inFlight.cancel()
            await inFlight.value
            if loadTask == inFlight {
                loadTask = nil
                loadingModelName = nil
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }

        guard generation == loadGeneration, !Task.isCancelled else { return }
        if isModelLoaded && loadedModelName == name {
            pendingModelName = nil
            return
        }
        if isSessionActive && isModelLoaded {
            pendingModelName = name
            return
        }

        // This request is being served now — it supersedes any queued switch.
        pendingModelName = nil
        loadingModelName = name
        let task = Task { await performLoad(name: name, generation: generation) }
        loadTask = task
        await task.value
        if loadTask == task {
            loadTask = nil
            loadingModelName = nil
        }
    }

    private func performLoad(name: String, generation: Int) async {
        guard generation == loadGeneration, !Task.isCancelled else { return }

        // Re-check: a recording may have claimed the engine between loadModel's
        // guard and this task's first turn on the MainActor — never tear the
        // model out from under it. Queue the swap for endSession() instead.
        if isSessionActive && whisperKit != nil {
            pendingModelName = name
            return
        }

        failure = nil
        clearModelLoadStatus(generation: generation)
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
                    loadingProgress = "Loading the installed transcription model..."
                    let startedAt = Date()
                    try await loadWhisperKit(from: localFolder, name: name, generation: generation)
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
                    logger.notice("Loaded \(name, privacy: .public) from local cache in \(elapsed, privacy: .public)s")
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
                    guard self.loadGeneration == generation,
                          self.loadingModelName == name,
                          self.isDownloading
                    else { return }
                    let fraction = min(max(progress.fractionCompleted, 0), 1)
                    self.downloadFraction = max(self.downloadFraction, fraction)
                    let pct = Int(self.downloadFraction * 100)
                    self.loadingProgress = "Downloading \(name)... \(pct)%"
                }
            }
            isDownloading = false
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }

            // Step 2: Load model from downloaded folder
            loadingProgress = "Download complete. Loading the transcription model..."
            let startedAt = Date()
            try await loadWhisperKit(from: modelFolder, name: name, generation: generation)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
            logger.notice("Loaded \(name, privacy: .public) after download in \(elapsed, privacy: .public)s")
        } catch {
            clearModelLoadStatus(generation: generation)
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
            }
            // A superseded load may restore its in-memory fallback so the next
            // request can snapshot it, but it must never roll back the latest
            // persisted selection or publish an error.
            let superseded = generation != loadGeneration
                || error is CancellationError
                || Task.isCancelled
            if superseded {
                logger.notice("Load of \(name, privacy: .public) cancelled")
                return
            }
            if let previousName, previousKit != nil,
               TranscriptionSettings.shared.whisperModel == name
            {
                TranscriptionSettings.shared.whisperModel = previousName
            }
            logger.error("Failed to load model \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failure = .modelLoad("Failed to load model: \(error.localizedDescription)")
        }
    }

    private func loadWhisperKit(from folder: URL, name: String, generation: Int) async throws {
        let candidate = try await WhisperKit(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .none,
            download: false
        )
        // WhisperKit/Core ML may finish normally after Task.cancel(). Only the
        // latest generation may publish its model or clear the current status.
        try Task.checkCancellation()
        guard generation == loadGeneration, loadingModelName == name else {
            throw CancellationError()
        }
        whisperKit = candidate
        loadedModelName = name
        isModelLoaded = true
        clearModelLoadStatus(generation: generation)
    }

    private func clearModelLoadStatus(generation: Int) {
        guard generation == loadGeneration else { return }
        loadingProgress = ""
        downloadFraction = 0
        isDownloading = false
    }

    // MARK: - Recording session lifecycle

    /// Claim the engine for a recording: clears per-session state and blocks
    /// resets/model swaps from other windows until `endSession()`.
    func beginSession() {
        reset()
        // A failed model switch may leave a non-blocking warning while the old
        // model remains usable. Starting a recording accepts that fallback and
        // begins the session with a clean banner. A blocking initial-load error
        // is preserved defensively; normal UI readiness never calls this path.
        if isModelLoaded, case .some(.modelLoad(_)) = failure {
            failure = nil
        }
        isSessionActive = true
    }

    func clearFailure() {
        failure = nil
    }

    func retryModelLoad() async {
        guard canRetryModelLoad else {
            clearFailure()
            return
        }
        failure = nil
        await loadModel(name: TranscriptionSettings.shared.whisperModel)
    }

    /// Release the engine after the post-stop pipeline has consumed its output
    /// (or after the recording view died mid-recording and no pipeline will run),
    /// then apply any model switch that was requested during the session.
    func endSession() {
        isSessionActive = false
        if let pending = pendingModelName {
            pendingModelName = nil
            if pending != loadedModelName {
                Task { [weak self] in
                    await self?.resumeDeferredModelLoad(name: pending)
                }
            }
        }
    }

    private func resumeDeferredModelLoad(name: String) async {
        // The persisted selection changes synchronously when the picker changes,
        // potentially before its new Task reaches this actor. Check both sources
        // of intent so an old endSession task can never supersede that selection.
        guard !Task.isCancelled,
              desiredModelName == name,
              TranscriptionSettings.shared.whisperModel == name
        else {
            logger.notice("Discarded stale deferred model load for \(name, privacy: .public)")
            return
        }
        await loadDesiredModel(name: name)
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
        guard let base = modelCacheBase else { return nil }
        return installedModelFolder(for: variant, cacheBase: base)
    }

    /// Testable form of the local fast-path predicate. The app wrapper above
    /// supplies its pinned cache root; tests supply an isolated temporary root.
    nonisolated static func installedModelFolder(for variant: String, cacheBase: URL) -> URL? {
        let fm = FileManager.default
        let folder = cacheBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
        // WhisperKit requires exactly these three compiled bundles; the prefill
        // bundle and the *.json files are optional.
        for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            guard fm.fileExists(atPath: folder.appendingPathComponent(bundle).path) else { return nil }
        }
        guard isTokenizerCached(for: variant, cacheBase: cacheBase) else { return nil }
        return folder
    }

    /// WhisperKit resolves the tokenizer repo from the loaded model's dims and
    /// fetches it from the network when not cached — even with download:false.
    /// Both files must exist locally for a fully-offline load; this mirrors
    /// WhisperKit's variant→tokenizer mapping for the variants Seminarly offers.
    nonisolated static func isTokenizerCached(for variant: String) -> Bool {
        guard let base = modelCacheBase else { return false }
        return isTokenizerCached(for: variant, cacheBase: base)
    }

    nonisolated static func isTokenizerCached(for variant: String, cacheBase: URL) -> Bool {
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
        let dir = cacheBase.appendingPathComponent("models/\(repo)")
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
            failure = .transcription("Transcription error: \(error.localizedDescription)")
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
        // Setup views must preserve model-load failures so Error/Retry remains
        // visible. Only runtime transcription failures belong to the old session.
        if case .some(.transcription(_)) = failure {
            failure = nil
        }
        detectedLanguage = nil
        hasDetectedLanguage = false
        selectedLanguage = nil
    }
}
