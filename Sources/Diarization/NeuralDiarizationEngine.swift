import CoreML
import Foundation
import FluidAudio
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "NeuralDiarization")

@MainActor
final class NeuralDiarizationEngine: ObservableObject {
    /// App-lifetime instance — models survive window close/reopen (see
    /// TranscriptionEngine.shared for rationale).
    static let shared = NeuralDiarizationEngine()

    @Published var isDiarizing = false
    @Published var isModelReady = false
    @Published var modelStatus = ""
    @Published var errorMessage: String?

    typealias EmbeddingProvider = @Sendable (SpeakerAudioSource, [Float]) async throws -> [SpeakerEmbedding]
    private let embeddingProvider: EmbeddingProvider?

    init(embeddingProvider: EmbeddingProvider? = nil) {
        self.embeddingProvider = embeddingProvider
    }

    nonisolated(unsafe) private let diarizer: OfflineDiarizerManager = {
        var config = OfflineDiarizerConfig()
        // Threshold = minimum cosine similarity to merge. Higher = stricter merging = more clusters.
        // pyannote default: 0.7135. Previous 0.30 was wrong direction (too permissive, merged everything).
        config.clustering.threshold = 0.70
        // Don't discard short speaker turns (default 1.0s filters out brief interjections).
        config.embedding.minSegmentDurationSeconds = 0.3
        // Allow shorter gaps between speakers (default 0.1).
        config.postProcessing.minGapDurationSeconds = 0.05
        // VBx precision term — pyannote default. Previous 0.15 was too high, locked VBx into bad AHC init.
        config.clustering.warmStartFa = 0.07
        // Finer segmentation steps (1.5s vs 2s) for detecting brief 1-2s speaker turns.
        config.segmentation.stepRatio = 0.15
        // Safety net: triggers K-Means on raw 256D embeddings if AHC+VBx collapse to 1 speaker.
        config.clustering.minSpeakers = 2
        return OfflineDiarizerManager(config: config)
    }()

    // Engine-owned so a window closing mid-prepare cannot abort it, and
    // concurrent callers (window .task, Retry banner) join instead of racing.
    private var prepareTask: Task<Void, Never>?

    /// Download and prepare neural diarization models (runs once, cached).
    func prepareModels() async {
        guard !isModelReady else {
            logger.info("Models already ready, skipping preparation")
            return
        }
        if let inFlight = prepareTask {
            await inFlight.value
            return
        }
        let task = Task { await performPrepare() }
        prepareTask = task
        await task.value
        if prepareTask == task {
            prepareTask = nil
        }
    }

    /// Models loaded once and reused by recording and rediarization via
    /// `initialize(models:)` — CoreML models load once per app run, and an
    /// initialized manager never re-enters FluidAudio's download path.
    private var cachedModels: OfflineDiarizerModels?

    private func performPrepare() async {
        errorMessage = nil
        modelStatus = "Preparing speaker diarization models..."
        logger.info("Starting model preparation...")

        // Purge-immune path: when the on-disk cache is complete, build the
        // models with plain CoreML and inject them. FluidAudio's own loader
        // (DownloadUtils.loadModels) deletes the entire cache on ANY load error
        // and re-downloads from Hugging Face — which permanently bricks
        // diarization for offline/blocked-network users — so it is reserved
        // for the cache-missing case below.
        var localModels: OfflineDiarizerModels?
        do {
            localModels = try await Self.loadModelsFromDisk()
        } catch {
            logger.error("Local diarization model load failed: \(error.localizedDescription, privacy: .public) — falling back to FluidAudio loader")
        }
        if let localModels {
            diarizer.initialize(models: localModels)
            cachedModels = localModels
            isModelReady = true
            modelStatus = "Speaker models ready"
            logger.info("Diarization models loaded from local cache")
            return
        }

        do {
            modelStatus = "Downloading speaker diarization models..."
            try await diarizer.prepareModels()
            // The files are on disk now — rebuild once through the purge-immune
            // loader and share that set (manager included), so rediarize() and
            // any later load can never re-enter the download/purge path.
            if let models = try? await Self.loadModelsFromDisk() {
                diarizer.initialize(models: models)
                cachedModels = models
            }
            isModelReady = true
            modelStatus = "Speaker models ready"
            logger.info("Models prepared successfully")
        } catch {
            let msg = "Failed to load diarization models: \(error.localizedDescription)"
            errorMessage = msg
            modelStatus = "Model loading failed"
            logger.error("Model preparation FAILED: \(error)")
        }
    }

