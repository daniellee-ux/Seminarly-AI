import SwiftUI
import SwiftData

struct MeetingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var meeting: Meeting
    @StateObject private var noteService = NoteStructuringService()
    @State private var selectedTab = 0
    @State private var isEditing = false
    @State private var editedTitle: String = ""
    @State private var selectedSpeakerCount: Int = 2
    @State private var isRediarizing = false
    @State private var rediarizeStatus = ""
    @State private var editableUserNotes: String = ""
    @State private var showRegenerateSheet = false
    @State private var processingMeeting: Meeting?
    @State private var errorMeeting: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            meetingHeader
                .padding(Spacing.md)

            Divider()

            HStack(spacing: Spacing.sm) {
                tabButton("Notes", systemImage: "doc.text", tag: 0)
                tabButton("Transcript", systemImage: "text.quote", tag: 1)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)

            Group {
                if selectedTab == 0 {
                    structuredNotesTab
                } else {
                    transcriptTab
                }
            }
            .padding(Spacing.md)
        }
        .background(SeminarlyColors.background)
        .sheet(isPresented: $showRegenerateSheet) {
            RegenerateNotesSheet(
                initialTemplate: meeting.structuredNote?.resolvedTemplate ?? TemplateSettings.shared.defaultTemplate,
                initialLanguage: SummaryLanguage.fromStorageCode(meeting.structuredNote?.language),
                detectedLanguage: detectedSummaryLanguage
            ) { template, language in
                regenerateNotes(template: template, language: language)
            }
        }
    }

    private func tabButton(_ title: String, systemImage: String, tag: Int) -> some View {
        Button {
            selectedTab = tag
        } label: {
            Label(title, systemImage: systemImage)
                .font(Typography.captionMedium)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTab == tag ? SeminarlyColors.textPrimary : SeminarlyColors.textTertiary)
        .background(selectedTab == tag ? SeminarlyColors.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                if isEditing {
                    TextField("Session title", text: $editedTitle, onCommit: {
                        meeting.title = editedTitle
                        isEditing = false
                        try? modelContext.save()
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.largeTitle)
                } else {
                    Text(meeting.title)
                        .font(Typography.largeTitle)
                        .foregroundStyle(SeminarlyColors.textPrimary)
                    Button {
                        editedTitle = meeting.title
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(Typography.caption)
                            .foregroundStyle(SeminarlyColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit title")
                }
                Spacer()
            }

            HStack(spacing: Spacing.md) {
                Label(meeting.formattedDate, systemImage: "calendar")
                Label(meeting.formattedDuration, systemImage: "clock")
                if let source = meeting.appSource {
                    Label(source, systemImage: "app")
                }

                Spacer()

                if meeting.transcript != nil && meeting.structuredNote == nil && noteService.hasAPIKey {
                    Button {
                        enhanceSmart()
                    } label: {
                        Label("Enhance with Transcript", systemImage: "sparkles")
                            .font(Typography.captionMedium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs + 2)
                            .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(noteService.isProcessing)
                }

                if meeting.transcript != nil && meeting.structuredNote != nil {
                    Button {
                        showRegenerateSheet = true
                    } label: {
                        Label("Regenerate", systemImage: "sparkles")
                            .font(Typography.caption)
                            .foregroundStyle(SeminarlyColors.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(noteService.isProcessing || !noteService.hasAPIKey)
                    .help("Regenerate notes with a different template or language")
                }

                Menu {
                    Button("Export as Markdown") {
                        exportMarkdown()
                    }
                    Button("Copy to Clipboard") {
                        copyToClipboard()
                    }
                } label: {
                    Label("Export", systemImage: "arrow.up.doc")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.accent)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }
            .font(Typography.caption)
            .foregroundStyle(SeminarlyColors.textSecondary)

            if isGeneratingCurrentMeeting {
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating notes...")
                        .font(Typography.body)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
            }
            if let error = currentGenerationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SeminarlyColors.destructive)
                    .font(Typography.caption)
            }
        }
    }

    private var structuredNotesTab: some View {
        NotepadSurface(
            userNotesText: $editableUserNotes,
            structuredNote: meeting.structuredNote,
            isEditable: meeting.structuredNote == nil,
            placeholderTitle: "No notes typed during recording",
            placeholderSubtitle: placeholderSubtitle,
            onTranscriptRefTap: { _ in selectedTab = 1 }
        )
        .onAppear {
            syncEditableUserNotes(with: meeting)
        }
        .onChange(of: meeting) { _, newMeeting in
            syncEditableUserNotes(with: newMeeting)
        }
        .onChange(of: editableUserNotes) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? nil : trimmed
            guard meeting.userNotesText != next else { return }
            meeting.userNotesText = next
            try? modelContext.save()
        }
    }

    private var placeholderSubtitle: String? {
        if !noteService.hasAPIKey {
            return "Add your \(noteService.currentProviderDisplayName) API key in Settings to generate notes"
        }
        if meeting.transcript == nil || meeting.transcript?.rawText.isEmpty == true {
            return "No transcript available"
        }
        return "Add notes and click Enhance, or use Regenerate to create notes from the transcript"
    }

    private var isGeneratingCurrentMeeting: Bool {
        guard let processingMeeting else { return false }
        return noteService.isProcessing && processingMeeting == meeting
    }

    private var currentGenerationError: String? {
        guard let errorMeeting, errorMeeting == meeting else { return nil }
        return noteService.errorMessage
    }

    private func syncEditableUserNotes(with targetMeeting: Meeting) {
        editableUserNotes = targetMeeting.userNotesText ?? ""
    }

    private var transcriptTab: some View {
        ScrollView {
            if let transcript = meeting.transcript {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if meeting.hasRediarizationData {
                        speakerControls
                    }

                    if transcript.segments.isEmpty {
                        Text(transcript.rawText)
                            .font(Typography.body)
                            .foregroundStyle(SeminarlyColors.textPrimary)
                            .textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                                TranscriptSegmentRow(segment: segment)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SeminarlyEmptyState(
                    symbol: "text.quote",
                    title: "No transcript available"
                )
            }
        }
        .onAppear {
            let speakers = Set(meeting.transcript?.segments.compactMap(\.speaker) ?? [])
            selectedSpeakerCount = max(speakers.count, 2)
        }
    }

    private var speakerControls: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text("Speakers")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textSecondary)

                Spacer()

                Button(role: .destructive) {
                    meeting.deleteAudioFiles()
                    meeting.systemAudioPath = nil
                    meeting.micAudioPath = nil
                    meeting.speakerEmbeddingsData = nil
                    meeting.originalSegmentsData = nil
                    meeting.originalSpeakerCount = nil
                    try? modelContext.save()
                } label: {
                    Image(systemName: "trash")
                        .font(Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SeminarlyColors.textTertiary)
                .help("Delete rediarization data")
            }

            HStack(spacing: Spacing.sm) {
                Picker("", selection: $selectedSpeakerCount) {
                    ForEach(1...6, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if selectedSpeakerCount == meeting.originalSpeakerCount,
                   meeting.originalSegmentsData != nil {
                    Button {
                        restoreOriginal()
                    } label: {
                        Label("Restore Original", systemImage: "arrow.uturn.backward")
                            .font(Typography.caption)
                    }
                    .disabled(meeting.transcript?.segmentsData == meeting.originalSegmentsData)
                } else {
                    Button {
                        rediarize(numSpeakers: selectedSpeakerCount)
                    } label: {
                        if isRediarizing {
                            HStack(spacing: Spacing.xxs) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(rediarizeStatus)
                                    .font(Typography.caption)
                            }
                        } else {
                            Label("Rediarize", systemImage: "person.2.wave.2")
                                .font(Typography.caption)
                        }
                    }
                    .disabled(isRediarizing)
                }
            }

            let currentSpeakers = Set(meeting.transcript?.segments.compactMap(\.speaker) ?? [])
            if !currentSpeakers.isEmpty {
                Text("Current: \(currentSpeakers.sorted().joined(separator: ", "))")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textTertiary)
            }
        }
        .seminarlyCard()
    }

    /// Smart enhance: uses enhanceUserNotes() when user has typed notes, otherwise
    /// falls back to regenerateNotes() (transcript-only structuring).
    private func enhanceSmart() {
        let notes = editableUserNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            regenerateNotes(
                template: TemplateSettings.shared.defaultTemplate,
                language: SummaryLanguageSettings.shared.defaultLanguage
            )
        } else {
            enhanceUserNotes()
        }
    }

    private func enhanceUserNotes() {
        guard !noteService.isProcessing,
              let transcript = meeting.transcript else { return }
        let notes = editableUserNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }
        let targetMeeting = meeting
        let targetTranscript = transcript

        let template = targetMeeting.structuredNote?.resolvedTemplate ?? TemplateSettings.shared.defaultTemplate
        // Inherit the existing note's language if already generated; otherwise fall
        // back to the user's default. This keeps re-enhance idempotent in language.
        let language: SummaryLanguage = targetMeeting.structuredNote.flatMap {
            SummaryLanguage.fromStorageCode($0.language)
        } ?? SummaryLanguageSettings.shared.defaultLanguage

        beginNoteGeneration(for: targetMeeting)
        Task {
            defer { endNoteGeneration(for: targetMeeting) }
            if let result = await noteService.enhanceNotes(
                userNotes: notes,
                transcript: targetTranscript.diarizedText,
                template: template,
                summaryLanguage: language
            ) {
                targetMeeting.title = result.title
                targetMeeting.structuredNote = result.note
                result.note.meeting = targetMeeting
                targetMeeting.userNotesText = notes
                try? modelContext.save()
            }
        }
    }

    private func restoreOriginal() {
        guard let transcript = meeting.transcript,
              let originalData = meeting.originalSegmentsData else { return }
        transcript.segmentsData = originalData
        try? modelContext.save()
    }

    private func rediarize(numSpeakers: Int) {
        guard let transcript = meeting.transcript else { return }

        isRediarizing = true

        if let embeddings = meeting.speakerEmbeddings {
            rediarizeStatus = "Re-clustering speakers..."
            Task {
                let newSegments = NeuralDiarizationEngine.rediarizeFromEmbeddings(
                    segments: transcript.segments,
                    speakerEmbeddings: embeddings,
                    numSpeakers: numSpeakers
                )
                transcript.segments = newSegments
                try? modelContext.save()
                isRediarizing = false
                rediarizeStatus = ""
            }
        } else if let audio = meeting.loadAudio() {
            rediarizeStatus = "Loading models..."
            Task {
                let engine = NeuralDiarizationEngine()
                await engine.prepareModels()
                rediarizeStatus = "Re-identifying speakers..."
                let newSegments = await engine.rediarize(
                    segments: transcript.segments,
                    systemSamples: audio.system,
                    micSamples: audio.mic,
                    numSpeakers: numSpeakers
                )
                transcript.segments = newSegments
                try? modelContext.save()
                isRediarizing = false
                rediarizeStatus = ""
            }
        } else {
            isRediarizing = false
        }
    }

    private var detectedSummaryLanguage: SummaryLanguage? {
        guard let transcript = meeting.transcript else {
            return SummaryLanguage.fromLanguageCode(meeting.detectedLanguage)
        }
        return SummaryLanguage.detectTranscriptLanguage(transcript.diarizedText)
    }

    private func regenerateNotes(template: NoteTemplate, language: SummaryLanguage) {
        guard !noteService.isProcessing,
              let transcript = meeting.transcript else { return }
        let notes = editableUserNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetMeeting = meeting
        let targetTranscript = transcript

        beginNoteGeneration(for: targetMeeting)
        Task {
            defer { endNoteGeneration(for: targetMeeting) }
            let result: (title: String, note: StructuredNote)?
            if notes.isEmpty {
                result = await noteService.structureTranscript(
                    targetTranscript.diarizedText,
                    template: template,
                    summaryLanguage: language
                )
            } else {
                result = await noteService.enhanceNotes(
                    userNotes: notes,
                    transcript: targetTranscript.diarizedText,
                    template: template,
                    summaryLanguage: language
                )
            }
            guard let result else { return }
            targetMeeting.title = result.title
            targetMeeting.structuredNote = result.note
            result.note.meeting = targetMeeting
            if !notes.isEmpty {
                targetMeeting.userNotesText = notes
            }
            try? modelContext.save()
        }
    }

    private func beginNoteGeneration(for targetMeeting: Meeting) {
        processingMeeting = targetMeeting
        errorMeeting = nil
    }

    private func endNoteGeneration(for targetMeeting: Meeting) {
        if let current = processingMeeting, current == targetMeeting {
            processingMeeting = nil
        }

        if noteService.errorMessage == nil {
            if let current = errorMeeting, current == targetMeeting {
                errorMeeting = nil
            }
        } else {
            errorMeeting = targetMeeting
        }
    }

    private func exportMarkdown() {
        let md = MeetingMarkdownRenderer.render(meeting)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meeting.title).md"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? md.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func copyToClipboard() {
        let md = MeetingMarkdownRenderer.render(meeting)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

