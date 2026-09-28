import AVFoundation
import Foundation

/// Retains the exact 16 kHz mono Float32 stream sent to ASR. Separate source
/// tracks remain transient; speaker re-clustering continues to use embeddings.
enum RecordingAudioStore {
    static let preferenceKey = "retainRecordingAudio"

    static func save(samples: [Float], directory: URL = Meeting.audioDirectory) throws -> String? {
        guard !samples.isEmpty else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).transcription.wav"
        let destination = directory.appendingPathComponent(name)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial.wav")
        defer { try? fm.removeItem(at: staging) }
        try writeWAV(samples: samples, to: staging)
        // Publish only a closed, complete WAV; failed writes leave no partial file.
        try fm.moveItem(at: staging, to: destination)
        return name
    }

    private static func writeWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        // AVAudioFile closes and finalizes the header before save() publishes it.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try samples.withUnsafeBufferPointer { source in
            for offset in stride(from: 0, to: source.count, by: Int(buffer.frameCapacity)) {
                let count = min(Int(buffer.frameCapacity), source.count - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                channel.update(from: source.baseAddress!.advanced(by: offset), count: count)
                try file.write(from: buffer)
            }
        }
    }
}
