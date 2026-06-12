import Foundation
@preconcurrency import WhisperKit

struct SpeakerSegment: Sendable {
    let startTime: Double
    let endTime: Double
    let speakerLabel: String
}

@MainActor
final class DiarizationEngine: ObservableObject {
    @Published var isDiarizing = false
    @Published var errorMessage: String?

    /// Window duration in seconds for speaker analysis.
    nonisolated static let windowDuration: Double = 3.0
    /// Hop between windows (50% overlap).
    nonisolated static let windowHop: Double = 1.5
    /// Minimum window energy to consider voiced (RMS threshold).
    /// Normal speech RMS is ~0.03-0.3; this filters out noise/breath.
    nonisolated static let voiceEnergyThreshold: Float = 0.02

    /// Apply speaker labels to transcript segments using windowed MFCC+pitch embeddings
    /// and batch agglomerative clustering. Heavy computation runs on a background thread.
    func diarize(
        segments: [TranscriptSegment],
        audioSamples: [Float],
        sampleRate: Double = 16000
    ) async -> [TranscriptSegment] {
        isDiarizing = true
        defer { isDiarizing = false }

        guard !segments.isEmpty, !audioSamples.isEmpty else { return segments }

        // Offload all heavy computation to a background thread
        let result = await Task.detached(priority: .userInitiated) {
            Self.diarizeOffMain(
                segments: segments,
                audioSamples: audioSamples,
                sampleRate: sampleRate
            )
        }.value

        return result
    }

    /// Overload that accepts channel-separated audio for mic/system separation.
    /// When mic samples are provided, mic-dominant segments are labeled "You".
    func diarize(
        segments: [TranscriptSegment],
        systemSamples: [Float],
        micSamples: [Float]?,
        sampleRate: Double = 16000
    ) async -> [TranscriptSegment] {
        // First, run windowed diarization on system audio
        var result = await diarize(
            segments: segments,
            audioSamples: systemSamples,
            sampleRate: sampleRate
        )

        // If mic samples provided, identify mic-dominant segments as "You"
        guard let micSamples, !micSamples.isEmpty else { return result }

        for i in 0..<result.count {
            let startSample = Int(result[i].startTime * sampleRate)
            let endSample = min(Int(result[i].endTime * sampleRate), systemSamples.count)
            let micEnd = min(endSample, micSamples.count)

            guard startSample < endSample, startSample < micEnd else { continue }

            let sysSlice = Array(systemSamples[startSample..<endSample])
            let micSlice = Array(micSamples[startSample..<micEnd])

            let sysEnergy = rmsEnergy(sysSlice)
            let micEnergy = rmsEnergy(micSlice)

            // If mic energy is significantly stronger, this is the local user
            if sysEnergy > 0 && micEnergy > 0 && micEnergy / sysEnergy > 2.0 {
                result[i].speaker = "You"
                result[i].speakerConfidence = Double(min(micEnergy / sysEnergy / 5.0, 1.0))
            }
        }

        return result
    }

    // MARK: - Background Processing (nonisolated)

