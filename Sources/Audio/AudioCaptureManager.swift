import AVFoundation
import Combine
import Foundation

enum CaptureSource: Hashable, Sendable {
    case systemAudio(AudioProcess)
    case microphone
}

enum CaptureState: Sendable, Equatable {
    case idle
    case recording
    case paused
    case error(String)
}

/// Thread-safe audio buffer accumulator that runs off the main actor.
/// Tracks combined, system-only, and mic-only sample streams.
/// When both system and mic are active, produces a time-aligned mix
/// (sample-by-sample average up to min(sys, mic) count) instead of
/// concatenating chunks, which caused garbled live transcription.
final class AudioBufferAccumulator: @unchecked Sendable {
    static let micPassThroughFallbackSampleCount = 32_000

    private let lock = NSLock()
    private var _samples: [Float] = []
    private var _systemSamples: [Float] = []
    private var _micSamples: [Float] = []
    private var _emittedSampleCount: Int = 0
    private var _systemConverter: AudioFormatConverter?
    private var _micConverter: AudioFormatConverter?
    private var _hasMicInput = false
    private var _hasSystemSource = false
    private var _micPassThroughFallback = false

    var onAudioSamples: (@Sendable ([Float]) -> Void)?

    /// Combined audio samples (time-aligned system + mic mix, or system-only).
    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return _samples
    }

    /// System audio samples only.
    var systemSamples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return _systemSamples
    }

    /// Microphone audio samples only. Empty if mic was not active.
    var micSamples: [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return _hasMicInput ? _micSamples : nil
    }

    /// Call before audio starts flowing to tell the accumulator which streams to expect.
    /// When both streams are expected, system audio waits for mic data before emitting
    /// time-aligned mixes. Mic-only recordings pass through directly.
    func setMicExpected(_ expected: Bool, hasSystemSource: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        _hasMicInput = expected
        _hasSystemSource = hasSystemSource
        _micPassThroughFallback = false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _samples = []
        _systemSamples = []
        _micSamples = []
        _emittedSampleCount = 0
        _systemConverter = nil
        _micConverter = nil
        _hasMicInput = false
        _hasSystemSource = false
        _micPassThroughFallback = false
    }

    func handleSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if _systemConverter == nil {
            _systemConverter = try? AudioFormatConverter(sourceFormat: buffer.format)
        }
        let converter = _systemConverter
        lock.unlock()

        guard let converter,
              let converted = converter.convert(buffer),
              let newSamples = AudioFormatConverter.extractFloatSamples(from: converted) else {
            return
        }
        lock.lock()
        _systemSamples.append(contentsOf: newSamples)
        lock.unlock()
        _computeNewMixedSamples()
    }

    func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if _micConverter == nil {
            _micConverter = try? AudioFormatConverter(sourceFormat: buffer.format)
        }
        let converter = _micConverter
        _hasMicInput = true
        lock.unlock()

        guard let converter,
              let converted = converter.convert(buffer),
              let newSamples = AudioFormatConverter.extractFloatSamples(from: converted) else {
            return
        }
        lock.lock()
        _micSamples.append(contentsOf: newSamples)
        lock.unlock()
        _computeNewMixedSamples()
    }

    /// Compute time-aligned mixed samples from the cursor forward.
    /// When mic is active: mix = (sys[i] + mic[i]) * 0.5 up to min(sysCount, micCount).
    /// When mic is inactive: pass system audio through directly.
    /// Only emits NEW samples since the last call.
    private func _computeNewMixedSamples() {
        lock.lock()
        let sysCount = _systemSamples.count
        let micCount = _micSamples.count
        let hasMic = _hasMicInput
        let hasSystemSource = _hasSystemSource
        let cursor = _emittedSampleCount

        let newSamples: [Float]
        if hasMic {
            let micSamplesWaiting = micCount - cursor
            let shouldPassThroughMic = !hasSystemSource
                || _micPassThroughFallback
                || (sysCount <= cursor && micSamplesWaiting >= Self.micPassThroughFallbackSampleCount)

            if shouldPassThroughMic {
                // Mic-only or effectively silent system source: emit mic samples directly.
                // Once the fallback trips, keep this stream consistent for transcription.
                _micPassThroughFallback = hasSystemSource
                guard micCount > cursor else {
                    lock.unlock()
                    return
                }
                newSamples = Array(_micSamples[cursor..<micCount])
                _emittedSampleCount = micCount
                _samples.append(contentsOf: newSamples)
                lock.unlock()
                onAudioSamples?(newSamples)
                return
            }

            // Time-aligned mix: only emit up to where both streams have data
            let mixEnd = min(sysCount, micCount)
            guard mixEnd > cursor else {
                lock.unlock()
                return
            }
            newSamples = (cursor..<mixEnd).map { i in
                (_systemSamples[i] + _micSamples[i]) * 0.5
            }
            _emittedSampleCount = mixEnd
        } else {
            // System-only: pass through directly
            guard sysCount > cursor else {
                lock.unlock()
                return
            }
            newSamples = Array(_systemSamples[cursor..<sysCount])
            _emittedSampleCount = sysCount
        }
        _samples.append(contentsOf: newSamples)
        lock.unlock()
        onAudioSamples?(newSamples)
    }
}

@MainActor
final class AudioCaptureManager: ObservableObject {
    @Published var state: CaptureState = .idle
    @Published var availableProcesses: [AudioProcess] = []
    @Published var selectedProcess: AudioProcess?
    @Published var captureMicrophone = true
    @Published var isOutputBuiltInSpeaker = false

