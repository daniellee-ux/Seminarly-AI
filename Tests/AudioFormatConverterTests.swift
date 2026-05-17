import XCTest
import AVFoundation
@testable import Seminarly

final class AudioFormatConverterTests: XCTestCase {

    func testConvert48kHzStereoTo16kHzMono() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let converter = try AudioFormatConverter(sourceFormat: sourceFormat)

        let frameCount: AVAudioFrameCount = 4800 // 100ms at 48kHz
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)!
        inputBuffer.frameLength = frameCount

        // Fill with a simple sine wave
        let channelData = inputBuffer.floatChannelData!
        for i in 0..<Int(frameCount) {
            let sample = sin(Float(i) * 2 * .pi * 440 / 48000)
            channelData[0][i] = sample
            channelData[1][i] = sample
        }

        let output = converter.convert(inputBuffer)
        XCTAssertNotNil(output)

        // 4800 frames at 48kHz → should be ~1600 frames at 16kHz
        // AVAudioConverter may produce slightly fewer frames due to internal buffering
        let actualFrames = Int(output!.frameLength)
        XCTAssertGreaterThan(actualFrames, 0, "Should produce some output")
        XCTAssertLessThanOrEqual(actualFrames, 1700, "Should not exceed expected range")
    }

    func testConvert44100HzStereoTo16kHzMono() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!
        let converter = try AudioFormatConverter(sourceFormat: sourceFormat)

        let frameCount: AVAudioFrameCount = 4410 // 100ms at 44.1kHz
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)!
        inputBuffer.frameLength = frameCount

        let channelData = inputBuffer.floatChannelData!
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float.random(in: -1...1)
            channelData[1][i] = Float.random(in: -1...1)
        }

        let output = converter.convert(inputBuffer)
        XCTAssertNotNil(output)

        // AVAudioConverter may produce slightly fewer frames due to internal buffering
        let actualFrames = Int(output!.frameLength)
        XCTAssertGreaterThan(actualFrames, 0, "Should produce some output")
        XCTAssertLessThanOrEqual(actualFrames, 1700, "Should not exceed expected range")
    }

    func testEmptyBufferReturnsNil() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!
        let converter = try AudioFormatConverter(sourceFormat: sourceFormat)

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 1024)!
        inputBuffer.frameLength = 0

        let output = converter.convert(inputBuffer)
        XCTAssertNil(output)
    }

    func testOutputIsMono() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let converter = try AudioFormatConverter(sourceFormat: sourceFormat)
        XCTAssertEqual(converter.whisperFormat.channelCount, 1)
        XCTAssertEqual(converter.whisperFormat.sampleRate, 16000)
    }

    func testExtractFloatSamples() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 100
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        // Fill with known values
        let channelData = buffer.floatChannelData!
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float(i) / Float(frameCount)
        }

        let samples = AudioFormatConverter.extractFloatSamples(from: buffer)
        XCTAssertNotNil(samples)
        XCTAssertEqual(samples!.count, Int(frameCount))
        XCTAssertEqual(samples![0], 0.0, accuracy: 0.001)
        XCTAssertEqual(samples![50], 0.5, accuracy: 0.001)
    }
}