    /// Pure computation — runs entirely off the main actor.
    /// Takes segments + audio, returns diarized segments.
    nonisolated static func diarizeOffMain(
        segments: [TranscriptSegment],
        audioSamples: [Float],
        sampleRate: Double
    ) -> [TranscriptSegment] {
        // Step 1: Extract windowed embeddings
        let windowedResults = extractWindowedEmbeddings(
            from: audioSamples,
            sampleRate: sampleRate
        )

        guard !windowedResults.isEmpty else {
            return segments.map { seg in
                var s = seg
                s.speaker = "Speaker 1"
                s.speakerConfidence = 0.1
                return s
            }
        }

        // Step 2: Batch cluster all windows
        let embeddings = windowedResults.map(\.embedding)
        let clusterLabels = SpeakerClusterer.clusterBatch(
            embeddings: embeddings,
            maxSpeakers: 6,
            distanceThreshold: 0.35
        )

        // Build time-labeled windows with cluster assignments
        let labeledWindows: [(startTime: Double, endTime: Double, speaker: Int)] =
            zip(windowedResults, clusterLabels).map { (window, label) in
                (startTime: window.startTime, endTime: window.endTime, speaker: label)
            }

        // Step 3: Assign speaker labels to segments
        var result: [TranscriptSegment] = []
        for segment in segments {
            let segmentDuration = segment.endTime - segment.startTime

            if segmentDuration < 0.5 {
                let speaker = nearestWindowSpeaker(
                    for: segment,
                    windows: labeledWindows
                )
                var s = segment
                s.speaker = "Speaker \(speaker + 1)"
                s.speakerConfidence = 0.3
                result.append(s)
                continue
            }

            let overlapping = labeledWindows.filter { window in
                window.startTime < segment.endTime && window.endTime > segment.startTime
            }

            if overlapping.isEmpty {
                var s = segment
                s.speaker = "Speaker 1"
                s.speakerConfidence = 0.1
                result.append(s)
                continue
            }

            let speakers = Set(overlapping.map(\.speaker))

            if speakers.count == 1 {
                let speaker = overlapping[0].speaker
                var s = segment
                s.speaker = "Speaker \(speaker + 1)"
                s.speakerConfidence = confidence(for: overlapping)
                result.append(s)
            } else {
                let splitSegments = splitAtSpeakerBoundary(
                    segment: segment,
                    overlappingWindows: overlapping
                )
                result.append(contentsOf: splitSegments)
            }
        }

        // Step 4: Smooth short speaker-label flips
        result = smoothSpeakerLabels(result)

        return result
    }

    // MARK: - Windowed Embedding Extraction

    struct WindowEmbedding: Sendable {
        let startTime: Double
        let endTime: Double
        let embedding: [Float]
    }

    /// Split audio into fixed windows and extract embeddings from voiced windows.
    /// Uses range-based extraction to avoid copying 24k+ floats per window.
    nonisolated static func extractWindowedEmbeddings(
        from samples: [Float],
        sampleRate: Double
    ) -> [WindowEmbedding] {
        let windowSamples = Int(windowDuration * sampleRate)
        let hopSamples = Int(windowHop * sampleRate)

        guard samples.count >= windowSamples else {
            if let embedding = MFCCExtractor.extract(from: samples, sampleRate: sampleRate) {
                return [WindowEmbedding(
                    startTime: 0,
                    endTime: Double(samples.count) / sampleRate,
                    embedding: embedding
                )]
            }
            return []
        }

        return samples.withUnsafeBufferPointer { buffer in
            var results: [WindowEmbedding] = []
            var offset = 0

            while offset + windowSamples <= samples.count {
                let range = offset..<(offset + windowSamples)
                let startTime = Double(offset) / sampleRate
                let endTime = Double(offset + windowSamples) / sampleRate

                let energy = MFCCExtractor.rmsEnergyRange(buffer, range: range)
                if energy >= voiceEnergyThreshold {
                    if let embedding = MFCCExtractor.extract(from: buffer, range: range, sampleRate: sampleRate) {
                        results.append(WindowEmbedding(
                            startTime: startTime,
                            endTime: endTime,
                            embedding: embedding
                        ))
                    }
                }

                offset += hopSamples
            }

            // Handle remaining audio if it's at least half a window
            let remaining = samples.count - offset
            if remaining >= windowSamples / 2 {
                let range = offset..<samples.count
                let startTime = Double(offset) / sampleRate
                let endTime = Double(samples.count) / sampleRate
                let energy = MFCCExtractor.rmsEnergyRange(buffer, range: range)
                if energy >= voiceEnergyThreshold {
                    if let embedding = MFCCExtractor.extract(from: buffer, range: range, sampleRate: sampleRate) {
                        results.append(WindowEmbedding(
                            startTime: startTime,
                            endTime: endTime,
                            embedding: embedding
                        ))
                    }
                }
            }

            return results
        }
    }

    // MARK: - Speaker Assignment (static helpers)

    private nonisolated static func nearestWindowSpeaker(
        for segment: TranscriptSegment,
        windows: [(startTime: Double, endTime: Double, speaker: Int)]
    ) -> Int {
        let segMid = (segment.startTime + segment.endTime) / 2.0
        var bestDist = Double.greatestFiniteMagnitude
        var bestSpeaker = 0

        for window in windows {
            let winMid = (window.startTime + window.endTime) / 2.0
            let dist = abs(winMid - segMid)
            if dist < bestDist {
                bestDist = dist
                bestSpeaker = window.speaker
            }
        }

        return bestSpeaker
    }

