import XCTest
import AVFoundation
@testable import Seminarly

final class AudioBufferAccumulatorTests: XCTestCase {

    func testSystemOnlyPassesThrough() {
        let acc = AudioBufferAccumulator()

        // Simulate system audio arriving
        let sysSamples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        pushSystemSamples(sysSamples, to: acc)

        // System-only mode: output count should equal input count
        XCTAssertEqual(acc.samples.count, sysSamples.count, "System-only: output count should equal input count")
        for (i, expected) in sysSamples.enumerated() {
            XCTAssertEqual(acc.samples[i], expected, accuracy: 1e-4)
        }

        // System samples should be preserved separately
        XCTAssertEqual(acc.systemSamples.count, sysSamples.count)
        // Mic should be nil
        XCTAssertNil(acc.micSamples)
    }

    func testDualStreamTimeAlignedMix() {
        let acc = AudioBufferAccumulator()
        acc.setMicExpected(true)

        // Push 5 system samples
        let sysSamples: [Float] = [0.4, 0.6, 0.8, 1.0, 0.2]
        pushSystemSamples(sysSamples, to: acc)

        // Push 3 mic samples (shorter than system)
        let micSamples: [Float] = [0.2, 0.4, 0.6]
        pushMicSamples(micSamples, to: acc)

        // Time-aligned mix: output count = min(sys, mic) = 3, NOT sys + mic = 8
        XCTAssertEqual(acc.samples.count, 3, "Dual-stream: output count should be min(sys, mic), not sum")

        // Verify mixing: (sys[i] + mic[i]) * 0.5
        let expected: [Float] = [
            (0.4 + 0.2) * 0.5,  // 0.3
            (0.6 + 0.4) * 0.5,  // 0.5
            (0.8 + 0.6) * 0.5,  // 0.7
        ]
        for (i, exp) in expected.enumerated() {
            XCTAssertEqual(acc.samples[i], exp, accuracy: 1e-4, "Sample \(i) should be time-aligned mix")
        }

        // Raw channel data preserved
        XCTAssertEqual(acc.systemSamples.count, 5)
        XCTAssertEqual(acc.micSamples?.count, 3)
    }

    func testDualStreamCatchesUpWhenMoreMicArrives() {
        let acc = AudioBufferAccumulator()
        acc.setMicExpected(true)

        // Push 5 system samples
        pushSystemSamples([0.2, 0.4, 0.6, 0.8, 1.0], to: acc)
        // Push 3 mic samples → mix emits 3
        pushMicSamples([0.1, 0.3, 0.5], to: acc)
        XCTAssertEqual(acc.samples.count, 3)

        // Push 2 more mic samples → mix should catch up to 5
        pushMicSamples([0.7, 0.9], to: acc)
        XCTAssertEqual(acc.samples.count, 5, "Should catch up when more mic arrives")

        // Verify the last two mixed samples
        let expected3 = (Float(0.8) + Float(0.7)) * 0.5
        let expected4 = (Float(1.0) + Float(0.9)) * 0.5
        XCTAssertEqual(acc.samples[3], expected3, accuracy: 1e-6)
        XCTAssertEqual(acc.samples[4], expected4, accuracy: 1e-6)
    }

    func testMicOnlyWithoutSystemSourcePassesThroughAndEmits() {
        let acc = AudioBufferAccumulator()
        acc.setMicExpected(true, hasSystemSource: false)

        let emitted = ThreadSafeSamples()
        acc.onAudioSamples = { samples in
            emitted.append(samples)
        }

        let micSamples: [Float] = [0.15, 0.25, 0.35, 0.45]
        pushMicSamples(micSamples, to: acc)

        XCTAssertEqual(acc.samples.count, micSamples.count)
        XCTAssertEqual(emitted.values.count, micSamples.count)
        XCTAssertEqual(acc.systemSamples.count, 0)
        XCTAssertEqual(acc.micSamples?.count, micSamples.count)

        for (index, expected) in micSamples.enumerated() {
            XCTAssertEqual(acc.samples[index], expected, accuracy: 1e-4)
            XCTAssertEqual(emitted.values[index], expected, accuracy: 1e-4)
        }
    }

    func testMicFallsBackToPassThroughWhenSystemSourceStaysSilent() {
        let acc = AudioBufferAccumulator()
        acc.setMicExpected(true, hasSystemSource: true)

        let micSamples = Array(repeating: Float(0.25), count: AudioBufferAccumulator.micPassThroughFallbackSampleCount)
        pushMicSamples(micSamples, to: acc)

        XCTAssertEqual(acc.samples.count, micSamples.count)
        XCTAssertEqual(acc.systemSamples.count, 0)
        XCTAssertEqual(acc.micSamples?.count, micSamples.count)
        XCTAssertEqual(acc.samples.first ?? 0, Float(0.25), accuracy: 1e-4)

        let laterMicSamples: [Float] = [0.4, 0.5, 0.6]
        pushMicSamples(laterMicSamples, to: acc)
        XCTAssertEqual(acc.samples.count, micSamples.count + laterMicSamples.count)
        for (index, expected) in laterMicSamples.enumerated() {
            XCTAssertEqual(acc.samples[micSamples.count + index], expected, accuracy: 1e-4)
        }
    }

    func testResetClearsEverything() {
        let acc = AudioBufferAccumulator()
        acc.setMicExpected(true)
        pushSystemSamples([0.1, 0.2, 0.3], to: acc)
        pushMicSamples([0.4, 0.5, 0.6], to: acc)

        acc.reset()

        XCTAssertEqual(acc.samples.count, 0)
        XCTAssertEqual(acc.systemSamples.count, 0)
        XCTAssertNil(acc.micSamples)
    }

    // MARK: - Helpers

    /// Push raw float samples into the accumulator's system stream,
    /// bypassing AVAudioPCMBuffer creation (which requires AudioFormatConverter).
    private func pushSystemSamples(_ samples: [Float], to acc: AudioBufferAccumulator) {
        // Access internal state through handleSystemAudioBuffer by creating a proper buffer
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() {
            channelData[i] = s
        }
        acc.handleSystemAudioBuffer(buffer)
    }

    private func pushMicSamples(_ samples: [Float], to acc: AudioBufferAccumulator) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() {
            channelData[i] = s
        }
        acc.handleMicrophoneBuffer(buffer)
    }

    private final class ThreadSafeSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Float] = []

        var values: [Float] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ samples: [Float]) {
            lock.lock()
            storage.append(contentsOf: samples)
            lock.unlock()
        }
    }
}