struct RegenerateNotesSheet: View {
    let initialTemplate: NoteTemplate
    let initialLanguage: SummaryLanguage
    let detectedLanguage: SummaryLanguage?
    let onApply: (NoteTemplate, SummaryLanguage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var template: NoteTemplate
    @State private var languageSelection: SummaryLanguage
    @State private var customDraft: String

    init(
        initialTemplate: NoteTemplate,
        initialLanguage: SummaryLanguage,
        detectedLanguage: SummaryLanguage? = nil,
        onApply: @escaping (NoteTemplate, SummaryLanguage) -> Void
    ) {
        self.initialTemplate = initialTemplate
        self.initialLanguage = initialLanguage
        self.detectedLanguage = detectedLanguage
        self.onApply = onApply
        _template = State(initialValue: initialTemplate)

        // Map a stored .custom into the picker's sentinel + draft so the field
        // shows up prefilled when the sheet opens for an existing custom note.
        if case .custom(let name) = initialLanguage {
            _languageSelection = State(initialValue: .custom(""))
            _customDraft = State(initialValue: name.isEmpty
                ? SummaryLanguageSettings.shared.lastCustomLanguage
                : name)
        } else {
            _languageSelection = State(initialValue: initialLanguage)
            _customDraft = State(initialValue: SummaryLanguageSettings.shared.lastCustomLanguage)
        }
    }

    private var isCustomSelected: Bool {
        if case .custom = languageSelection { return true }
        return false
    }

    private var resolvedLanguage: SummaryLanguage {
        if case .custom = languageSelection {
            let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .matchTranscript : .custom(trimmed)
        }
        return languageSelection
    }

    private var canApply: Bool {
        if case .custom = languageSelection {
            return !customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Regenerate Notes")
                .font(Typography.headline)

            Form {
                Picker("Template", selection: $template) {
                    ForEach(NoteTemplate.allCases) { t in
                        Label(t.displayName, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.menu)

                Picker("Language", selection: $languageSelection) {
                    Text(SummaryLanguage.matchTranscript.displayName)
                        .tag(SummaryLanguage.matchTranscript)
                    Divider()
                    ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                        Text("\(lang.displayName) (\(lang.nativeName))").tag(lang)
                    }
                    Divider()
                    Text("Custom…").tag(SummaryLanguage.custom(""))
                }
                .pickerStyle(.menu)

                if languageSelection == .matchTranscript, let detectedLanguage {
                    Text("Detected: \(detectedLanguage.displayName)")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                if isCustomSelected {
                    TextField("e.g., Korean, Klingon, Latin", text: $customDraft)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let resolved = resolvedLanguage
                    if case .custom(let name) = resolved {
                        SummaryLanguageSettings.shared.lastCustomLanguage = name
                    }
                    onApply(template, resolved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
        .padding(Spacing.md)
        .frame(minWidth: 360)
    }
}

struct BulletPoint: View {
    let item: NoteItem
    var onTranscriptRefTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                // Bullet color: accent for user-sourced, subtle for AI/transcript
                Circle()
                    .fill(bulletColor.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    // Text color: primary (black) for user-sourced, secondary (gray) for AI
                    Text(item.text)
                        .font(Typography.body)
                        .foregroundStyle(textColor)

                    // Transcript reference badge
                    if let ref = item.transcriptRef {
                        Button {
                            onTranscriptRefTap?(ref)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                Text(ref)
                                    .font(Typography.caption)
                            }
                            .foregroundStyle(SeminarlyColors.accent.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let children = item.children, !children.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(children, id: \.self) { child in
                        ChildBulletPoint(item: child, onTranscriptRefTap: onTranscriptRefTap)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    /// User-sourced or legacy (nil) → primary text, AI-sourced → secondary (gray)
    private var textColor: Color {
        item.source == .transcript ? SeminarlyColors.textSecondary : SeminarlyColors.textPrimary
    }

    private var bulletColor: Color {
        item.source == .transcript ? SeminarlyColors.textSecondary : SeminarlyColors.accent
    }
}

/// Sub-bullet renderer used inside `BulletPoint` for the Freeform template's
/// one level of nesting. Hollow circle glyph differentiates from main bullets.
struct ChildBulletPoint: View {
    let item: NoteItem
    var onTranscriptRefTap: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Circle()
                .strokeBorder(bulletColor.opacity(0.5), lineWidth: 1)
                .frame(width: 4, height: 4)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(Typography.body)
                    .foregroundStyle(textColor)

                if let ref = item.transcriptRef {
                    Button {
                        onTranscriptRefTap?(ref)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(ref)
                                .font(Typography.caption)
                        }
                        .foregroundStyle(SeminarlyColors.accent.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var textColor: Color {
        item.source == .transcript ? SeminarlyColors.textSecondary : SeminarlyColors.textPrimary
    }

    private var bulletColor: Color {
        item.source == .transcript ? SeminarlyColors.textSecondary : SeminarlyColors.accent
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(formattedTime)
                .font(Typography.mono)
                .foregroundStyle(SeminarlyColors.textTertiary)
                .frame(width: 50, alignment: .trailing)

            if let speaker = segment.speaker {
                let identity = SpeakerPalette.identity(for: speaker)
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: identity.shape)
                        .font(.system(size: 8))
                        .foregroundStyle(identity.color)
                    Text(identity.label)
                        .font(Typography.captionMedium)
                        .foregroundStyle(identity.color)
                }
                .frame(width: 60, alignment: .leading)
                .accessibilityLabel("\(speaker)")
            }

            Text(segment.text)
                .font(Typography.body)
                .foregroundStyle(SeminarlyColors.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var formattedTime: String {
        let mins = Int(segment.startTime) / 60
        let secs = Int(segment.startTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