    private nonisolated static func confidence(
        for overlapping: [(startTime: Double, endTime: Double, speaker: Int)]
    ) -> Double {
        guard !overlapping.isEmpty else { return 0.1 }

        var speakerCounts: [Int: Int] = [:]
        for w in overlapping {
            speakerCounts[w.speaker, default: 0] += 1
        }
        let maxCount = speakerCounts.values.max() ?? 0
        return Double(maxCount) / Double(overlapping.count)
    }

    // MARK: - Segment Splitting

    private nonisolated static func splitAtSpeakerBoundary(
        segment: TranscriptSegment,
        overlappingWindows: [(startTime: Double, endTime: Double, speaker: Int)]
    ) -> [TranscriptSegment] {
        let sorted = overlappingWindows.sorted { $0.startTime < $1.startTime }

        var runs: [(speaker: Int, startTime: Double, endTime: Double)] = []
        var currentSpeaker = sorted[0].speaker
        var runStart = max(sorted[0].startTime, segment.startTime)

        for i in 1..<sorted.count {
            if sorted[i].speaker != currentSpeaker {
                let runEnd = (sorted[i - 1].endTime + sorted[i].startTime) / 2.0
                runs.append((speaker: currentSpeaker, startTime: runStart, endTime: min(runEnd, segment.endTime)))
                currentSpeaker = sorted[i].speaker
                runStart = max(runEnd, segment.startTime)
            }
        }
        runs.append((speaker: currentSpeaker, startTime: runStart, endTime: segment.endTime))

        if runs.count <= 1 {
            var speakerCounts: [Int: Int] = [:]
            for w in overlappingWindows {
                speakerCounts[w.speaker, default: 0] += 1
            }
            let majority = speakerCounts.max(by: { $0.value < $1.value })!.key
            var s = segment
            s.speaker = "Speaker \(majority + 1)"
            s.speakerConfidence = Double(speakerCounts[majority]!) / Double(overlappingWindows.count)
            return [s]
        }

        let totalDuration = segment.endTime - segment.startTime
        let words = segment.text.split(separator: " ")
        var result: [TranscriptSegment] = []
        var wordOffset = 0

        for (index, run) in runs.enumerated() {
            let runDuration = run.endTime - run.startTime
            let wordCount: Int
            if index == runs.count - 1 {
                wordCount = words.count - wordOffset
            } else {
                wordCount = max(1, Int(round(Double(words.count) * runDuration / totalDuration)))
            }

            let endWordIdx = min(wordOffset + wordCount, words.count)
            let text = words[wordOffset..<endWordIdx].joined(separator: " ")

            if !text.isEmpty {
                var seg = TranscriptSegment(
                    startTime: run.startTime,
                    endTime: run.endTime,
                    text: text
                )
                seg.speaker = "Speaker \(run.speaker + 1)"
                seg.speakerConfidence = 0.6
                result.append(seg)
            }

            wordOffset = endWordIdx
        }

        if result.isEmpty {
            var speakerCounts: [Int: Int] = [:]
            for w in overlappingWindows {
                speakerCounts[w.speaker, default: 0] += 1
            }
            let majority = speakerCounts.max(by: { $0.value < $1.value })!.key
            var s = segment
            s.speaker = "Speaker \(majority + 1)"
            s.speakerConfidence = 0.5
            return [s]
        }

        return result
    }

    // MARK: - Smoothing

    private nonisolated static func smoothSpeakerLabels(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.count >= 3 else { return segments }

        var smoothed = segments
        for i in 1..<(segments.count - 1) {
            let duration = segments[i].endTime - segments[i].startTime
            if duration < 1.0 {
                let prevSpeaker = smoothed[i - 1].speaker
                let nextSpeaker = segments[i + 1].speaker
                if prevSpeaker == nextSpeaker && segments[i].speaker != prevSpeaker {
                    smoothed[i].speaker = prevSpeaker
                    smoothed[i].speakerConfidence = 0.4
                }
            }
        }
        return smoothed
    }

    // MARK: - Utilities

    private func rmsEnergy(_ samples: [Float]) -> Float {
        Self.rmsEnergyStatic(samples)
    }

    private nonisolated static func rmsEnergyStatic(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