    private let processTap = ProcessTapManager()
    private let micCapture = MicrophoneCaptureManager()
    private let accumulator = AudioBufferAccumulator()
    private var refreshTimer: Timer?
    private(set) var recordingStartTime: Date?

    // Capture start runs on a detached task (Core Audio setup blocks). A stop
    // or abort issued while that task is in flight bumps this token, and the
    // stale task's completion must not flip state or leave taps running.
    private var captureGeneration = 0

    var onAudioSamples: (@Sendable ([Float]) -> Void)? {
        get { accumulator.onAudioSamples }
        set { accumulator.onAudioSamples = newValue }
    }

    var accumulatedSamples: [Float] {
        accumulator.samples
    }

    var systemSamples: [Float] {
        accumulator.systemSamples
    }

    var micSamples: [Float]? {
        accumulator.micSamples
    }

    func refreshProcessList() {
        do {
            let processes = try CoreAudioUtils.listAudioProcesses()
            self.availableProcesses = processes.sorted { a, b in
                if a.isRunningOutput != b.isRunningOutput {
                    return a.isRunningOutput
                }
                return a.name < b.name
            }
        } catch {
            self.availableProcesses = []
        }
        isOutputBuiltInSpeaker = CoreAudioUtils.isOutputBuiltInSpeaker()
    }

    func startRecording() {
        guard case .idle = state else { return }

        accumulator.reset()
        recordingStartTime = Date()
        isOutputBuiltInSpeaker = CoreAudioUtils.isOutputBuiltInSpeaker()

        let process = selectedProcess
        let wantMic = captureMicrophone
        accumulator.setMicExpected(wantMic, hasSystemSource: process != nil)
        let acc = accumulator
        let tap = processTap
        let mic = micCapture

        // Set up callbacks before moving to background
        tap.audioBufferCallback = { buffer in
            acc.handleSystemAudioBuffer(buffer)
        }
        mic.audioBufferCallback = { buffer in
            acc.handleMicrophoneBuffer(buffer)
        }

        // Move blocking Core Audio setup off the main thread
        captureGeneration += 1
        let generation = captureGeneration
        Task.detached(priority: .userInitiated) {
            // Start system audio tap
            if let process {
                do {
                    try tap.start(processObjectID: process.objectID)
                } catch {
                    await MainActor.run {
                        guard generation == self.captureGeneration else { return }
                        self.state = .error("System audio: \(error.localizedDescription)")
                    }
                    return
                }
            }

            // Start microphone capture
            if wantMic {
                do {
                    try mic.start()
                } catch {
                    tap.stop()
                    await MainActor.run {
                        guard generation == self.captureGeneration else { return }
                        self.state = .error("Microphone: \(error.localizedDescription)")
                    }
                    return
                }
            }

            await MainActor.run {
                // A stop/abort superseded this start while Core Audio was
                // setting up — kill the freshly started taps instead of
                // resurrecting a capture nobody owns.
                guard generation == self.captureGeneration else {
                    tap.stop()
                    mic.stop()
                    return
                }
                self.state = .recording

                // Periodically refresh process list
                self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshProcessList()
                    }
                }
            }
        }
    }

    func pauseRecording() {
        guard case .recording = state else { return }
        processTap.stop()
        micCapture.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        state = .paused
    }

    func resumeRecording() {
        guard case .paused = state else { return }

        let process = selectedProcess
        let wantMic = captureMicrophone
        let tap = processTap
        let mic = micCapture
        let acc = accumulator
        accumulator.setMicExpected(wantMic, hasSystemSource: process != nil)

        // Re-attach callbacks (cleared on stop)
        tap.audioBufferCallback = { buffer in
            acc.handleSystemAudioBuffer(buffer)
        }
        mic.audioBufferCallback = { buffer in
            acc.handleMicrophoneBuffer(buffer)
        }

        captureGeneration += 1
        let generation = captureGeneration
        Task.detached(priority: .userInitiated) {
            if let process {
                do {
                    try tap.start(processObjectID: process.objectID)
                } catch {
                    await MainActor.run {
                        guard generation == self.captureGeneration else { return }
                        self.state = .error("Resume system audio: \(error.localizedDescription)")
                    }
                    return
                }
            }

            if wantMic {
                do {
                    try mic.start()
                } catch {
                    tap.stop()
                    await MainActor.run {
                        guard generation == self.captureGeneration else { return }
                        self.state = .error("Resume microphone: \(error.localizedDescription)")
                    }
                    return
                }
            }

            await MainActor.run {
                // Superseded by a stop/abort while starting — see startRecording.
                guard generation == self.captureGeneration else {
                    tap.stop()
                    mic.stop()
                    return
                }
                self.state = .recording
                self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshProcessList()
                    }
                }
            }
        }
    }

    /// Result of stopping a recording, containing combined and channel-separated audio.
    struct RecordingResult {
        let combinedSamples: [Float]
        let systemSamples: [Float]
        let micSamples: [Float]?
    }

    func stopRecording() -> RecordingResult {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Stop unconditionally and bump the generation: a resume/start may
        // still be inside its detached Core Audio setup, and this stop must
        // win that race (stop on a not-started tap is a no-op).
        captureGeneration += 1
        processTap.stop()
        micCapture.stop()
        state = .idle

        return RecordingResult(
            combinedSamples: accumulator.samples,
            systemSamples: accumulator.systemSamples,
            micSamples: accumulator.micSamples
        )
    }

    /// Kill any live or in-flight-starting capture WITHOUT touching the
    /// published state — used when a recording session is released after a
    /// capture error, where resetting state would hide the error banner.
    func abortCapture() {
        captureGeneration += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        processTap.stop()
        micCapture.stop()
    }

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }
}
