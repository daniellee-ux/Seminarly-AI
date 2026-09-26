import SwiftUI
import SwiftData

struct MeetingSpeakerControls: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var meeting: Meeting
    @State private var selectedCount = 2
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var processingTask: Task<Void, Never>?
    @State private var operationID: UUID?

    private var segments: [TranscriptSegment] { meeting.transcript?.segments ?? [] }

    private var speakers: [(id: String, name: String)] {
        var seen: Set<String> = []
        return segments.compactMap {
            guard let id = SpeakerAttribution.identity(of: $0), let name = $0.speaker,
                  seen.insert(id).inserted else { return nil }
            return (id, name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Speakers")
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                Spacer()
                if meeting.hasRediarizationData {
                    Button(role: .destructive, action: deleteVoiceData) {
                        Image(systemName: "trash").font(Typography.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SeminarlyColors.textTertiary)
                    .help("Delete rediarization data")
                }
            }

            Text("Total speakers, including you")
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.textSecondary)
            HStack(spacing: Spacing.sm) {
                Picker("Total speakers", selection: $selectedCount) {
                    ForEach(1...max(6, max(speakers.count, selectedCount)), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(minWidth: 200, maxWidth: 280)

                Button(action: rediarize) {
                    if isProcessing {
                        HStack(spacing: Spacing.xxs) {
                            ProgressView().controlSize(.small)
                            Text("Identifying speakers…").font(Typography.caption)
                        }
                    } else {
                        Label("Rediarize", systemImage: "person.2.wave.2").font(Typography.caption)
                    }
                }
                .disabled(segments.isEmpty || (!meeting.hasRediarizationData && selectedCount != 1))
            }

            if meeting.originalSegmentsData != nil {
                Button(action: restoreOriginal) {
                    Label("Restore Original", systemImage: "arrow.uturn.backward").font(Typography.caption)
                }
                .disabled(meeting.transcript?.segmentsData == meeting.originalSegmentsData)
            }

            if !speakers.isEmpty {
                Text("Current: \(speakers.map(\.name).joined(separator: ", "))")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textTertiary)
                Picker("Your voice", selection: Binding(
                    get: {
                        segments.first(where: { $0.isUser == true && $0.speaker == "You" })
                            .flatMap { SpeakerAttribution.identity(of: $0) } ?? ""
                    },
                    set: { identifyUser($0.isEmpty ? nil : $0) }
                )) {
                    Text("Not identified").tag("")
                    ForEach(speakers, id: \.id) { speaker in
                        Text(speaker.name).tag(speaker.id)
                    }
                }
                .frame(maxWidth: 320)
                .help("Choose the speaker who is you. This changes their name, not the total number of speakers.")
            }

            if meeting.hasLegacySpeakerEvidence {
                Text("This older recording cannot reliably separate people who shared the microphone. Check the speaker labels before choosing your voice.")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
            }
            if let resultMessage {
                Text(resultMessage).font(Typography.caption).foregroundStyle(SeminarlyColors.textSecondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.destructive)
            }
        }
        .disabled(isProcessing)
        .seminarlyCard()
        .onAppear(perform: resetSelection)
        .onChange(of: meeting.persistentModelID) { _, _ in
            processingTask?.cancel()
            operationID = nil
            isProcessing = false
            errorMessage = nil
            resultMessage = nil
            resetSelection()
        }
        .onDisappear {
            processingTask?.cancel()
            operationID = nil
            isProcessing = false
        }
    }

    private func resetSelection() { selectedCount = max(1, speakers.count) }

    private func identifyUser(_ id: String?) {
        saveSegments(SpeakerAttribution.identifyUser(in: segments, speakerID: id))
        resultMessage = nil
    }

    private func restoreOriginal() {
        guard meeting.originalSegmentsData != nil else { return }
        let original = meeting.rediarizationSegments
        let restored = original.contains(where: { $0.isUser != nil })
            ? SpeakerAttribution.displayNames(for: original) : original
        saveSegments(restored)
        resetSelection()
        resultMessage = nil
    }

    private func saveSegments(_ updated: [TranscriptSegment]) {
        guard let transcript = meeting.transcript else { return }
        let previous = transcript.segmentsData
        transcript.segments = updated
        do {
            try modelContext.save()
            errorMessage = nil
        } catch {
            transcript.segmentsData = previous
            errorMessage = error.localizedDescription
        }
    }

    private func rediarize() {
        guard let transcript = meeting.transcript else { return }
        let targetMeeting = meeting
        let targetID = meeting.persistentModelID
        let previousData = transcript.segmentsData
        let input = meeting.rediarizationSegments
        let embeddings = meeting.speakerEmbeddings
        let count = selectedCount
        let operation = UUID()
        operationID = operation
        errorMessage = nil
        resultMessage = nil
        isProcessing = true

        processingTask = Task { @MainActor in
            defer {
                if operationID == operation {
                    isProcessing = false
                    operationID = nil
                }
            }
            do {
                let updated: [TranscriptSegment]
                var newEmbeddings: [SpeakerEmbedding]?
                if count == 1 || embeddings?.isEmpty == false {
                    updated = try await Task.detached(priority: .userInitiated) {
                        try NeuralDiarizationEngine.rediarizeFromEmbeddings(
                            segments: input, speakerEmbeddings: embeddings ?? [], numSpeakers: count
                        )
                    }.value
                } else if let audio = targetMeeting.loadAudio() {
                    let result = try await NeuralDiarizationEngine.shared.rediarize(
                        segments: input, systemSamples: audio.system, micSamples: audio.mic,
                        numSpeakers: count, detectedLanguage: targetMeeting.detectedLanguage
                    )
                    updated = result.segments
                    newEmbeddings = result.speakerEmbeddings
                } else {
                    throw SpeakerAttributionError.missingEmbeddings
                }
                try Task.checkCancellation()
                guard operationID == operation, meeting.persistentModelID == targetID else { return }
                // Another window may have changed this transcript while processing.
                guard transcript.segmentsData == previousData else {
                    errorMessage = "The transcript changed while identifying speakers. Please try again."
                    return
                }
                let previousEmbeddings = targetMeeting.speakerEmbeddingsData
                transcript.segments = updated
                if let newEmbeddings { targetMeeting.speakerEmbeddings = newEmbeddings }
                do { try modelContext.save() } catch {
                    transcript.segmentsData = previousData
                    targetMeeting.speakerEmbeddingsData = previousEmbeddings
                    throw error
                }
                let actual = Set(updated.compactMap(\.speaker)).count
                let unknown = updated.filter { $0.speaker == nil }.count
                var messages: [String] = []
                if actual < count { messages.append("Identified \(actual) of the requested \(count) speakers.") }
                if unknown > 0 { messages.append("\(unknown) transcript segments could not be assigned a speaker.") }
                if updated.contains(where: { $0.isUser == true }) && !updated.contains(where: { $0.speaker == "You" }) {
                    messages.append("Your voice could not be matched confidently. Choose it again if needed.")
                }
                resultMessage = messages.isEmpty ? nil : messages.joined(separator: " ")
            } catch is CancellationError {
                // Leaving the session cancels publication of this result.
            } catch {
                if meeting.persistentModelID == targetID { errorMessage = error.localizedDescription }
            }
        }
    }

    private func deleteVoiceData() {
        meeting.deleteAudioFiles()
        meeting.systemAudioPath = nil
        meeting.micAudioPath = nil
        meeting.speakerEmbeddingsData = nil
        meeting.originalSegmentsData = nil
        meeting.originalSpeakerCount = nil
        do { try modelContext.save() } catch { errorMessage = error.localizedDescription }
    }
}
