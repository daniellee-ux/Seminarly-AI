import Foundation
import FluidAudio
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "NeuralDiarization")

@MainActor
final class NeuralDiarizationEngine: ObservableObject {
    @Published var isDiarizing = false
    @Published var isModelReady = false
    @Published var modelStatus = ""
    @Published var errorMessage: String?

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

    /// Download and prepare neural diarization models (runs once, cached).
    func prepareModels() async {
        guard !isModelReady else {
            logger.info("Models already ready, skipping preparation")
            return
        }
        modelStatus = "Downloading speaker diarization models..."
        logger.info("Starting model preparation...")
        do {
            try await diarizer.prepareModels()
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

    /// Apply neural speaker labels to transcript segments.
    /// Returns labeled segments AND speaker embeddings for lightweight re-clustering later.
    /// When `detectedLanguage` indicates Chinese, bypasses FluidAudio's PLDA-based clustering
    /// and re-clusters on raw 256D embeddings (PLDA destroys Chinese speaker features).
    func diarize(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float]?,
        sampleRate: Double = 16000,
        detectedLanguage: String? = nil
    ) async -> (segments: [TranscriptSegment], speakerEmbeddings: [SpeakerEmbedding]) {
        isDiarizing = true
        defer { isDiarizing = false }

        let audioDuration = Double(systemSamples.count) / sampleRate
        logger.info("""
        ┌─ DIARIZATION INPUT ─────────────────────────
        │ Transcript segments: \(segments.count)
        │ System samples: \(systemSamples.count) (\(String(format: "%.1f", audioDuration))s at \(Int(sampleRate))Hz)
        │ Mic samples: \(micSamples?.count ?? 0) (\(micSamples == nil ? "nil" : "present"))
        │ Model ready: \(self.isModelReady)
        └──────────────────────────────────────────────
        """)

        guard !segments.isEmpty, !systemSamples.isEmpty else {
            logger.warning("Empty segments or samples — returning unlabeled segments")
            return (segments, [])
        }

        // Diarize on system audio only — mic echo through speakers would create
        // phantom speaker clusters since FluidAudio sees the remote voice twice
        // (clean system tap + attenuated mic echo).
        let allSamples = systemSamples
        logger.info("Using system audio only for diarization: \(allSamples.count) samples")

        // Log diarization config
        logger.info("""
        ┌─ DIARIZATION CONFIG ───────────────────────────
        │ clustering.threshold: 0.70 (pyannote ~0.7135, higher = stricter merging = more clusters)
        │ clustering.warmStartFa: 0.07 (pyannote default)
        │ segmentation.stepRatio: 0.15 (default 0.2)
        │ embedding.minSegmentDuration: 0.3s (default 1.0)
        │ postProcessing.minGapDuration: 0.05s (default 0.1)
        │ clustering.minSpeakers: 2 (K-Means fallback if AHC+VBx collapse)
        │ Audio normalization: OFF (let embedding model handle internally)
        └──────────────────────────────────────────────────
        """)

        do {
            logger.info("Calling FluidAudio diarizer.process(audio:)... detectedLanguage=\(detectedLanguage ?? "nil")")
            let result = try await diarizer.process(audio: allSamples)
            var speakerSegments = result.segments

            // For Chinese audio, re-cluster on raw 256D embeddings (bypasses PLDA).
            // FluidAudio's PLDA was trained on English (VoxCeleb) and destroys
            // speaker-discriminative dimensions for Chinese speakers.
            if Self.isCJKLanguage(detectedLanguage) {
                let pldaSegments = speakerSegments
                let pldaCounts = Dictionary(grouping: pldaSegments.map(\.speakerId), by: { $0 }).mapValues(\.count)
                let pldaSummary = pldaCounts.sorted(by: { $0.value > $1.value }).map { "\($0.key): \($0.value)" }.joined(separator: ", ")

                // Compute PLDA split validation (what would happen without our fix)
                let pldaSpeakerTimes = Dictionary(grouping: pldaSegments, by: { $0.speakerId })
                    .mapValues { segs in segs.reduce(0.0) { $0 + ($1.endTimeSeconds - $1.startTimeSeconds) } }
                let pldaTotalTime = pldaSpeakerTimes.values.reduce(0.0, +)
                let pldaMinorityTime = pldaSpeakerTimes.values.min() ?? 0
                let pldaMinorityRatio = pldaTotalTime > 0 ? pldaMinorityTime / pldaTotalTime * 100.0 : 0

                let pldaSpeakerCount = max(pldaCounts.count, 2)
                logger.info("Chinese detected (\(detectedLanguage ?? "")) — re-clustering on raw 256D embeddings (bypassing PLDA, k=\(pldaSpeakerCount) from PLDA).")
                speakerSegments = Self.reclusterForChinese(speakerSegments: speakerSegments, k: pldaSpeakerCount)

                let rawCounts = Dictionary(grouping: speakerSegments.map(\.speakerId), by: { $0 }).mapValues(\.count)
                let rawSummary = rawCounts.sorted(by: { $0.value > $1.value }).map { "\($0.key): \($0.value)" }.joined(separator: ", ")

                // Compute raw 256D split validation
                let rawSpeakerTimes = Dictionary(grouping: speakerSegments, by: { $0.speakerId })
                    .mapValues { segs in segs.reduce(0.0) { $0 + ($1.endTimeSeconds - $1.startTimeSeconds) } }
                let rawTotalTime = rawSpeakerTimes.values.reduce(0.0, +)
                let rawMinorityTime = rawSpeakerTimes.values.min() ?? 0
                let rawMinorityRatio = rawTotalTime > 0 ? rawMinorityTime / rawTotalTime * 100.0 : 0

                // Build best PLDA→Raw speaker mapping using majority overlap
                let pldaToRaw = Self.buildSpeakerMapping(from: pldaSegments, to: speakerSegments)
                let mappingDesc = pldaToRaw.sorted(by: { $0.key < $1.key }).map { "\($0.key)→\($0.value)" }.joined(separator: ", ")

                // Count segments that changed cluster (not just ID) using the mapping
                let reassigned = zip(pldaSegments, speakerSegments).filter { plda, raw in
                    pldaToRaw[plda.speakerId] != raw.speakerId
                }.count
                let reassignedPct = speakerSegments.isEmpty ? 0.0 : Double(reassigned) / Double(speakerSegments.count) * 100.0

                // Count PLDA speakers that merged (multiple PLDA IDs → same raw ID)
                let rawTargets = Set(pldaToRaw.values)
                let mergedCount = pldaCounts.count - rawTargets.count

                logger.info("""
                ┌─ CHINESE RE-CLUSTER COMPARISON ──────────────────────────────────
                │ PLDA result:    \(pldaCounts.count) speakers [\(pldaSummary)]
                │ PLDA minority:  \(String(format: "%.1f", pldaMinorityRatio))% (\(String(format: "%.1f", pldaMinorityTime))s / \(String(format: "%.1f", pldaTotalTime))s)
                │ Raw 256D:       \(rawCounts.count) speakers [\(rawSummary)]
                │ Raw minority:   \(String(format: "%.1f", rawMinorityRatio))% (\(String(format: "%.1f", rawMinorityTime))s / \(String(format: "%.1f", rawTotalTime))s)
                │ Mapping:        [\(mappingDesc)]
                │ Speakers merged: \(mergedCount) (\(pldaCounts.count)→\(rawCounts.count))
                │ Segments reassigned: \(reassigned)/\(speakerSegments.count) (\(String(format: "%.1f", reassignedPct))%)
                └──────────────────────────────────────────────────────────────────
                """)

                // Log sample of genuinely reassigned segments (changed cluster, not just ID)
                let changed = zip(pldaSegments, speakerSegments)
                    .filter { plda, raw in pldaToRaw[plda.speakerId] != raw.speakerId }
                    .prefix(10)
                if !changed.isEmpty {
                    logger.info("  Sample reassigned segments (PLDA → Raw 256D):")
                    for (plda, raw) in changed {
                        logger.info("    \(String(format: "%.1f", plda.startTimeSeconds))-\(String(format: "%.1f", plda.endTimeSeconds))s: \(plda.speakerId) → \(raw.speakerId) (was mapped to \(pldaToRaw[plda.speakerId] ?? "?"))")
                    }
                }
            }

            // Convert FluidAudio segments to persistable SpeakerEmbeddings
            let speakerEmbeddings = speakerSegments.map { seg in
                SpeakerEmbedding(
                    speakerId: seg.speakerId,
                    embedding: seg.embedding,
                    startTime: seg.startTimeSeconds,
                    endTime: seg.endTimeSeconds,
                    qualityScore: seg.qualityScore
                )
            }

            // Log FluidAudio's raw output
            let uniqueSpeakers = Set(speakerSegments.map(\.speakerId))
            logger.info("""
            ┌─ FLUIDAUDIO RAW OUTPUT ─────────────────────
            │ Speaker segments returned: \(speakerSegments.count)
            │ Unique speakers found: \(uniqueSpeakers.count) → \(uniqueSpeakers.sorted())
            └──────────────────────────────────────────────
            """)

            if let timings = result.timings {
                logger.info("""
                ┌─ PIPELINE TIMINGS ─────────────────────────────
                │ Segmentation: \(String(format: "%.2f", timings.segmentationSeconds))s
                │ Embedding: \(String(format: "%.2f", timings.embeddingExtractionSeconds))s
                │ Clustering: \(String(format: "%.2f", timings.speakerClusteringSeconds))s
                │ Post-processing: \(String(format: "%.2f", timings.postProcessingSeconds))s
                │ Total: \(String(format: "%.2f", timings.totalProcessingSeconds))s
                └──────────────────────────────────────────────────
                """)
            }

            for (i, seg) in speakerSegments.prefix(20).enumerated() {
                logger.info("  FluidAudio[\(i)]: speaker=\(seg.speakerId) time=\(String(format: "%.2f", seg.startTimeSeconds))-\(String(format: "%.2f", seg.endTimeSeconds))s quality=\(String(format: "%.3f", seg.qualityScore))")
            }
            if speakerSegments.count > 20 {
                logger.info("  ... (\(speakerSegments.count - 20) more segments)")
            }

            // Validate forced K-Means split: reject if minority speaker < 10% of total time
            let effectiveSpeakerCount = validateSpeakerSplit(speakerSegments)

            var labeled: [TranscriptSegment]
            if effectiveSpeakerCount <= 1 {
                // Fake split — collapse to single speaker
                labeled = segments.map { seg in
                    var s = seg
                    s.speaker = "Speaker 1"
                    s.speakerConfidence = 0.9
                    return s
                }
            } else {
                labeled = assignSpeakers(
                    transcriptSegments: segments,
                    speakerSegments: speakerSegments
                )
            }

            // If mic available, override mic-dominant segments as "You"
            if let micSamples, !micSamples.isEmpty {
                labeled = labelMicSpeaker(
                    segments: labeled,
                    systemSamples: systemSamples,
                    micSamples: micSamples,
                    sampleRate: sampleRate
                )
            }

            // Log final assigned labels
            let assignedSpeakers = Set(labeled.compactMap(\.speaker))
            logger.info("""
            ┌─ FINAL DIARIZATION RESULT ───────────────────
            │ Output segments: \(labeled.count)
            │ Speakers assigned: \(assignedSpeakers.sorted())
            └──────────────────────────────────────────────
            """)
            for (i, seg) in labeled.prefix(10).enumerated() {
                logger.info("  Final[\(i)]: speaker=\(seg.speaker ?? "nil") conf=\(String(format: "%.2f", seg.speakerConfidence ?? 0)) text=\"\(String(seg.text.prefix(50)))\"")
            }

            return (labeled, speakerEmbeddings)
        } catch {
            logger.error("FluidAudio diarization FAILED: \(error)")
            errorMessage = "Diarization failed: \(error.localizedDescription)"
            return (segments.map { seg in
                var s = seg
                s.speaker = "Speaker 1"
                s.speakerConfidence = 0.1
                return s
            }, [])
        }
    }

    /// Re-run diarization with a specific speaker count (for post-recording adjustment).
    func rediarize(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float]?,
        numSpeakers: Int,
        sampleRate: Double = 16000
    ) async -> [TranscriptSegment] {
        logger.info("Re-diarizing with numSpeakers=\(numSpeakers)")

        // Create a one-shot diarizer with forced speaker count
        var config = OfflineDiarizerConfig()
        config.clustering.threshold = 0.70
        config.embedding.minSegmentDurationSeconds = 0.3
        config.postProcessing.minGapDurationSeconds = 0.05
        config.clustering.warmStartFa = 0.07
        config.segmentation.stepRatio = 0.15
        config.clustering.numSpeakers = numSpeakers
        let tempDiarizer = OfflineDiarizerManager(config: config)

        do {
            try await tempDiarizer.prepareModels()
            // Diarize on system audio only (same as diarize()) — avoids mic echo phantom clusters
            let allSamples = systemSamples

            let result = try await tempDiarizer.process(audio: allSamples)
            var labeled = assignSpeakers(
                transcriptSegments: segments,
                speakerSegments: result.segments
            )

            if let micSamples, !micSamples.isEmpty {
                labeled = labelMicSpeaker(
                    segments: labeled,
                    systemSamples: systemSamples,
                    micSamples: micSamples,
                    sampleRate: sampleRate
                )
            }
            return labeled
        } catch {
            logger.error("Re-diarization failed: \(error)")
            return segments
        }
    }

