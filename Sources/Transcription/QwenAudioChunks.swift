import Foundation

/// Bounds Qwen's timestamp-free output to short audio intervals. These are
/// approximate segment boundaries, never fabricated word timestamps.
enum QwenAudioChunks {
    static let sampleRate = 16000
    static func ranges(in samples: [Float]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        let maximum = 8 * sampleRate
        let frame = sampleRate / 50
        while start < samples.count {
            var end = min(start + maximum, samples.count)
            if end < samples.count {
                let searchStart = end - 2 * sampleRate
                var lowest = Double.infinity
                for position in stride(from: searchStart, through: end - frame, by: frame) {
                    let energy = samples[position..<(position + frame)].reduce(0.0) { $0 + Double($1 * $1) }
                    if energy < lowest { lowest = energy; end = position + frame }
                }
            }
            result.append(start..<end)
            start = end
        }
        return result
    }

    static func hasSignal(_ samples: ArraySlice<Float>) -> Bool {
        samples.contains { abs($0) > 0.00001 }
    }
}
