import Foundation

/// Source selection is an echo-reduction heuristic, never a person identifier.
enum DiarizationAudio {
    static let silenceFloor: Float = 0.001

    static func energy(_ samples: [Float], start: Double, end: Double, sampleRate: Double) -> Float {
        guard sampleRate.isFinite, sampleRate > 0, start.isFinite, end.isFinite,
              end > start, !samples.isEmpty else { return 0 }
        let duration = Double(samples.count) / sampleRate
        let lower = Int(min(max(0, start), duration) * sampleRate)
        let upper = min(samples.count, Int(min(max(0, end), duration) * sampleRate))
        guard lower < upper else { return 0 }
        let sum = samples[lower..<upper].reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(upper - lower))
    }

    static func preferredSource(
        start: Double, end: Double, system: [Float], microphone: [Float], sampleRate: Double
    ) -> SpeakerAudioSource? {
        let systemEnergy = energy(system, start: start, end: end, sampleRate: sampleRate)
        let micEnergy = energy(microphone, start: start, end: end, sampleRate: sampleRate)
        if micEnergy > silenceFloor && (systemEnergy <= silenceFloor || micEnergy > systemEnergy * 2) {
            return .microphone
        }
        return systemEnergy > silenceFloor ? .system : nil
    }

    static func annotate(
        _ segments: [TranscriptSegment], system: [Float], microphone: [Float], sampleRate: Double
    ) -> [TranscriptSegment] {
        segments.map { original in
            var segment = original
            segment.audioSource = preferredSource(
                start: original.startTime, end: original.endTime,
                system: system, microphone: microphone, sampleRate: sampleRate
            )
            return segment
        }
    }
}
