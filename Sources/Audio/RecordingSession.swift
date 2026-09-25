import Foundation
import Combine
import Observation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "RecordingSession")

/// Owned by AppState, so capture, transcription, notes and saving survive the
/// destruction of every window. Views only observe and control this session.
@MainActor
@Observable
final class RecordingSession {
    let captureManager: AudioCaptureManager
    let transcriptionEngine: TranscriptionEngine
    let diarizationEngine: NeuralDiarizationEngine

    private(set) var id = UUID()
    private(set) var ownsRecordingSession = false
    private(set) var isProcessingNotes = false
    private(set) var processingStatus = ""
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var savedMeeting: Meeting?
    private(set) var captureState: CaptureState = .idle

    var selectedTemplate = TemplateSettings.shared.defaultTemplate
    var customInstructions = TemplateSettings.shared.customInstructions
    var selectedLanguage = TranscriptionSettings.shared.defaultLanguage
    var selectedSummaryLanguage = SummaryLanguageSettings.shared.defaultLanguage
    var userNotesText = ""
    var timestampedNotes: [TimestampedNote] = []

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var backgroundActivity: RecordingActivity?
    @ObservationIgnored private var captureDidStart = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var elapsedBeforePause: TimeInterval = 0
    @ObservationIgnored private var runningSince: TimeInterval?
    @ObservationIgnored private var lastCheckpointTime: TimeInterval = 0
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var settingsSubscriptions = Set<AnyCancellable>()

    init(
        captureManager: AudioCaptureManager = AudioCaptureManager(),
        transcriptionEngine: TranscriptionEngine = .shared,
        diarizationEngine: NeuralDiarizationEngine = .shared,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.captureManager = captureManager
        self.transcriptionEngine = transcriptionEngine
        self.diarizationEngine = diarizationEngine
        self.now = now
        captureManager.onStateChange = { [weak self] state in
            self?.captureStateChanged(state)
        }
        // A settings window can change defaults when no recording view exists.
        // Preserve choices during capture/saving, and update only a setup draft.
        TemplateSettings.shared.$defaultTemplate.sink { [weak self] value in
            guard let self, self.isInSetupPhase else { return }
            self.selectedTemplate = value
        }.store(in: &settingsSubscriptions)
        TemplateSettings.shared.$customInstructions.sink { [weak self] value in
            guard let self, self.isInSetupPhase else { return }
            self.customInstructions = value
        }.store(in: &settingsSubscriptions)
        SummaryLanguageSettings.shared.$defaultLanguage.sink { [weak self] value in
            guard let self, self.isInSetupPhase else { return }
            self.selectedSummaryLanguage = value
        }.store(in: &settingsSubscriptions)
        TranscriptionSettings.shared.$defaultLanguage.sink { [weak self] value in
            guard let self, self.isInSetupPhase else { return }
            self.selectedLanguage = value
        }.store(in: &settingsSubscriptions)
    }

    var isRecording: Bool { captureState == .recording }
    var isPaused: Bool { captureState == .paused }
    /// Includes capture startup and a user-requested pause, but not finalization.
    var isActive: Bool { ownsRecordingSession && !isProcessingNotes }
    var isInSetupPhase: Bool { !ownsRecordingSession && savedMeeting == nil }
    var shouldRestoreRecording: Bool { ownsRecordingSession || savedMeeting != nil }
    var hasBackgroundActivity: Bool { backgroundActivity != nil }

    /// Only an explicit request for a new recording clears the preceding session.
    func prepareNewRecording() {
        guard !ownsRecordingSession, !transcriptionEngine.isSessionActive else { return }
        savedMeeting = nil
        userNotesText = ""
        timestampedNotes = []
        elapsedTime = 0
        processingStatus = ""
        selectedTemplate = TemplateSettings.shared.defaultTemplate
        customInstructions = TemplateSettings.shared.customInstructions
        selectedLanguage = TranscriptionSettings.shared.defaultLanguage
        selectedSummaryLanguage = SummaryLanguageSettings.shared.defaultLanguage
        transcriptionEngine.reset()
        id = UUID()
    }