    // MARK: - Embedding-Based Re-clustering

    /// Lightweight re-clustering using saved speaker embeddings (no FluidAudio models needed).
    /// K-means cosine on 256-dim WeSpeaker embeddings + time-overlap speaker assignment.
    /// Preserves "You" labels from the original transcript segments.
    nonisolated static func rediarizeFromEmbeddings(
        segments: [TranscriptSegment],
        speakerEmbeddings: [SpeakerEmbedding],
        numSpeakers: Int
    ) -> [TranscriptSegment] {
        let log = Logger(subsystem: "ai.seminarly.Seminarly", category: "EmbeddingRecluster")
        guard !speakerEmbeddings.isEmpty else {
            log.warning("No speaker embeddings — returning segments unchanged")
            return segments
        }

        // Log embedding diagnostics
        let qualities = speakerEmbeddings.map(\.qualityScore)
        let avgQuality = qualities.reduce(Float(0), +) / Float(qualities.count)
        let minQuality = qualities.min() ?? 0
        let lowQualityCount = qualities.filter { $0 < 0.3 }.count
        let originalSpeakers = Set(speakerEmbeddings.map(\.speakerId))
        log.info("""
        ┌─ EMBEDDING RE-CLUSTER INPUT ──────────────────
        │ Embeddings: \(speakerEmbeddings.count)
        │ Transcript segments: \(segments.count)
        │ Requested speakers: \(numSpeakers)
        │ Original speakers: \(originalSpeakers.count) → \(originalSpeakers.sorted())
        │ Quality: avg=\(String(format: "%.3f", avgQuality)) min=\(String(format: "%.3f", minQuality)) low(<0.3)=\(lowQualityCount)
        │ Time span: \(String(format: "%.1f", speakerEmbeddings.first.map { Double($0.startTime) } ?? 0))s – \(String(format: "%.1f", speakerEmbeddings.last.map { Double($0.endTime) } ?? 0))s
        └───────────────────────────────────────────────
        """)

        let embeddings = speakerEmbeddings.map(\.embedding)
        let assignments = SpeakerClusterer.kMeansCosine(
            embeddings: embeddings,
            k: numSpeakers
        )

        // Log cluster sizes
        var clusterSizes: [Int: Int] = [:]
        for a in assignments { clusterSizes[a, default: 0] += 1 }
        log.info("Cluster sizes: \(clusterSizes.sorted(by: { $0.key < $1.key }).map { "Speaker \($0.key + 1): \($0.value) embeddings" }.joined(separator: ", "))")

        var noOverlapCount = 0
        var youPreservedCount = 0

        let result = segments.map { segment in
            var s = segment

            // Find overlapping speaker embeddings, weighted by time overlap
            var speakerWeights: [Int: Double] = [:]
            for (i, emb) in speakerEmbeddings.enumerated() {
                let overlapStart = max(segment.startTime, Double(emb.startTime))
                let overlapEnd = min(segment.endTime, Double(emb.endTime))
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > 0 {
                    speakerWeights[assignments[i], default: 0] += overlap
                }
            }

            if let best = speakerWeights.max(by: { $0.value < $1.value }) {
                let total = speakerWeights.values.reduce(0, +)
                s.speaker = "Speaker \(best.key + 1)"
                s.speakerConfidence = total > 0 ? best.value / total : 0.5
            } else {
                noOverlapCount += 1
                s.speaker = "Speaker 1"
                s.speakerConfidence = 0.1
            }

            // Preserve "You" labels — determined by mic energy, independent of clustering
            if segment.speaker == "You" {
                s.speaker = "You"
                youPreservedCount += 1
            }

            return s
        }

        let finalSpeakers = Set(result.compactMap(\.speaker))
        log.info("""
        ┌─ EMBEDDING RE-CLUSTER RESULT ─────────────────
        │ Output segments: \(result.count)
        │ Speakers assigned: \(finalSpeakers.sorted())
        │ No-overlap segments: \(noOverlapCount) (defaulted to Speaker 1)
        │ "You" labels preserved: \(youPreservedCount)
        └───────────────────────────────────────────────
        """)

        return result
    }

