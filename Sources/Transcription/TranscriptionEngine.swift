import Foundation
@preconcurrency import WhisperKit
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "Transcription")

@MainActor
final class TranscriptionEngine: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var liveText: String = ""
    @Published var segments: [TranscriptSegment] = []
    @Published var loadingProgress: String = ""
    @Published var downloadFraction: Double = 0
    @Published var isDownloading = false
    @Published var errorMessage: String?
    @Published var detectedLanguage: String?

    /// When set (e.g. "en", "zh"), forces WhisperKit to transcribe in this language.
    /// When nil, WhisperKit auto-detects per chunk.
    var selectedLanguage: String?

    private var whisperKit: WhisperKit?
    private var accumulatedAudio: [Float] = []
    private var transcriptionTask: Task<Void, Never>?
    private var hasDetectedLanguage = false
    private let chunkDuration: Double = 30.0 // Process in 30-second chunks
    private let sampleRate: Double = 16000.0

    func loadModel(name: String = TranscriptionSettings.defaultModel) async {
        guard !isModelLoaded else { return }
        do {
            // Step 1: Download with progress
            isDownloading = true
            downloadFraction = 0
            loadingProgress = "Downloading \(name)..."
            let modelFolder = try await WhisperKit.download(
                variant: name
            ) { @Sendable [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadFraction = progress.fractionCompleted
                    let pct = Int(progress.fractionCompleted * 100)
                    self.loadingProgress = "Downloading \(name)... \(pct)%"
                }
            }
            isDownloading = false

            // Step 2: Load model from downloaded folder
            loadingProgress = "Preparing transcription model..."
            whisperKit = try await WhisperKit(
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .none,
                download: false
            )
            isModelLoaded = true
            loadingProgress = ""
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
            loadingProgress = ""
            isDownloading = false
        }
    }

    func appendAudio(_ samples: [Float]) {
        accumulatedAudio.append(contentsOf: samples)

        // Trigger transcription when we have enough audio
        let chunkSamples = Int(chunkDuration * sampleRate)
        if accumulatedAudio.count >= chunkSamples && !isTranscribing {
            processAccumulatedAudio()
        }
    }

    func processAccumulatedAudio() {
        guard !isTranscribing, !accumulatedAudio.isEmpty else { return }

        let audioToProcess = accumulatedAudio
        accumulatedAudio = []

        transcriptionTask = Task {
            await transcribe(audioToProcess)
        }
    }

    func finalizeTranscription() async -> [TranscriptSegment] {
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if !accumulatedAudio.isEmpty {
            let remaining = accumulatedAudio
            accumulatedAudio = []
            await transcribe(remaining)
        }
        return segments
    }

    private func transcribe(_ audio: [Float]) async {
        guard let whisperKit else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Calculate offset ONCE per chunk — WhisperKit segment timestamps
            // are relative to the start of the audio array passed in.
            let timeOffset = totalTranscribedDuration()
            let options = DecodingOptions(language: selectedLanguage, wordTimestamps: true)
            let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
            for result in results {
                for segment in result.segments {
                    let cleanedText = Self.stripWhisperTokens(segment.text)
                    let newSegment = TranscriptSegment(
                        startTime: timeOffset + Double(segment.start),
                        endTime: timeOffset + Double(segment.end),
                        text: cleanedText
                    )
                    if !newSegment.text.isEmpty {
                        segments.append(newSegment)
                        liveText += newSegment.text + " "
                    }
                }
            }
        } catch {
            errorMessage = "Transcription error: \(error.localizedDescription)"
        }
    }

    /// Remove WhisperKit special tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect spoken language using WhisperKit's acoustic analysis (first 30s of audio).
    /// Independent of transcription output — correctly identifies Chinese even if
    /// the model transcribes it as English text.
    func detectLanguage(_ audio: [Float]) async {
        guard !hasDetectedLanguage, let whisperKit else { return }
        hasDetectedLanguage = true
        do {
            let (language, probabilities) = try await whisperKit.detectLangauge(audioArray: audio)
            detectedLanguage = language
            let top3 = probabilities.sorted { $0.value > $1.value }.prefix(3)
            logger.info("Language detection: \(language) — \(top3.map { "\($0.key): \(String(format: "%.1f%%", $0.value * 100))" }.joined(separator: ", "))")
        } catch {
            logger.warning("Language detection failed: \(error.localizedDescription)")
        }
    }

    private func totalTranscribedDuration() -> Double {
        segments.last?.endTime ?? 0
    }

    func reset() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        accumulatedAudio = []
        segments = []
        liveText = ""
        isTranscribing = false
        errorMessage = nil
        detectedLanguage = nil
        hasDetectedLanguage = false
        selectedLanguage = nil
    }
}