    func startRecording(modelContext: ModelContext) {
        guard isInSetupPhase, !transcriptionEngine.isSessionActive else { return }
        if case .error = captureManager.state {
            _ = captureManager.stopRecording()
        }
        self.modelContext = modelContext
        transcriptionEngine.beginSession()
        ownsRecordingSession = true
        captureDidStart = false
        isStarting = true

        timestampedNotes = userNotesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { TimestampedNote(timestamp: 0, text: $0) }

        transcriptionEngine.selectedLanguage = selectedLanguage.whisperCode
        if let code = selectedLanguage.whisperCode {
            transcriptionEngine.detectedLanguage = code
        }
        captureManager.onAudioSamples = { [weak transcriptionEngine] samples in
            Task { @MainActor in
                transcriptionEngine?.appendAudio(samples)
            }
        }

        elapsedTime = 0
        elapsedBeforePause = 0
        lastCheckpointTime = 0
        runningSince = now()
        beginBackgroundActivity()
        startTimer()
        captureManager.startRecording()
    }

    func pauseRecording() {
        guard isActive, isRecording, !isStarting else { return }
        updateElapsedTime()
        elapsedBeforePause = elapsedTime
        runningSince = nil
        captureManager.pauseRecording()
        stopTimer()
        backgroundActivity = nil
    }

    func resumeRecording() {
        guard isActive, isPaused, !isStarting else { return }
        isStarting = true
        runningSince = now()
        beginBackgroundActivity()
        startTimer()
        captureManager.resumeRecording()
    }

    /// Called directly by AppDelegate, including when the last window is closed.
    func stopForTermination() {
        guard ownsRecordingSession, !isProcessingNotes else { return }
        if captureDidStart {
            stopRecording()
        } else {
            releaseRecordingSession()
        }
    }

    private func captureStateChanged(_ state: CaptureState) {
        captureState = state
        if case .recording = state {
            captureDidStart = true
            isStarting = false
        }
        if case .error = state, ownsRecordingSession, !isProcessingNotes {
            isStarting = false
            if captureDidStart {
                logger.notice("Capture failed after \(self.elapsedTime)s; saving the session")
                stopRecording()
            } else {
                releaseRecordingSession()
            }
        }
    }

    private func beginBackgroundActivity() {
        if backgroundActivity == nil {
            backgroundActivity = RecordingActivity()
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsedTime() }
        }
        self.timer = timer
        // Menus and window interactions must not suspend elapsed-time updates.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Derive time from a monotonic clock, never from the number of timer fires.
    /// A delayed callback while the app is hidden must not lose elapsed seconds.
    func updateElapsedTime() {
        guard let runningSince else { return }
        elapsedTime = elapsedBeforePause + max(0, now() - runningSince)
        if elapsedTime - lastCheckpointTime >= 300 {
            lastCheckpointTime = elapsedTime
            checkpoint()
        }
    }

    private func checkpoint() {
        guard let config = modelContext?.container.configurations.first,
              !config.isStoredInMemoryOnly else { return }
        let ok = DatabaseCheckpoint.performCheckpoint(at: config.url, mode: .passive)
        logger.notice("Recording checkpoint success=\(ok, privacy: .public)")
    }

    private func releaseRecordingSession() {
        captureManager.abortCapture()
        captureManager.onAudioSamples = nil
        stopTimer()
        runningSince = nil
        backgroundActivity = nil
        transcriptionEngine.endSession()
        ownsRecordingSession = false
        isStarting = false
        AppDelegate.resolveTerminationIfIdle()
    }

