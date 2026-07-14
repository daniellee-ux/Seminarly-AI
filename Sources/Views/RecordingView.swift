import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "RecordingView")

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Binding var selectedMeeting: Meeting?

    @StateObject private var captureManager = AudioCaptureManager()
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    @ObservedObject var diarizationEngine: NeuralDiarizationEngine

    /// True while this view sits in its post-recording (saved) state, i.e.
    /// `savedMeeting` is set. Owned per-window by ContentView (which re-keys a
    /// *finished* recording on the next "Record") — a global flag here would let
    /// one window's teardown clobber another window's saved-screen state.
    @Binding var recordingSaved: Bool
    @ObservedObject private var enhancement = EnhancementCoordinator.shared
    @ObservedObject private var templateSettings = TemplateSettings.shared
    @ObservedObject private var summaryLanguageSettings = SummaryLanguageSettings.shared
    @ObservedObject var audioMonitor: AudioSourceMonitor

    /// When set, auto-selects this process on appear (from auto-detection banner).
    var preSelectedProcess: AudioProcess?

    /// Whether this view is currently visible in the UI (affects toolbar contributions).
    var isVisible: Bool = true

    /// Called when the view wants to close itself (recording fully finished).
    var onDismiss: () -> Void = {}

    /// Called when the user wants to navigate away while keeping recording alive.
    var onNavigateAway: () -> Void = {}

    @State private var isProcessingNotes = false
    @State private var processingStatus = ""
    @State private var elapsedTime: TimeInterval = 0
    @State private var pausedDuration: TimeInterval = 0
    @State private var pauseStartTime: Date?
    @State private var timer: Timer?
    @State private var selectedTemplate: NoteTemplate = TemplateSettings.shared.defaultTemplate
    @State private var customInstructions: String = TemplateSettings.shared.customInstructions
    @State private var selectedLanguage: TranscriptionLanguage = TranscriptionSettings.shared.defaultLanguage
    @State private var selectedSummaryLanguage: SummaryLanguage = SummaryLanguageSettings.shared.defaultLanguage
    @State private var summaryLanguageCustomDraft: String = SummaryLanguageSettings.shared.lastCustomLanguage
    @State private var showSummaryLanguageCustomEditor: Bool = false
    @State private var showRegenerateSheet: Bool = false

    // Notepad state
    @State private var userNotesText = ""
    @State private var showTranscript = true
    // Live, append-only log of notes completed during recording. It can drift
    // from the editable notepad as the user edits/deletes lines, so it is
    // rebuilt from the final notepad text in stopRecording() before saving.
    @State private var timestampedNotes: [TimestampedNote] = []

    // Post-recording lifecycle state (set after stopRecording saves the meeting)
    @State private var savedMeeting: Meeting?

    // True from Record-click until this view's recording session is released
    // (saved, failed, or torn down). Unlike isRecording/isPaused — which derive
    // from captureManager.state and are false both before capture actually
    // starts and after a capture error — this tracks session OWNERSHIP, so
    // cleanup can't be skipped in those states (which would leak the app-wide
    // recording flags and the shared engine's session forever).
    @State private var ownsRecordingSession = false
    // True once capture actually reached .recording for this attempt — a
    // start-failure has elapsed-timer ticks but no audio, and must not be
    // salvaged as an (empty) meeting.
    @State private var captureDidStart = false

    var body: some View {
        VStack(spacing: 0) {
            if let meeting = savedMeeting {
                postRecordingView(meeting: meeting)
            } else if isRecording || isPaused || isProcessingNotes {
                activeRecordingView
            } else {
                setupView
            }
        }
        .background(SeminarlyColors.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showRegenerateSheet) {
            if let meeting = savedMeeting {
                RegenerateNotesSheet(
                    initialTemplate: initialRegenerateTemplate(for: meeting),
                    initialLanguage: initialRegenerateLanguage(for: meeting),
                    detectedLanguage: detectedSummaryLanguage(for: meeting)
                ) { template, language in
                    applyEnhancementPreferences(template: template, language: language, meeting: meeting)
                }
            }
        }
        .if(isVisible) { view in
            view
                .navigationTitle("Recording")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            if isRecording || isPaused {
                                onNavigateAway()
                            } else {
                                onDismiss()
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
        }
        .task {
            // A freshly built view starts in setup (savedMeeting == nil), so it's
            // not a saved recording until stopRecording() finishes.
            recordingSaved = false
            // The engine is shared app-wide: a setup view opening in another
            // window must not wipe a recording that is live elsewhere or a
            // stopped one whose finalization is still consuming the engine.
            if !appState.isRecording && !transcriptionEngine.isSessionActive {
                transcriptionEngine.reset()
            }
            captureManager.refreshProcessList()
            if let preSelectedProcess {
                captureManager.selectedProcess = preSelectedProcess
            }
        }
        .onDisappear {
            // This instance is leaving the hierarchy (dismissed or rebuilt), so
            // no saved recording is mounted anymore.
            recordingSaved = false
            // If the view is torn down while it owns a session whose pipeline
            // hasn't started (window closed mid-recording, mid-start, or after a
            // capture error), its captureManager dies with it and no pipeline
            // would run. Salvage a real recording by stopping capture and running
            // the normal finalize/save pipeline (its Task outlives this view);
            // otherwise just clear the app-wide flags and release the engine so
            // the menu bar and other windows don't report a phantom recording
            // forever. When the pipeline IS already running (isProcessingNotes),
            // it survives this view and releases the session itself.
            if ownsRecordingSession && !isProcessingNotes {
                // isRecording/isPaused prove capture actually started — salvage
                // even inside the first second (the elapsed timer only ticks at
                // 1s, and the user's setup notes are part of the saved session).
                if isRecording || isPaused {
                    logger.notice("Window closed mid-recording after \(Int(elapsedTime))s — finalizing and saving the session")
                    stopRecording(viewWillPersist: false)
                } else {
                    releaseRecordingSession()
                }
            }
        }
        .onChange(of: captureManager.state) { _, newState in
            if case .recording = newState {
                captureDidStart = true
            }
            // Capture failed to start (or died): isRecording/isPaused turn false
            // so the Stop button is unreachable, yet the flags set optimistically
            // in startRecording() would block every retry and model swap forever.
            // If real audio was captured (e.g. the device died mid-recording or
            // on resume), salvage it through the normal finalize/save pipeline —
            // same policy as a window closing mid-recording; otherwise release
            // the session so the error banner's Retry can start over. Gate on
            // capture having actually reached .recording, not just wall-clock:
            // the timer starts optimistically before Core Audio finishes its
            // async setup, so a slow start-failure has ticks but zero samples.
            if case .error = newState, ownsRecordingSession, !isProcessingNotes {
                if captureDidStart && elapsedTime > 0 {
                    logger.notice("Capture error after \(Int(elapsedTime))s of recording — finalizing and saving the session")
                    stopRecording()
                } else {
                    releaseRecordingSession()
                }
            }
        }
        // Sync local chip selection with Settings changes while still in the setup
        // phase. RecordingView is kept alive behind an opacity layer when the user
        // navigates to Settings, so the @State initializer only runs once — without
        // this, changing the default in Settings would not update the chip.
        .onChange(of: templateSettings.defaultTemplate) { _, newValue in
            if isInSetupPhase {
                selectedTemplate = newValue
            }
        }
        .onChange(of: templateSettings.customInstructions) { _, newValue in
            if isInSetupPhase {
                customInstructions = newValue
            }
        }
        .onChange(of: summaryLanguageSettings.defaultLanguage) { _, newValue in
            if isInSetupPhase {
                selectedSummaryLanguage = newValue
            }
        }
        // Auto-select newly-detected audio sources while the user is in the
        // setup phase. AudioSourceMonitor polls every 3s and publishes
        // `detectedProcess` when an app transitions silent → active; we
        // consume that here so the dropdown updates without requiring the
        // user to re-open the menu.
        .onChange(of: audioMonitor.detectedProcess) { _, newDetection in
            guard let process = newDetection, isInSetupPhase else { return }
            captureManager.refreshProcessList()
            if captureManager.selectedProcess == nil {
                captureManager.selectedProcess = process
            }
            // Consume so the ContentView banner doesn't also offer the same process
            _ = audioMonitor.accept()
        }
    }

    /// True when the user hasn't started (or finished) a recording yet — safe to
    /// pull fresh defaults from Settings.
    private var isInSetupPhase: Bool {
        savedMeeting == nil && !isRecording && !isPaused && !isProcessingNotes
    }

    // MARK: - Phase 1: Setup View (before recording)

    private var setupView: some View {
        VStack(spacing: 0) {
            setupStatusBanner

            setupToolbar
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)

            Divider()

            if selectedTemplate == .custom {
                customInstructionsEditor
                Divider()
            }

            if captureManager.captureMicrophone
                && captureManager.selectedProcess != nil
                && captureManager.isOutputBuiltInSpeaker {
                builtInSpeakerWarning
                Divider()
            }

            NotepadSurface(
                userNotesText: $userNotesText,
                structuredNote: nil,
                placeholderTitle: "Jot down your agenda or questions before the session starts...",
                placeholderSubtitle: "Use # for headings"
            )
        }
    }

    // MARK: - Phase 2: Active Recording View (notepad-dominant)

    private var activeRecordingView: some View {
        VStack(spacing: 0) {
            recordingToolbar
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)

            Divider()

            NotepadSurface(
                userNotesText: $userNotesText,
                structuredNote: nil,
                isEditable: !isProcessingNotes,
                autoFocus: true,
                placeholderTitle: "Type notes as you listen...",
                placeholderSubtitle: "Use # headings to define sections",
                onLineCompleted: { lineText in
                    // Append freely — any duplicate of a seeded setup line is
                    // reconciled when stopRecording() rebuilds from the notepad.
                    timestampedNotes.append(
                        TimestampedNote(timestamp: elapsedTime, text: lineText)
                    )
                }
            )

            if isProcessingNotes {
                Divider()
                processingSection
                    .padding(Spacing.md)
            }

            if showTranscript && !isProcessingNotes {
                Divider()
                liveTranscriptFooter
            }
        }
    }

    // MARK: - Phase 3: Post-Recording View (after stop, enhancement deferred to user)

    @ViewBuilder
    private func postRecordingView(meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            postRecordingToolbar(meeting: meeting)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)

            Divider()

            NotepadSurface(
                userNotesText: $userNotesText,
                structuredNote: meeting.structuredNote,
                isEditable: meeting.structuredNote == nil,
                placeholderTitle: "No notes typed during recording",
                placeholderSubtitle: enhancement.hasAPIKey
                    ? "Click Enhance to generate notes from the transcript"
                    : "Add your \(enhancement.currentProviderDisplayName) API key in Settings to generate notes"
            )
            .overlay {
                if enhancement.isEnhancing(meeting) {
                    SeminarlyColors.background.opacity(0.6)
                        .overlay {
                            VStack(spacing: Spacing.sm) {
                                ProgressView()
                                    .controlSize(.large)
                                Text("Enhancing with transcript...")
                                    .font(Typography.body)
                                    .foregroundStyle(SeminarlyColors.textSecondary)
                            }
                        }
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: userNotesText) { _, newValue in
            guard meeting.structuredNote == nil else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? nil : trimmed
            guard meeting.userNotesText != next else { return }
            meeting.userNotesText = next
            try? modelContext.save()
        }
    }

    private func postRecordingToolbar(meeting: Meeting) -> some View {
        let canEnhance = enhanceButtonEnabled(for: meeting)

        return HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xxs + 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SeminarlyColors.success)
                Text("Recording saved")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                Text(formattedElapsedTime)
                    .font(Typography.mono)
                    .foregroundStyle(SeminarlyColors.textTertiary)
            }

            Spacer()

            if let error = enhancement.error(for: meeting) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.destructive)
                    .lineLimit(1)
            }

            if meeting.structuredNote == nil {
                Button {
                    showRegenerateSheet = true
                } label: {
                    Label("Enhance with Transcript", systemImage: "sparkles")
                        .font(Typography.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs + 2)
                        .background(canEnhance ? SeminarlyColors.accent : SeminarlyColors.textTertiary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canEnhance || enhancement.isEnhancing(meeting))
                .help(enhanceHelpText(for: meeting))
            } else {
                Button {
                    showRegenerateSheet = true
                } label: {
                    Label("Re-enhance", systemImage: "arrow.clockwise")
                        .font(Typography.captionMedium)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canEnhance || enhancement.isEnhancing(meeting))
                .help("Choose template and language, then re-run enhancement")
            }

            Button {
                selectedMeeting = meeting
                onDismiss()
            } label: {
                Text("Done")
                    .font(Typography.captionMedium)
                    .foregroundStyle(SeminarlyColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Close recording and view in detail")
        }
    }

    private func enhanceButtonEnabled(for meeting: Meeting) -> Bool {
        guard let transcript = meeting.transcript,
              !transcript.rawText.isEmpty,
              enhancement.hasAPIKey else { return false }
        return true
    }

    private func enhanceHelpText(for meeting: Meeting) -> String {
        if !enhancement.hasAPIKey { return "Add \(enhancement.currentProviderDisplayName) API key in Settings" }
        if meeting.transcript?.rawText.isEmpty ?? true { return "No transcript available" }
        return "Choose template and language, then generate structured notes"
    }

    private var recordingToolbar: some View {
        HStack(spacing: Spacing.sm) {
            // Recording indicator
            HStack(spacing: Spacing.xxs + 2) {
                Circle()
                    .fill(isPaused ? SeminarlyColors.accent : SeminarlyColors.recording)
                    .frame(width: 8, height: 8)
                    .shadow(color: (isPaused ? SeminarlyColors.accent : SeminarlyColors.recording).opacity(0.5), radius: 4)
                    .opacity(isPaused ? 0.6 : 1.0)
                if isPaused {
                    Text("Paused")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.accent)
                }
                Text(formattedElapsedTime)
                    .font(Typography.mono)
                    .foregroundStyle(SeminarlyColors.textSecondary)
            }

            Spacer()

            // Transcript toggle
            if !isProcessingNotes {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTranscript.toggle()
                    }
                } label: {
                    Image(systemName: showTranscript ? "text.quote.rtl" : "text.quote")
                        .font(.system(size: 14))
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(showTranscript ? "Hide transcript" : "Show transcript")
            }

            // Pause / Resume
            if isRecording {
                Button {
                    pauseRecording()
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SeminarlyColors.accent)
                }
                .buttonStyle(.plain)
                .help("Pause recording")
            } else if isPaused {
                Button {
                    resumeRecording()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SeminarlyColors.recording)
                }
                .buttonStyle(.plain)
                .help("Resume recording")
            }

            // Stop
            if isRecording || isPaused {
                Button {
                    stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Stop recording")
            }
        }
    }

    private var liveTranscriptFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text("Live Transcript")
                    .font(Typography.captionMedium)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.xs)

            ScrollView {
                Text(transcriptionEngine.liveText.isEmpty ? "Waiting for audio..." : transcriptionEngine.liveText)
                    .font(Typography.caption)
                    .foregroundStyle(transcriptionEngine.liveText.isEmpty ? SeminarlyColors.textTertiary : SeminarlyColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: 120)
            .padding(.bottom, Spacing.xs)
        }
        .background(SeminarlyColors.surfaceElevated)
    }

    // MARK: - Setup Toolbar + Chips

    private var setupToolbar: some View {
        HStack(spacing: Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                chipsRow(compact: false)
                chipsRow(compact: true)
            }
            Spacer()
            startRecordingButton
        }
    }

    private func chipsRow(compact: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            micToggleChip(compact: compact)
            audioSourceChip(compact: compact)
            templateChip(compact: compact)
            languageChip(compact: compact)
            summaryLanguageChip(compact: compact)
        }
    }

    private func audioSourceChip(compact: Bool) -> some View {
        Menu {
            Button {
                captureManager.selectedProcess = nil
            } label: {
                Label("None (microphone only)", systemImage: "mic")
            }
            .onAppear { captureManager.refreshProcessList() }

            if !captureManager.availableProcesses.isEmpty {
                Divider()
            }

            ForEach(captureManager.availableProcesses) { process in
                Button {
                    captureManager.selectedProcess = process
                } label: {
                    if process.isRunningOutput {
                        Label(process.name, systemImage: "speaker.wave.2.fill")
                    } else {
                        Text(process.name)
                    }
                }
            }
        } label: {
            chipLabel(
                icon: "waveform",
                text: captureManager.selectedProcess?.name ?? "None",
                compact: compact,
                maxTextWidth: 150
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Audio source: \(captureManager.selectedProcess?.name ?? "None")")
    }

    private func micToggleChip(compact: Bool) -> some View {
        let isOn = captureManager.captureMicrophone
        return Button {
            captureManager.captureMicrophone.toggle()
        } label: {
            chipLabel(
                icon: isOn ? "mic.fill" : "mic.slash",
                text: isOn ? "Mic: On" : "Mic: Off",
                trailingChevron: false,
                isActive: isOn,
                compact: compact
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Include microphone audio alongside system audio (\(isOn ? "On" : "Off"))")
    }

    private func templateChip(compact: Bool) -> some View {
        Menu {
            ForEach(NoteTemplate.allCases) { template in
                Button {
                    selectedTemplate = template
                } label: {
                    Label(template.displayName, systemImage: template.icon)
                }
            }
        } label: {
            chipLabel(icon: selectedTemplate.icon, text: selectedTemplate.displayName, compact: compact)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(selectedTemplate.displayName): \(selectedTemplate.description)")
    }

    private func languageChip(compact: Bool) -> some View {
        Menu {
            ForEach(TranscriptionLanguage.allCases) { lang in
                Button {
                    selectedLanguage = lang
                } label: {
                    if lang == .auto {
                        Text(lang.displayName)
                    } else {
                        Text("\(lang.displayName) (\(lang.nativeName))")
                    }
                }
            }
        } label: {
            chipLabel(icon: "globe", text: selectedLanguage.displayName, compact: compact)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(selectedLanguage == .auto
            ? "Language: auto-detect per chunk"
            : "Language: \(selectedLanguage.displayName)")
    }

    private func summaryLanguageChip(compact: Bool) -> some View {
        Menu {
            Button {
                selectedSummaryLanguage = .matchTranscript
            } label: {
                Text(SummaryLanguage.matchTranscript.displayName)
            }
            Divider()
            ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                Button {
                    selectedSummaryLanguage = lang
                } label: {
                    Text("\(lang.displayName) (\(lang.nativeName))")
                }
            }
            Divider()
            Button {
                showSummaryLanguageCustomEditor = true
            } label: {
                Text("Custom…")
            }
        } label: {
            chipLabel(
                icon: "text.bubble",
                text: "Notes: \(selectedSummaryLanguage.displayName)",
                compact: compact
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(summaryLanguageHelpText)
        .popover(isPresented: $showSummaryLanguageCustomEditor) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Custom note language")
                    .font(Typography.headline)
                TextField("e.g., Korean, Klingon, Latin", text: $summaryLanguageCustomDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { showSummaryLanguageCustomEditor = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Use") {
                        let trimmed = summaryLanguageCustomDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            selectedSummaryLanguage = .custom(trimmed)
                            summaryLanguageSettings.lastCustomLanguage = trimmed
                        }
                        showSummaryLanguageCustomEditor = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(summaryLanguageCustomDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Spacing.md)
        }
    }

    private var summaryLanguageHelpText: String {
        switch selectedSummaryLanguage {
        case .matchTranscript:
            return "Notes language: same as transcript"
        case .custom(let name):
            return "Notes language: \(name)"
        default:
            return "Notes language: \(selectedSummaryLanguage.displayName)"
        }
    }

    private func chipLabel(
        icon: String,
        text: String,
        trailingChevron: Bool = true,
        isActive: Bool = false,
        compact: Bool = false,
        maxTextWidth: CGFloat? = nil
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 11))
            if !compact {
                Text(text)
                    .font(Typography.caption)
                    .lineLimit(1)
                    .frame(maxWidth: maxTextWidth)
                if trailingChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
            }
        }
        .foregroundStyle(isActive ? SeminarlyColors.textPrimary : SeminarlyColors.textSecondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs + 1)
        .background(
            isActive ? SeminarlyColors.accent.opacity(0.15) : SeminarlyColors.surface,
            in: Capsule()
        )
    }

    private var startRecordingButton: some View {
        let (canStart, help) = recordingReadiness
        return Button {
            startRecording()
        } label: {
            Label("Record", systemImage: "record.circle.fill")
                .font(Typography.captionMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs + 2)
                .background(canStart ? SeminarlyColors.recording : SeminarlyColors.textTertiary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!canStart)
        .help(help)
    }

    private var recordingReadiness: (canStart: Bool, help: String) {
        // Engines are shared app-wide — a second window must not start a
        // concurrent recording over a live one, nor over a stopped one whose
        // finalization is still consuming the engine.
        if appState.isRecording || transcriptionEngine.isSessionActive {
            return (false, "A recording is already in progress")
        }
        // A load error only blocks recording when no model is usable — after a
        // failed switch the previous model is restored and keeps working; the
        // error stays visible in the banner (with Retry) as information.
        if let err = transcriptionEngine.errorMessage, !transcriptionEngine.isModelLoaded {
            return (false, err)
        }
        if let err = diarizationEngine.errorMessage { return (false, err) }
        if !transcriptionEngine.isModelLoaded { return (false, "Loading transcription model...") }
        if !diarizationEngine.isModelReady { return (false, "Loading speaker diarization models...") }
        if captureManager.selectedProcess == nil && !captureManager.captureMicrophone {
            return (false, "Select an audio source or enable microphone")
        }
        return (true, "Start recording audio")
    }

    // MARK: - Status Banners

    @ViewBuilder
    private var setupStatusBanner: some View {
        if case .error(let message) = captureManager.state {
            errorBanner(message) { startRecording() }
            Divider()
        } else if let error = transcriptionEngine.errorMessage {
            errorBanner(error) {
                transcriptionEngine.errorMessage = nil
                Task { await transcriptionEngine.loadModel(name: TranscriptionSettings.shared.whisperModel) }
            }
            Divider()
        } else if let error = diarizationEngine.errorMessage {
            errorBanner(error) {
                diarizationEngine.errorMessage = nil
                Task { await diarizationEngine.prepareModels() }
            }
            Divider()
        } else if !transcriptionEngine.isModelLoaded || !diarizationEngine.isModelReady {
            modelLoadingBanner
            Divider()
        }
    }

    private func errorBanner(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(message)
                .font(Typography.caption)
                .lineLimit(1)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(Typography.captionMedium)
                .foregroundStyle(SeminarlyColors.accent)
        }
        .foregroundStyle(SeminarlyColors.destructive)
        .statusBannerBackground()
    }

    private var modelLoadingBanner: some View {
        HStack(spacing: Spacing.xs) {
            if !transcriptionEngine.isDownloading {
                ProgressView().controlSize(.small)
            }
            Text(modelLoadingText)
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.textSecondary)
                .lineLimit(1)
            if transcriptionEngine.isDownloading {
                ProgressView(value: transcriptionEngine.downloadFraction)
                    .tint(SeminarlyColors.accent)
                    .frame(width: 100)
            }
            Spacer()
        }
        .statusBannerBackground()
    }

    private var modelLoadingText: String {
        if transcriptionEngine.isDownloading {
            return "Downloading transcription model (\(Int(transcriptionEngine.downloadFraction * 100))%)..."
        }
        if !transcriptionEngine.isModelLoaded {
            return transcriptionEngine.loadingProgress.isEmpty ? "Loading transcription model..." : transcriptionEngine.loadingProgress
        }
        if !diarizationEngine.isModelReady {
            return diarizationEngine.modelStatus.isEmpty ? "Loading speaker models..." : diarizationEngine.modelStatus
        }
        return ""
    }

    private var builtInSpeakerWarning: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Built-in speakers detected — mic may pick up echo. Use headphones for cleaner separation.")
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .statusBannerBackground()
    }

    private var customInstructionsEditor: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11))
                .foregroundStyle(SeminarlyColors.textSecondary)
            TextField("Custom note generation instructions...", text: $customInstructions)
                .font(Typography.caption)
                .textFieldStyle(.plain)
        }
        .statusBannerBackground()
    }

    @ViewBuilder
    private var processingSection: some View {
        if isProcessingNotes {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Processing")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textSecondary)

                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(processingStatus)
                        .font(Typography.body)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .seminarlyCard()
        }
    }

    // MARK: - Logic

    private var isRecording: Bool {
        if case .recording = captureManager.state { return true }
        return false
    }

    private var isPaused: Bool {
        if case .paused = captureManager.state { return true }
        return false
    }

    private var formattedElapsedTime: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Undo startRecording()'s optimistic claims after the recording can no
    /// longer complete (capture error, or view teardown before the pipeline).
    private func releaseRecordingSession() {
        // Kill live taps AND any capture start still inside its detached Core
        // Audio setup — otherwise a torn-down view can leave capture running
        // headless. Deliberately state-preserving so an .error stays visible.
        captureManager.abortCapture()
        timer?.invalidate()
        timer = nil
        appState.isRecording = false
        appState.isPaused = false
        transcriptionEngine.endSession()
        ownsRecordingSession = false
    }

    private func startRecording() {
        guard !appState.isRecording, !transcriptionEngine.isSessionActive else { return }
        // A failed attempt leaves the capture manager in .error, and its
        // startRecording() silently no-ops unless .idle — reset it first so
        // Retry actually retries instead of claiming flags over dead capture.
        if case .error = captureManager.state {
            _ = captureManager.stopRecording()
        }
        transcriptionEngine.beginSession()
        ownsRecordingSession = true
        captureDidStart = false

        // Preserve any notes the user jotted down during the setup phase rather
        // than wiping them, and seed each non-empty line as a 0:00 entry. This
        // anchors pre-meeting notes at the start of the timeline: stopRecording()
        // rebuilds timestampedNotes from the final notepad and keeps each line's
        // earliest stamp, so a seeded setup line stays at 0:00 even if the user
        // later presses Enter after it (which would otherwise stamp it mid-session).
        let setupLines = userNotesText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        timestampedNotes = setupLines.map { TimestampedNote(timestamp: 0, text: $0) }

        // Apply user-selected language
        transcriptionEngine.selectedLanguage = selectedLanguage.whisperCode
        if let code = selectedLanguage.whisperCode {
            transcriptionEngine.detectedLanguage = code
        }

        captureManager.onAudioSamples = { [weak transcriptionEngine] samples in
            Task { @MainActor in
                transcriptionEngine?.appendAudio(samples)
            }
        }

        captureManager.startRecording()

        elapsedTime = 0
        pausedDuration = 0
        pauseStartTime = nil
        appState.recordingElapsedTime = 0
        appState.isPaused = false
        appState.isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                elapsedTime += 1
                appState.recordingElapsedTime = elapsedTime
                // Checkpoint every 5 minutes during long sessions so the WAL stays
                // small and a forced quit can't lose an entire multi-hour recording.
                if Int(elapsedTime) > 0 && Int(elapsedTime) % 300 == 0 {
                    let ok = DatabaseCheckpoint.performCheckpoint(at: AppDelegate.storeURL, mode: .passive)
                    logger.notice("5-min recording checkpoint fired at elapsed=\(Int(elapsedTime))s success=\(ok, privacy: .public)")
                }
            }
        }
    }

    private func pauseRecording() {
        captureManager.pauseRecording()
        timer?.invalidate()
        timer = nil
        pauseStartTime = Date()
        appState.isPaused = true
    }

    private func resumeRecording() {
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }
        captureManager.resumeRecording()
        appState.isPaused = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                elapsedTime += 1
                appState.recordingElapsedTime = elapsedTime
                if Int(elapsedTime) > 0 && Int(elapsedTime) % 300 == 0 {
                    let ok = DatabaseCheckpoint.performCheckpoint(at: AppDelegate.storeURL, mode: .passive)
                    logger.notice("5-min recording checkpoint fired at elapsed=\(Int(elapsedTime))s success=\(ok, privacy: .public)")
                }
            }
        }
    }

    /// Stop capture and run the finalize/diarize/save pipeline. Pass
    /// `viewWillPersist: false` when this view is being torn down (window
    /// closed mid-recording): the pipeline Task still completes and saves the
    /// meeting, but skips the UI-state writes that only make sense for a
    /// still-mounted view (saved screen, sidebar selection, re-key flag).
    private func stopRecording(viewWillPersist: Bool = true) {
        // Accumulate any final paused duration
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartTime = nil
        }
        timer?.invalidate()
        timer = nil
        appState.isRecording = false
        appState.isPaused = false

        let recording = captureManager.stopRecording()
        let duration = captureManager.recordingDuration - pausedDuration

        logger.info("Recording stopped. Duration: \(String(format: "%.1f", duration))s, systemSamples: \(recording.systemSamples.count), micSamples: \(recording.micSamples?.count ?? 0)")

        isProcessingNotes = true

        // Quitting must wait for this pipeline: the recording exists only in
        // memory until modelContext.save() below.
        AppDelegate.beginSavePipeline()

        Task {
            defer { AppDelegate.endSavePipeline() }

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
            // End-of-recording checkpoint: the session just wrote its transcript,
            // segments, and embeddings — make sure those land in the main store file
            // immediately, so a later crash or forced reboot can't lose them.
            let ok = DatabaseCheckpoint.performCheckpoint(at: AppDelegate.storeURL, mode: .passive)
            logger.notice("End-of-recording checkpoint success=\(ok, privacy: .public)")

            if viewWillPersist {
                // Select the just-saved meeting so the sidebar reflects what's in
                // the detail pane — without this, the previously-selected meeting
                // (if any) stays highlighted until the user clicks Done.
                selectedMeeting = meeting

                isProcessingNotes = false
                savedMeeting = meeting
                // Now in the post-recording (saved) state — let ContentView rebuild
                // this view fresh on the next "Record" instead of re-showing it.
                recordingSaved = true
            }
            // The pipeline has consumed everything it needs from the engine —
            // release it for the next recording (and for deferred model swaps).
            transcriptionEngine.endSession()
            ownsRecordingSession = false
        }
    }

    private func initialRegenerateTemplate(for meeting: Meeting) -> NoteTemplate {
        meeting.structuredNote?.resolvedTemplate ?? selectedTemplate
    }

    private func initialRegenerateLanguage(for meeting: Meeting) -> SummaryLanguage {
        if let note = meeting.structuredNote {
            return SummaryLanguage.fromStorageCode(note.language)
        }
        return selectedSummaryLanguage
    }

    private func detectedSummaryLanguage(for meeting: Meeting) -> SummaryLanguage? {
        guard let transcript = meeting.transcript else {
            return SummaryLanguage.fromLanguageCode(meeting.detectedLanguage)
        }
        return SummaryLanguage.detectTranscriptLanguage(transcript.diarizedText)
    }

    private func applyEnhancementPreferences(template: NoteTemplate, language: SummaryLanguage, meeting: Meeting) {
        selectedTemplate = template
        selectedSummaryLanguage = language
        if case .custom(let name) = language {
            summaryLanguageCustomDraft = name
        }

        meeting.structuredNote = nil
        try? modelContext.save()
        runEnhancement(template: template, summaryLanguage: language)
    }

    /// Runs note enhancement on the saved meeting using the selected preferences
    /// from `RegenerateNotesSheet`.
    private func runEnhancement(template: NoteTemplate, summaryLanguage: SummaryLanguage) {
        guard let meeting = savedMeeting,
              let transcript = meeting.transcript,
              !transcript.rawText.isEmpty,
              enhancement.hasAPIKey else { return }

        let currentNotes = userNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.userNotesText = currentNotes.isEmpty ? nil : currentNotes

        // Persist the raw notes as userNotesText (above), but show the model the
        // timestamped form when we have it — it carries when each note was taken.
        let notesForPrompt: String?
        let mode: String
        if currentNotes.isEmpty {
            notesForPrompt = nil
            mode = "transcript-only"
        } else if let stamps = meeting.timestampedNotes, !stamps.isEmpty {
            notesForPrompt = TimestampedNote.formatForPrompt(stamps)
            mode = "enhance"
        } else {
            notesForPrompt = currentNotes
            mode = "enhance"
        }
        logger.info("Enhancement: mode=\(mode), userNotes=\(currentNotes.count) chars, template=\(template.rawValue)")

        enhancement.enhance(
            meeting: meeting,
            transcript: transcript.diarizedText,
            userNotes: notesForPrompt,
            template: template,
            customInstructions: template == .custom ? customInstructions : nil,
            summaryLanguage: summaryLanguage,
            modelContext: modelContext
        )
    }
}

private extension View {
    /// Wraps a status banner with standard horizontal+vertical padding and surface background.
    func statusBannerBackground() -> some View {
        self.padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(SeminarlyColors.surface)
    }
}
