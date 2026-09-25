import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "RecordingView")

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Binding var selectedMeeting: Meeting?

    @ObservedObject var captureManager: AudioCaptureManager
    @Bindable var session: RecordingSession
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    @ObservedObject var diarizationEngine: NeuralDiarizationEngine

    @ObservedObject private var enhancement = EnhancementCoordinator.shared
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

    @State private var summaryLanguageCustomDraft: String = SummaryLanguageSettings.shared.lastCustomLanguage
    @State private var showSummaryLanguageCustomEditor: Bool = false
    @State private var showRegenerateSheet: Bool = false

    @State private var showTranscript = true

    var body: some View {
        VStack(spacing: 0) {
            if let meeting = session.savedMeeting {
                postRecordingView(meeting: meeting)
            } else if session.isActive || session.isProcessingNotes {
                activeRecordingView
            } else {
                setupView
            }
        }
        .background(SeminarlyColors.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showRegenerateSheet) {
            if let meeting = session.savedMeeting {
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
                            if session.isActive {
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
            // Reopening a window observes the same session; it must never reset
            // the engine, notes, or source selection of a background recording.
            guard session.isInSetupPhase else { return }
            captureManager.refreshProcessList()
            if let preSelectedProcess {
                captureManager.selectedProcess = preSelectedProcess
            }
        }
        .onChange(of: session.savedMeeting?.id, initial: true) { _, _ in
            if let meeting = session.savedMeeting {
                selectedMeeting = meeting
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
        session.isInSetupPhase
    }

    // MARK: - Phase 1: Setup View (before recording)

    private var setupView: some View {
        VStack(spacing: 0) {
            setupStatusBanner

            setupToolbar
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)

            Divider()

            if session.selectedTemplate == .custom {
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
                userNotesText: $session.userNotesText,
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
                userNotesText: $session.userNotesText,
                structuredNote: nil,
                isEditable: !session.isProcessingNotes,
                autoFocus: true,
                placeholderTitle: "Type notes as you listen...",
                placeholderSubtitle: "Use # headings to define sections",
                onLineCompleted: { lineText in
                    // Append freely — any duplicate of a seeded setup line is
                    // reconciled when session.stopRecording() rebuilds from the notepad.
                    session.timestampedNotes.append(
                        TimestampedNote(timestamp: session.elapsedTime, text: lineText)
                    )
                }
            )

            if session.isProcessingNotes {
                Divider()
                processingSection
                    .padding(Spacing.md)
            }

            if showTranscript && !session.isProcessingNotes {
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
                userNotesText: $session.userNotesText,
                structuredNote: meeting.structuredNote,
                isEditable: meeting.structuredNote == nil,
                placeholderTitle: "No notes typed during recording",
                placeholderSubtitle: enhancement.isProviderReady
                    ? "Click Enhance to generate notes from the transcript"
                    : enhancement.providerSetupMessage
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
        .onChange(of: session.userNotesText) { _, newValue in
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
              enhancement.isProviderReady else { return false }
        return true
    }

    private func enhanceHelpText(for meeting: Meeting) -> String {
        if !enhancement.isProviderReady { return enhancement.providerSetupMessage }
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
            if !session.isProcessingNotes {
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
                    session.pauseRecording()
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SeminarlyColors.accent)
                }
                .buttonStyle(.plain)
                .help("Pause recording")
            } else if isPaused {
                Button {
                    session.resumeRecording()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SeminarlyColors.recording)
                }
                .buttonStyle(.plain)
                .help("Resume recording")
            }

            // Stop
            if session.isActive {
                Button {
                    session.stopRecording()
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
                    session.selectedTemplate = template
                } label: {
                    Label(template.displayName, systemImage: template.icon)
                }
            }
        } label: {
            chipLabel(icon: session.selectedTemplate.icon, text: session.selectedTemplate.displayName, compact: compact)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(session.selectedTemplate.displayName): \(session.selectedTemplate.description)")
    }

    private func languageChip(compact: Bool) -> some View {
        Menu {
            ForEach(TranscriptionLanguage.allCases) { lang in
                Button {
                    session.selectedLanguage = lang
                } label: {
                    if lang == .auto {
                        Text(lang.displayName)
                    } else {
                        Text("\(lang.displayName) (\(lang.nativeName))")
                    }
                }
            }
        } label: {
            chipLabel(icon: "globe", text: session.selectedLanguage.displayName, compact: compact)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(session.selectedLanguage == .auto
            ? "Language: auto-detect per chunk"
            : "Language: \(session.selectedLanguage.displayName)")
    }

    private func summaryLanguageChip(compact: Bool) -> some View {
        Menu {
            Button {
                session.selectedSummaryLanguage = .matchTranscript
            } label: {
                Text(SummaryLanguage.matchTranscript.displayName)
            }
            Divider()
            ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                Button {
                    session.selectedSummaryLanguage = lang
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
                text: "Notes: \(session.selectedSummaryLanguage.displayName)",
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
                            session.selectedSummaryLanguage = .custom(trimmed)
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
        switch session.selectedSummaryLanguage {
        case .matchTranscript:
            return "Notes language: same as transcript"
        case .custom(let name):
            return "Notes language: \(name)"
        default:
            return "Notes language: \(session.selectedSummaryLanguage.displayName)"
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
            errorBanner(
                error,
                actionTitle: transcriptionEngine.canRetryModelLoad ? "Retry" : "Dismiss"
            ) {
                if transcriptionEngine.canRetryModelLoad {
                    Task { await transcriptionEngine.retryModelLoad() }
                } else {
                    transcriptionEngine.clearFailure()
                }
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

    private func errorBanner(
        _ message: String,
        actionTitle: String = "Retry",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(message)
                .font(Typography.caption)
                .lineLimit(1)
            Spacer()
            Button(actionTitle, action: action)
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
            TextField("Custom note generation instructions...", text: $session.customInstructions)
                .font(Typography.caption)
                .textFieldStyle(.plain)
        }
        .statusBannerBackground()
    }

    @ViewBuilder
    private var processingSection: some View {
        if session.isProcessingNotes {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Processing")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textSecondary)

                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(session.processingStatus)
                        .font(Typography.body)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .seminarlyCard()
        }
    }

    // MARK: - Logic

    private var isRecording: Bool { session.isRecording }

    private var isPaused: Bool { session.isPaused }

    private var formattedElapsedTime: String {
        let minutes = Int(session.elapsedTime) / 60
        let seconds = Int(session.elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startRecording() {
        session.startRecording(modelContext: modelContext)
    }

    private func initialRegenerateTemplate(for meeting: Meeting) -> NoteTemplate {
        meeting.structuredNote?.resolvedTemplate ?? session.selectedTemplate
    }

    private func initialRegenerateLanguage(for meeting: Meeting) -> SummaryLanguage {
        if let note = meeting.structuredNote {
            return SummaryLanguage.fromStorageCode(note.language)
        }
        return session.selectedSummaryLanguage
    }

    private func detectedSummaryLanguage(for meeting: Meeting) -> SummaryLanguage? {
        guard let transcript = meeting.transcript else {
            return SummaryLanguage.fromLanguageCode(meeting.detectedLanguage)
        }
        return SummaryLanguage.detectTranscriptLanguage(transcript.diarizedText)
    }

    private func applyEnhancementPreferences(template: NoteTemplate, language: SummaryLanguage, meeting: Meeting) {
        session.selectedTemplate = template
        session.selectedSummaryLanguage = language
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
        guard let meeting = session.savedMeeting,
              let transcript = meeting.transcript,
              !transcript.rawText.isEmpty,
              enhancement.isProviderReady else { return }

        let currentNotes = session.userNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.userNotesText = currentNotes.isEmpty ? nil : currentNotes

        // Persist the raw notes as session.userNotesText (above), but show the model the
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
            customInstructions: template == .custom ? session.customInstructions : nil,
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
