import Foundation

/// Renders a `Meeting` (session) to Markdown. Pure function — no SwiftUI, no UI state.
///
/// Used by both the in-app Export → Markdown / Copy to Clipboard buttons and the
/// `seminarly-cli` tool. Options let the CLI surface user notes and source tags
/// without changing the visible in-app export.
enum MeetingMarkdownRenderer {

    struct Options: Sendable {
        var includeUserNotes: Bool
        var includeEnhancedNotes: Bool
        var includeTranscript: Bool
        var showSourceTags: Bool

        init(
            includeUserNotes: Bool = true,
            includeEnhancedNotes: Bool = true,
            includeTranscript: Bool = true,
            showSourceTags: Bool = false
        ) {
            self.includeUserNotes = includeUserNotes
            self.includeEnhancedNotes = includeEnhancedNotes
            self.includeTranscript = includeTranscript
            self.showSourceTags = showSourceTags
        }

        /// Used by the in-app Export and Copy to Clipboard buttons. Includes
        /// user-typed notes (the user almost always wants what they wrote in the
        /// exported file) but omits the agent-only `[user]` / `[transcript]`
        /// source tags to keep the output clean for human consumption.
        static let inAppExport = Options()

        /// Everything an agent might want: all three data types plus inline source
        /// tags so `[user]` / `[transcript]` items can be distinguished.
        static let agentDefault = Options(
            includeUserNotes: true,
            includeEnhancedNotes: true,
            includeTranscript: true,
            showSourceTags: true
        )
    }

    @MainActor
    static func render(_ meeting: Meeting, options: Options = .inAppExport) -> String {
        var md = "# \(meeting.title)\n\n"
        md += "**Date**: \(meeting.formattedDate)\n"
        md += "**Duration**: \(meeting.formattedDuration)\n"
        if let source = meeting.appSource {
            md += "**Source**: \(source)\n"
        }
        md += "\n"

        if options.includeUserNotes {
            md += renderUserNotes(meeting)
        }
        if options.includeEnhancedNotes {
            md += renderEnhancedNotes(meeting, showSourceTags: options.showSourceTags)
        }
        if options.includeTranscript {
            md += renderTranscript(meeting)
        }

        return md
    }

    // MARK: - Sections

    @MainActor
    private static func renderUserNotes(_ meeting: Meeting) -> String {
        let stamped = meeting.timestampedNotes ?? []
        if !stamped.isEmpty {
            var md = "## User Notes\n\n"
            for note in stamped {
                md += "- [\(note.formattedTimestamp)] \(note.text)\n"
            }
            return md + "\n"
        }
        let raw = meeting.userNotesText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "" }
        return "## User Notes\n\n\(raw)\n\n"
    }

    @MainActor
    private static func renderEnhancedNotes(_ meeting: Meeting, showSourceTags: Bool) -> String {
        guard let note = meeting.structuredNote else { return "" }
        var md = ""
        if !note.summary.isEmpty {
            md += "## Summary\n\n\(note.summary)\n\n"
        }
        for section in note.sections {
            md += "## \(section.title)\n\n"
            for item in section.items {
                md += renderItem(item, depth: 0, showSourceTags: showSourceTags)
            }
            md += "\n"
        }
        return md
    }

    private static func renderItem(_ item: NoteItem, depth: Int, showSourceTags: Bool) -> String {
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)- "
        if showSourceTags, let source = item.source {
            line += "[\(source.rawValue)] "
        }
        line += item.text
        if let ref = item.transcriptRef {
            line += " (\(ref))"
        }
        line += "\n"
        if let children = item.children {
            for child in children {
                line += renderItem(child, depth: depth + 1, showSourceTags: showSourceTags)
            }
        }
        return line
    }

    @MainActor
    private static func renderTranscript(_ meeting: Meeting) -> String {
        guard let transcript = meeting.transcript, !transcript.rawText.isEmpty else { return "" }
        var md = "## Transcript\n\n"
        if transcript.segments.isEmpty {
            md += transcript.rawText + "\n"
        } else {
            md += transcript.diarizedText + "\n"
        }
        return md
    }
}
