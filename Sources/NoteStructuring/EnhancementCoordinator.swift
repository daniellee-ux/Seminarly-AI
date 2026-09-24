import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "EnhancementCoordinator")

/// App-wide owner of note-enhancement work.
///
/// Enhancement used to be gated by a single `isProcessing` flag on a per-view
/// `NoteStructuringService`. Because the detail pane reuses one view instance
/// across session selections, that flag was effectively global: while one
/// session was enhancing, every other session's "Enhance" button was disabled
/// and a second run was refused. This coordinator instead tracks work *per
/// meeting*, so any number of sessions can enhance at once — each surfaces its
/// own progress and errors — while a single meeting is still de-duplicated.
///
/// The running `Task`s live here rather than in a view, so they keep going (and
/// keep updating the right session) when the user navigates between sessions
/// mid-enhancement. Everything is `@MainActor`: the bodies only suspend inside
/// the provider's network call, then resume on the main actor to mutate the
/// SwiftData models — the same isolation the views used before.
@MainActor
final class EnhancementCoordinator: ObservableObject {
    static let shared = EnhancementCoordinator()

    /// Meetings with an enhancement in flight, keyed by persistent ID. Drives the
    /// per-session progress indicators and disables only that session's own
    /// Enhance button — never the others'.
    @Published private(set) var inFlight: Set<PersistentIdentifier> = []

    /// The most recent failure reason per meeting, surfaced inline. Cleared when a
    /// fresh run starts for that meeting or when one succeeds.
    @Published private(set) var errors: [PersistentIdentifier: String] = [:]

    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var observations: Set<AnyCancellable> = []

    private init() {
        LLMSettings.shared.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        ChatGPTAccountStore.shared.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
    }

    // MARK: - Query

    /// Whether this specific meeting has an enhancement running right now.
    func isEnhancing(_ meeting: Meeting) -> Bool {
        inFlight.contains(meeting.persistentModelID)
    }

    /// The last enhancement error for this meeting, if any.
    func error(for meeting: Meeting) -> String? {
        errors[meeting.persistentModelID]
    }

    var isProviderReady: Bool {
        if LLMSettings.shared.currentDescriptor.kind == .chatGPTPlan { return ChatGPTAccountStore.shared.isReady }
        return KeychainStore.exists(for: LLMSettings.shared.currentDescriptor.keychainAccount)
    }

    var providerSetupMessage: String {
        if LLMSettings.shared.currentDescriptor.kind == .chatGPTPlan {
            return ChatGPTAccountStore.shared.isWorking ? "Checking ChatGPT account…" : "Connect your ChatGPT account in Settings to generate notes"
        }
        return "Add your \(currentProviderDisplayName) API key in Settings to generate notes"
    }

    var currentProviderDisplayName: String {
        LLMSettings.shared.currentDescriptor.displayName
    }

    // MARK: - Run

    /// Starts enhancement for `meeting`. Runs are de-duplicated per meeting — a
    /// second call while this meeting is already in flight is ignored — but
    /// different meetings run concurrently.
    ///
    /// `userNotes` is the note text shown to the model (the caller is responsible
    /// for persisting `meeting.userNotesText`). When it is nil or blank the
    /// transcript is structured directly; otherwise the notes are enhanced with
    /// transcript context. On success the coordinator writes back the generated
    /// title and note and saves; it never touches `userNotesText`.
    func enhance(
        meeting: Meeting,
        transcript: String,
        userNotes: String?,
        template: NoteTemplate,
        customInstructions: String? = nil,
        summaryLanguage: SummaryLanguage,
        modelContext: ModelContext
    ) {
        let id = meeting.persistentModelID
        guard !inFlight.contains(id) else { return }

        let notes = (userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight.insert(id)
        errors[id] = nil

        let task = Task {
            let service = NoteStructuringService()
            let result: (title: String, note: StructuredNote)?
            if notes.isEmpty {
                result = await service.structureTranscript(
                    transcript,
                    template: template,
                    customInstructions: customInstructions,
                    summaryLanguage: summaryLanguage
                )
            } else {
                result = await service.enhanceNotes(
                    userNotes: notes,
                    transcript: transcript,
                    template: template,
                    customInstructions: customInstructions,
                    summaryLanguage: summaryLanguage
                )
            }

            // The run may have been cancelled (e.g. the session was deleted) while
            // the provider call was in flight — don't write back to a stale model.
            guard !Task.isCancelled else {
                self.finish(id)
                return
            }

            if let result {
                meeting.title = result.title
                meeting.structuredNote = result.note
                result.note.meeting = meeting
                try? modelContext.save()
                self.errors[id] = nil
            } else {
                let message = service.errorMessage ?? "Enhancement failed"
                logger.error("Enhancement failed: \(message, privacy: .public)")
                self.errors[id] = message
            }
            self.finish(id)
        }
        tasks[id] = task
    }

    /// Cancels any in-flight enhancement for a meeting and forgets its error.
    /// Call before deleting a session so a completing run can't write to it.
    func cancel(_ meeting: Meeting) {
        let id = meeting.persistentModelID
        tasks[id]?.cancel()
        finish(id)
        errors[id] = nil
    }

    private func finish(_ id: PersistentIdentifier) {
        inFlight.remove(id)
        tasks[id] = nil
    }
}
