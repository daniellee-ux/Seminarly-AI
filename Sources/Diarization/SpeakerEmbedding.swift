import Foundation

/// Codable mirror of FluidAudio's `TimedSpeakerSegment` for persisting speaker embeddings
/// without storing raw audio. ~500KB for a 30-minute meeting vs ~115MB of raw Float32 audio.
struct SpeakerEmbedding: Codable, Sendable {
    let speakerId: String
    let embedding: [Float]
    let startTime: Float
    let endTime: Float
    let qualityScore: Float
}