    @discardableResult
    func stopRecording() -> Task<Void, Never>? {
        guard ownsRecordingSession, !isProcessingNotes, let modelContext else { return nil }
        // A stop during Core Audio startup must invalidate the in-flight start.
        guard captureDidStart else {
            releaseRecordingSession()
            return nil
        }
        updateElapsedTime()
        runningSince = nil
        stopTimer()
        isStarting = false
        isProcessingNotes = true
        let recording = captureManager.stopRecording()
        let duration = elapsedTime

        // Saving must survive App Nap and a quit request even after capture stops.
        beginBackgroundActivity()
        AppDelegate.beginSavePipeline()
        return Task {
            defer {
                isProcessingNotes = false
                releaseRecordingSession()
                AppDelegate.endSavePipeline()
            }
            // 1. Finalize transcription
            processingStatus = "Finalizing transcription..."
            let segments = await transcriptionEngine.finalizeTranscription()
            logger.info("Transcription finalized: \(segments.count) segments")
            for (i, seg) in segments.prefix(5).enumerated() {
                logger.info("  Segment[\(i)]: \(String(format: "%.2f", seg.startTime))-\(String(format: "%.2f", seg.endTime))s \"\(String(seg.text.prefix(60)))\"")
            }

            // 2. Detect language (acoustic analysis, independent of transcription text)
            if transcriptionEngine.detectedLanguage == nil {
                let languageDetectionSource = recording.systemSamples.isEmpty
                    ? recording.combinedSamples
                    : recording.systemSamples
                let detectSamples = Array(languageDetectionSource.prefix(Int(16000 * 30)))
                await transcriptionEngine.detectLanguage(detectSamples)
            }

            // 3. Diarize
            processingStatus = "Identifying speakers..."
            let diarizeResult = await diarizationEngine.diarize(
                segments: segments,
                systemSamples: recording.systemSamples,
                micSamples: recording.micSamples,
                detectedLanguage: transcriptionEngine.detectedLanguage
            )
            let diarizedSegments = diarizeResult.segments

            // Log diarization results
            let speakers = Set(diarizedSegments.compactMap(\.speaker))
            logger.info("Diarization complete: \(diarizedSegments.count) segments, speakers: \(speakers.sorted()), embeddings: \(diarizeResult.speakerEmbeddings.count)")

            // 4. Create transcript
            let transcript = Transcript(
                rawText: transcriptionEngine.liveText,
                segments: diarizedSegments
            )
            logger.info("Transcript created. rawText length: \(transcript.rawText.count), segments: \(transcript.segments.count)")

            // 5. Rebuild timestampedNotes from the final notepad so it faithfully
            // mirrors the notes the user actually kept (see TimestampedNote.reconcile).
            // Enhancement and markdown export prefer it over the raw text, so it
            // must contain every kept line and nothing stale, even after the user
            // edits, deletes, or duplicates lines mid-session.
            let trimmedNotes = userNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
            timestampedNotes = TimestampedNote.reconcile(
                notepadText: userNotesText,
                log: timestampedNotes,
                trailingTimestamp: elapsedTime
            )

            // 6. Save session
            let sessionTitle = "Session \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            let meeting = Meeting(
                title: sessionTitle,
                date: captureManager.recordingStartTime ?? Date(),
                duration: duration,
                appSource: captureManager.selectedProcess?.name,
                appBundleID: captureManager.selectedProcess?.bundleID
            )
            meeting.transcript = transcript
            transcript.meeting = meeting

            // Save user notes and timestamps
            meeting.userNotesText = trimmedNotes.isEmpty ? nil : trimmedNotes
            meeting.timestampedNotes = timestampedNotes.isEmpty ? nil : timestampedNotes

            // Save speaker embeddings for lightweight re-clustering (~500KB vs ~115MB raw audio)
            meeting.speakerEmbeddings = diarizeResult.speakerEmbeddings
            meeting.originalSpeakerCount = speakers.count
            meeting.originalSegmentsData = transcript.segmentsData
            meeting.detectedLanguage = transcriptionEngine.detectedLanguage

            modelContext.insert(meeting)
            try? modelContext.save()
            checkpoint()
            savedMeeting = meeting
        }
    }
}

/// The assertion permits display sleep, while preventing App Nap and idle
/// system sleep for capture/finalization. Releasing it also handles early exits.
private final class RecordingActivity {
    private let token = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Recording and saving meeting audio"
    )

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}
