import Foundation

enum SpeakerAttributionError: LocalizedError {
    case invalidSpeakerCount
    case missingEmbeddings
    case invalidEmbeddings
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .invalidSpeakerCount: "Choose at least one speaker."
        case .missingEmbeddings: "No saved voice data is available to identify speakers."
        case .invalidEmbeddings: "The saved voice data could not be read. The transcript has not been changed."
        case .noSpeech: "No speech could be identified in the saved audio."
        }
    }
}

/// Identity assignment shared by initial processing and both rediarization paths.
/// Audio sources provide evidence; only explicit user confirmation names a new
/// speaker You. Older system-only recordings retain their existing local group.
enum SpeakerAttribution {
    static let legacyLocalID = "legacy-local"

    static func recluster(
        segments: [TranscriptSegment],
        embeddings: [SpeakerEmbedding],
        totalSpeakers: Int
    ) throws -> [TranscriptSegment] {
        guard totalSpeakers > 0 else { throw SpeakerAttributionError.invalidSpeakerCount }
        guard !segments.isEmpty else { return [] }

        // An explicit merge to one identity needs no acoustic inference. Keep
        // the per-turn identity evidence so a later split remains reversible.
        if totalSpeakers == 1 {
            return displayNames(for: segments.map {
                var segment = $0
                segment.speakerID = "cluster-0"
                segment.speaker = nil
                segment.speakerConfidence = nil
                return segment
            })
        }

        try validate(embeddings)
        let legacyLocal = embeddings.allSatisfy { $0.source == nil }
            && segments.contains { $0.speaker == "You" || $0.speakerID == legacyLocalID }
        let clusterCount = totalSpeakers - (legacyLocal ? 1 : 0)
        let clusters = SpeakerClusterer.kMeansCosine(
            embeddings: embeddings.map(\.embedding), k: clusterCount
        ).map { "cluster-\($0)" }
        return assign(segments: segments, embeddings: embeddings, identities: clusters, legacyLocal: legacyLocal)
    }

    static func assignOriginal(
        segments: [TranscriptSegment], embeddings: [SpeakerEmbedding]
    ) throws -> [TranscriptSegment] {
        try validate(embeddings)
        return assign(segments: segments, embeddings: embeddings, identities: embeddings.map(\.speakerId))
    }

    static func validate(_ embeddings: [SpeakerEmbedding]) throws {
        guard let first = embeddings.first else { throw SpeakerAttributionError.missingEmbeddings }
        let dimension = first.embedding.count
        guard dimension > 0, embeddings.allSatisfy({
            $0.embedding.count == dimension && $0.embedding.allSatisfy(\.isFinite)
                && $0.embedding.contains(where: { $0 != 0 })
                && $0.startTime.isFinite && $0.endTime.isFinite
                && $0.startTime >= 0 && $0.endTime > $0.startTime
                && $0.qualityScore.isFinite
        }) else { throw SpeakerAttributionError.invalidEmbeddings }
    }

    private static func assign(
        segments: [TranscriptSegment], embeddings: [SpeakerEmbedding],
        identities: [String], legacyLocal: Bool = false
    ) -> [TranscriptSegment] {
        let labeled = segments.map { original in
            var segment = original
            segment.speaker = nil
            segment.speakerID = nil
            segment.speakerConfidence = nil

            if legacyLocal && (original.speaker == "You" || original.speakerID == legacyLocalID) {
                segment.speakerID = legacyLocalID
                segment.speakerConfidence = original.speakerConfidence
                return segment
            }

            var weights: [String: Double] = [:]
            for (index, embedding) in embeddings.enumerated() {
                if let source = segment.audioSource, let embeddingSource = embedding.source,
                   source != embeddingSource { continue }
                let overlap = max(0, min(segment.endTime, Double(embedding.endTime))
                    - max(segment.startTime, Double(embedding.startTime)))
                if overlap > 0 { weights[identities[index], default: 0] += overlap }
            }
            // Stable tie-breaking prevents identical requests from changing labels.
            if let best = weights.sorted(by: {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }).first {
                segment.speakerID = best.key
                segment.speakerConfidence = best.value / weights.values.reduce(0, +)
            }
            // No overlap is unknown, not evidence that this person is Speaker 1.
            return segment
        }
        return displayNames(for: labeled, preserveLegacyYou: legacyLocal)
    }

    static func identity(of segment: TranscriptSegment) -> String? {
        segment.speakerID ?? segment.speaker.map { "original-\($0)" }
    }

    static func identifyUser(in segments: [TranscriptSegment], speakerID: String?) -> [TranscriptSegment] {
        let annotated = segments.map { original in
            var segment = original
            segment.speakerID = identity(of: original)
            segment.isUser = speakerID != nil && segment.speakerID == speakerID
            return segment
        }
        return displayNames(for: annotated)
    }

    static func displayNames(
        for segments: [TranscriptSegment], preserveLegacyYou: Bool = false
    ) -> [TranscriptSegment] {
        var identities: [String] = []
        var confirmed: [String: Double] = [:]
        var other: Set<String> = []
        for segment in segments {
            guard let id = identity(of: segment) else { continue }
            if !identities.contains(id) { identities.append(id) }
            if segment.isUser == true {
                confirmed[id, default: 0] += max(0.001, segment.endTime - segment.startTime)
            } else if segment.isUser == false {
                other.insert(id)
            }
        }
        let candidates = confirmed.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        var userID: String?
        if let best = candidates.first,
           !other.contains(best.key),
           best.value > confirmed.values.reduce(0, +) / 2 {
            userID = best.key
        } else if preserveLegacyYou && !segments.contains(where: { $0.isUser != nil }) {
            userID = legacyLocalID
        }
        let names = Dictionary(uniqueKeysWithValues: identities.filter { $0 != userID }
            .enumerated().map { ($1, "Speaker \($0 + 1)") })
        return segments.map { original in
            var segment = original
            if let id = identity(of: original) {
                segment.speakerID = id
                segment.speaker = id == userID ? "You" : names[id]
            } else {
                segment.speaker = nil
            }
            return segment
        }
    }
}
