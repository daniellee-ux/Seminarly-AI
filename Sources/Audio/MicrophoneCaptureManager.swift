import AVFoundation
import Foundation

final class MicrophoneCaptureManager: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private(set) var isRecording = false

    var audioBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func start() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw MicrophoneError.noInputDevice
        }

        let callback = self.audioBufferCallback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            callback?(buffer)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.isRecording = true
    }

    func stop() {
        guard isRecording, let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.audioEngine = nil
        self.isRecording = false
    }

    var inputFormat: AVAudioFormat? {
        audioEngine?.inputNode.outputFormat(forBus: 0)
    }
}

enum MicrophoneError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input device available"
        }
    }
}