    // MARK: - Speaker Assignment

    /// Map FluidAudio's TimedSpeakerSegments onto TranscriptSegments using time overlap.
    private func assignSpeakers(
        transcriptSegments: [TranscriptSegment],
        speakerSegments: [TimedSpeakerSegment]
    ) -> [TranscriptSegment] {
        // Build a sorted speaker ID → consistent label mapping
        var speakerIds: [String] = []
        for seg in speakerSegments {
            if !speakerIds.contains(seg.speakerId) {
                speakerIds.append(seg.speakerId)
            }
        }
        logger.info("Speaker ID mapping: \(speakerIds.enumerated().map { "Speaker \($0.offset + 1) = \($0.element)" })")

        var noOverlapCount = 0

        let result = transcriptSegments.map { segment in
            var s = segment

            // Find all neural segments overlapping this transcript segment
            let overlapping = speakerSegments.filter { neural in
                Double(neural.startTimeSeconds) < segment.endTime &&
                Double(neural.endTimeSeconds) > segment.startTime
            }

            if overlapping.isEmpty {
                noOverlapCount += 1
                s.speaker = "Speaker 1"
                s.speakerConfidence = 0.1
                return s
            }

            // Weight by overlap duration
            var speakerWeights: [String: Double] = [:]
            for neural in overlapping {
                let overlapStart = max(segment.startTime, Double(neural.startTimeSeconds))
                let overlapEnd = min(segment.endTime, Double(neural.endTimeSeconds))
                let overlap = max(0, overlapEnd - overlapStart)
                speakerWeights[neural.speakerId, default: 0] += overlap
            }

            let bestSpeaker = speakerWeights.max(by: { $0.value < $1.value })!
            let totalOverlap = speakerWeights.values.reduce(0, +)
            let confidence = totalOverlap > 0 ? bestSpeaker.value / totalOverlap : 0.5

            let speakerIndex = (speakerIds.firstIndex(of: bestSpeaker.key) ?? 0) + 1
            s.speaker = "Speaker \(speakerIndex)"
            s.speakerConfidence = confidence

            return s
        }

        if noOverlapCount > 0 {
            logger.warning("⚠️ \(noOverlapCount)/\(transcriptSegments.count) transcript segments had NO overlapping FluidAudio segments (defaulted to Speaker 1)")
        }

        return result
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

    /// Label segments where mic energy dominates as "You".
    /// Echo resilience: speaker output picked up by mic is attenuated -10 to -30dB,
    /// giving a mic/sys energy ratio of ~0.1-0.5 — safely below the 2.0 threshold.
    /// Only direct speech into the mic (ratio >2.0) triggers the "You" label.
    private func labelMicSpeaker(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float],
        sampleRate: Double
    ) -> [TranscriptSegment] {
        var result = segments
        for i in 0..<result.count {
            let startSample = Int(result[i].startTime * sampleRate)
            let endSample = min(Int(result[i].endTime * sampleRate), systemSamples.count)
            let micEnd = min(endSample, micSamples.count)

            guard startSample < endSample, startSample < micEnd else { continue }

            let sysSlice = systemSamples[startSample..<endSample]
            let micSlice = micSamples[startSample..<micEnd]

            let sysEnergy = rmsEnergy(sysSlice)
            let micEnergy = rmsEnergy(micSlice)

            if sysEnergy > 0 && micEnergy > 0 && micEnergy / sysEnergy > 2.0 {
                result[i].speaker = "You"
                result[i].speakerConfidence = Double(min(micEnergy / sysEnergy / 5.0, 1.0))
            }
        }
        return result
    }

