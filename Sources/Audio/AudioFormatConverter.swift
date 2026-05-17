import AVFoundation

final class AudioFormatConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    let whisperFormat: AVAudioFormat

    init(sourceFormat: AVAudioFormat) throws {
        self.sourceFormat = sourceFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverterError.invalidFormat("Failed to create 16kHz mono format")
        }
        self.whisperFormat = targetFormat

        guard let conv = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioConverterError.converterCreationFailed(
                "Cannot convert from \(sourceFormat.sampleRate)Hz to 16kHz"
            )
        }
        self.converter = conv
    }

    convenience init(streamDescription: AudioStreamBasicDescription) throws {
        var desc = streamDescription
        guard let format = AVAudioFormat(streamDescription: &desc) else {
            throw AudioConverterError.invalidFormat("Invalid stream description")
        }
        try self.init(sourceFormat: format)
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFrameCount = inputBuffer.frameLength
        guard inputFrameCount > 0 else { return nil }

        let ratio = whisperFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 128

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        var consumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}

enum AudioConverterError: LocalizedError {
    case invalidFormat(String)
    case converterCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return msg
        case .converterCreationFailed(let msg): return msg
        }
    }
}