    private struct DiarizerCacheError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Build the diarizer models directly from FluidAudio's on-disk cache with
    /// plain CoreML, bypassing DownloadUtils entirely. Returns nil when any
    /// required file is missing (fresh install → FluidAudio downloads them);
    /// throws when files exist but fail to load. Mirrors the configurations of
    /// OfflineDiarizerModels.load: computeUnits .all with low-precision GPU
    /// accumulation, except FBank which is pinned to CPU.
    nonisolated private static func loadModelsFromDisk() async throws -> OfflineDiarizerModels? {
        let repoDir = OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        let fm = FileManager.default
        let psiURL = repoDir.appendingPathComponent("plda-parameters.json")

        func modelURL(_ name: String) -> URL {
            repoDir.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        }
        let allPresent = ["Segmentation", "FBank", "Embedding", "PldaRho"]
            .allSatisfy { fm.fileExists(atPath: modelURL($0).path) }
            && fm.fileExists(atPath: psiURL.path)
        guard allPresent else { return nil }

        let mainConfig = MLModelConfiguration()
        mainConfig.computeUnits = .all
        mainConfig.allowLowPrecisionAccumulationOnGPU = true
        let fbankConfig = MLModelConfiguration()
        fbankConfig.computeUnits = .cpuOnly
        fbankConfig.allowLowPrecisionAccumulationOnGPU = true

        let start = Date()
        let segmentation = try await MLModel.load(contentsOf: modelURL("Segmentation"), configuration: mainConfig)
        let embedding = try await MLModel.load(contentsOf: modelURL("Embedding"), configuration: mainConfig)
        let pldaRho = try await MLModel.load(contentsOf: modelURL("PldaRho"), configuration: mainConfig)
        let fbank = try await MLModel.load(contentsOf: modelURL("FBank"), configuration: fbankConfig)
        let psi = try loadPLDAPsi(from: psiURL)

        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: pldaRho,
            pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(start)
        )
    }

    /// Parse the PLDA psi tensor from plda-parameters.json — the same format
    /// FluidAudio reads (tensors.psi.data_base64 → little-endian Float32 array).
    nonisolated private static func loadPLDAPsi(from url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psiInfo = tensors["psi"] as? [String: Any],
              let base64 = psiInfo["data_base64"] as? String,
              let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
        else {
            throw DiarizerCacheError(message: "Failed to decode PLDA psi parameters at \(url.path)")
        }
        let floatCount = decoded.count / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            throw DiarizerCacheError(message: "PLDA psi tensor is empty at \(url.path)")
        }
        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return floats.map(Double.init)
    }

    /// Diarize every available source without treating the microphone as one
    /// person. Source-tagged embeddings are saved for later total-count changes.
    func diarize(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float]?,
        sampleRate: Double = 16000,
        detectedLanguage: String? = nil
    ) async -> (segments: [TranscriptSegment], speakerEmbeddings: [SpeakerEmbedding]) {
        isDiarizing = true
        errorMessage = nil
        defer { isDiarizing = false }
        guard !segments.isEmpty else { return ([], []) }

        let annotated = DiarizationAudio.annotate(
            segments, system: systemSamples, microphone: micSamples ?? [], sampleRate: sampleRate
        )
        do {
            let embeddings = try await extractEmbeddings(
                systemSamples: systemSamples, micSamples: micSamples ?? [],
                sampleRate: sampleRate, detectedLanguage: detectedLanguage
            )
            let labeled = try SpeakerAttribution.assignOriginal(segments: annotated, embeddings: embeddings)
            logger.info("Diarized \(labeled.count) turns using \(embeddings.count) source-tagged embeddings; speakers: \(Set(labeled.compactMap(\.speaker)).sorted())")
            return (labeled, embeddings)
        } catch {
            logger.error("Diarization failed: \(error.localizedDescription)")
            errorMessage = "Diarization failed: \(error.localizedDescription)"
            return (annotated.map {
                var segment = $0
                segment.speaker = nil
                segment.speakerID = nil
                segment.speakerConfidence = nil
                return segment
            }, [])
        }
    }

    /// Both audio sources feed one total speaker budget. Failures propagate so
    /// callers retain the saved transcript and can explain why no change occurred.
    func rediarize(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float]?,
        numSpeakers: Int,
        sampleRate: Double = 16000,
        detectedLanguage: String? = nil
    ) async throws -> (segments: [TranscriptSegment], speakerEmbeddings: [SpeakerEmbedding]) {
        guard numSpeakers > 0 else { throw SpeakerAttributionError.invalidSpeakerCount }
        if numSpeakers == 1 {
            return (try Self.rediarizeFromEmbeddings(segments: segments, speakerEmbeddings: [], numSpeakers: 1), [])
        }
        let embeddings = try await extractEmbeddings(
            systemSamples: systemSamples, micSamples: micSamples ?? [],
            sampleRate: sampleRate, detectedLanguage: detectedLanguage
        )
        let annotated = DiarizationAudio.annotate(
            segments, system: systemSamples, microphone: micSamples ?? [], sampleRate: sampleRate
        )
        let labeled = try await Task.detached(priority: .userInitiated) {
            try Self.rediarizeFromEmbeddings(
                segments: annotated, speakerEmbeddings: embeddings, numSpeakers: numSpeakers
            )
        }.value
        return (labeled, embeddings)
    }

    nonisolated static func rediarizeFromEmbeddings(
        segments: [TranscriptSegment],
        speakerEmbeddings: [SpeakerEmbedding],
        numSpeakers: Int
    ) throws -> [TranscriptSegment] {
        try SpeakerAttribution.recluster(
            segments: segments, embeddings: speakerEmbeddings, totalSpeakers: numSpeakers
        )
    }

    private func extractEmbeddings(
        systemSamples: [Float], micSamples: [Float], sampleRate: Double, detectedLanguage: String?
    ) async throws -> [SpeakerEmbedding] {
        let tracks: [(SpeakerAudioSource, [Float])] = [(.system, systemSamples), (.microphone, micSamples)]
        let activeTracks = tracks.filter { _, samples in
            // A brief turn in a long meeting must not disappear into the RMS of
            // the entire recording. The model's VAD will reject non-speech.
            sampleRate.isFinite && sampleRate > 0
                && samples.contains { $0.isFinite && abs($0) > DiarizationAudio.silenceFloor }
        }
        guard !activeTracks.isEmpty else { throw SpeakerAttributionError.noSpeech }
        if embeddingProvider == nil {
            await prepareModels()
            guard isModelReady else {
                throw DiarizerCacheError(message: errorMessage ?? "Speaker models are unavailable.")
            }
        }

        var embeddings: [SpeakerEmbedding] = []
        for (source, samples) in activeTracks {
            try Task.checkCancellation()
            let track: [SpeakerEmbedding]
            if let embeddingProvider {
                track = try await embeddingProvider(source, samples)
            } else {
                let result = try await diarizer.process(audio: samples)
                var speakerSegments = result.segments
                if Self.isCJKLanguage(detectedLanguage) {
                    let count = max(Set(speakerSegments.map(\.speakerId)).count, 2)
                    speakerSegments = Self.reclusterForChinese(speakerSegments: speakerSegments, k: count)
                }
                let count = validateSpeakerSplit(speakerSegments)
                track = speakerSegments.map {
                    SpeakerEmbedding(
                        speakerId: count <= 1 ? "0" : $0.speakerId, embedding: $0.embedding,
                        startTime: $0.startTimeSeconds, endTime: $0.endTimeSeconds, qualityScore: $0.qualityScore
                    )
                }
            }
            for embedding in track {
                // Prefer the clean system track when the microphone mostly hears
                // loudspeaker output. This does not identify anyone as You.
                if source == .microphone && DiarizationAudio.preferredSource(
                    start: Double(embedding.startTime), end: Double(embedding.endTime),
                    system: systemSamples, microphone: micSamples, sampleRate: sampleRate
                ) != .microphone { continue }
                embeddings.append(SpeakerEmbedding(
                    speakerId: "\(source.rawValue)-\(embedding.speakerId)", embedding: embedding.embedding,
                    startTime: embedding.startTime, endTime: embedding.endTime,
                    qualityScore: embedding.qualityScore, source: source
                ))
            }
        }
        guard !embeddings.isEmpty else { throw SpeakerAttributionError.noSpeech }
        try SpeakerAttribution.validate(embeddings)
        return embeddings
    }

    /// Validate whether a multi-speaker K-Means split is genuine.
    /// Rejects splits where the minority speaker has < 10% of total speaking time
    /// (e.g., Podcast A's 9/384 = 2.3% was a fake split).
    private func validateSpeakerSplit(_ segments: [TimedSpeakerSegment]) -> Int {
        var speakerDurations: [String: Double] = [:]
        for seg in segments {
            speakerDurations[seg.speakerId, default: 0] += Double(seg.durationSeconds)
        }

        guard speakerDurations.count >= 2 else { return speakerDurations.count }

        let totalDuration = speakerDurations.values.reduce(0, +)
        let sorted = speakerDurations.sorted { $0.value > $1.value }
        let minorityDuration = sorted.last!.value
        let minorityRatio = totalDuration > 0 ? minorityDuration / totalDuration : 0

        logger.info("""
        ┌─ SPLIT VALIDATION ────────────────────────────
        │ Speakers: \(sorted.map { "\($0.key): \(String(format: "%.1f", $0.value))s" }.joined(separator: ", "))
        │ Minority ratio: \(String(format: "%.1f", minorityRatio * 100))%
        │ Verdict: \(minorityRatio >= 0.10 ? "GENUINE split" : "FAKE split → collapsing to 1 speaker")
        └──────────────────────────────────────────────────
        """)

        return minorityRatio >= 0.10 ? speakerDurations.count : 1
    }

    // MARK: - Language-Aware Re-clustering

    /// Check if the detected language is Chinese (where PLDA underperforms).
    nonisolated static func isCJKLanguage(_ language: String?) -> Bool {
        guard let lang = language?.lowercased() else { return false }
        return lang.hasPrefix("zh") || lang == "yue"
    }

    /// Re-cluster FluidAudio segments on raw 256D embeddings using K-Means cosine.
    /// Bypasses PLDA-based cluster assignments that fail for Chinese speakers.
    private static func reclusterForChinese(
        speakerSegments: [TimedSpeakerSegment],
        k: Int = 2
    ) -> [TimedSpeakerSegment] {
        guard speakerSegments.count >= k else { return speakerSegments }

        let embeddings = speakerSegments.map(\.embedding)
        let assignments = SpeakerClusterer.kMeansCosine(embeddings: embeddings, k: k)

        // Compute cluster durations to detect phantom clusters
        var clusterDurations: [Int: Float] = [:]
        for (i, a) in assignments.enumerated() {
            clusterDurations[a, default: 0] += speakerSegments[i].endTimeSeconds - speakerSegments[i].startTimeSeconds
        }
        let totalDuration = clusterDurations.values.reduce(Float(0), +)

        // Drop clusters with <5% of total time — merge into nearest valid cluster
        let validClusters = Set(clusterDurations.filter { totalDuration > 0 && $0.value / totalDuration >= 0.05 }.map(\.key))
        let droppedClusters = Set(clusterDurations.keys).subtracting(validClusters)

        if !droppedClusters.isEmpty {
            let droppedInfo = droppedClusters.sorted().map { c in
                "speaker_\(c): \(String(format: "%.1f", (clusterDurations[c] ?? 0) / totalDuration * 100))%"
            }.joined(separator: ", ")
            logger.info("Chinese re-cluster: dropping phantom clusters [\(droppedInfo)]")
        }

        // Build centroids for valid clusters to find nearest for merging
        let normed = embeddings.map { SpeakerClusterer.l2Normalize($0) }
        var centroids: [Int: [Float]] = [:]
        var centroidCounts: [Int: Int] = [:]
        for (i, a) in assignments.enumerated() where validClusters.contains(a) {
            if centroids[a] == nil {
                centroids[a] = [Float](repeating: 0, count: normed[i].count)
            }
            for d in 0..<normed[i].count { centroids[a]![d] += normed[i][d] }
            centroidCounts[a, default: 0] += 1
        }
        for c in centroids.keys {
            centroids[c] = SpeakerClusterer.l2Normalize(centroids[c]!)
        }

        // Assign final speaker IDs, merging dropped clusters into nearest valid one
        let validSorted = validClusters.sorted()
        let validIndexMap = Dictionary(uniqueKeysWithValues: validSorted.enumerated().map { ($1, $0) })

        let result = speakerSegments.enumerated().map { i, seg in
            var clusterId = assignments[i]
            if !validClusters.contains(clusterId) {
                // Find nearest valid cluster by cosine similarity
                var bestCluster = validSorted.first ?? 0
                var bestSim: Float = -2
                for vc in validSorted {
                    guard let cent = centroids[vc] else { continue }
                    let sim = zip(normed[i], cent).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    if sim > bestSim { bestSim = sim; bestCluster = vc }
                }
                clusterId = bestCluster
            }
            return TimedSpeakerSegment(
                speakerId: "speaker_\(validIndexMap[clusterId] ?? 0)",
                embedding: seg.embedding,
                startTimeSeconds: seg.startTimeSeconds,
                endTimeSeconds: seg.endTimeSeconds,
                qualityScore: seg.qualityScore
            )
        }

        let finalCounts = Dictionary(grouping: result.map(\.speakerId), by: { $0 }).mapValues(\.count)
        logger.info("Chinese re-cluster: \(finalCounts.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value) segments" }.joined(separator: ", "))")

        return result
    }
}