    /// Normalize audio samples to a target RMS level for consistent embedding extraction.
    private func normalizeAudio(_ samples: [Float], targetRMS: Float = 0.1) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let currentRMS = rmsEnergy(samples)
        // Don't amplify silence
        guard currentRMS > 0.001 else { return samples }
        let scale = targetRMS / currentRMS
        return samples.map { min(max($0 * scale, -1.0), 1.0) }
    }

    private func rmsEnergy<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    // MARK: - Language-Aware Re-clustering

    /// Check if the detected language is Chinese (where PLDA underperforms).
    nonisolated static func isCJKLanguage(_ language: String?) -> Bool {
        guard let lang = language?.lowercased() else { return false }
        return lang.hasPrefix("zh") || lang == "yue"
    }

    /// Build best-effort speaker ID mapping from PLDA to raw 256D using majority time overlap.
    /// Each PLDA speaker maps to the raw speaker that covers most of its time.
    private static func buildSpeakerMapping(
        from pldaSegments: [TimedSpeakerSegment],
        to rawSegments: [TimedSpeakerSegment]
    ) -> [String: String] {
        // For each PLDA speaker, accumulate time assigned to each raw speaker
        var pldaToRawTime: [String: [String: Float]] = [:]
        for (plda, raw) in zip(pldaSegments, rawSegments) {
            let duration = plda.endTimeSeconds - plda.startTimeSeconds
            pldaToRawTime[plda.speakerId, default: [:]][raw.speakerId, default: 0] += duration
        }
        // Map each PLDA speaker to the raw speaker with most overlapping time
        var mapping: [String: String] = [:]
        for (pldaId, rawTimes) in pldaToRawTime {
            if let best = rawTimes.max(by: { $0.value < $1.value }) {
                mapping[pldaId] = best.key
            }
        }
        return mapping
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
