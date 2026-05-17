import Foundation
@preconcurrency import SwiftData

/// JSON / table formatters for the CLI's subcommands. Kept separate from the
/// ArgumentParser command structs so the rendering logic can be unit-tested
/// without touching ArgumentParser.
@MainActor
enum SessionFormatter {

    // MARK: - DTOs (snake_case keys via JSONEncoder.keyEncodingStrategy)

    struct SessionListItem: Encodable, Sendable {
        let id: String
        let title: String
        let date: String
        let durationSeconds: Int
        let durationFormatted: String
        let appSource: String?
        let hasUserNotes: Bool
        let hasEnhancedNotes: Bool
        let hasTranscript: Bool
    }

    struct SessionDetail: Encodable, Sendable {
        let id: String
        let title: String
        let date: String
        let durationSeconds: Int
        let appSource: String?
        let markdown: String
    }

    struct SearchMatch: Encodable, Sendable {
        let id: String
        let title: String
        let date: String
        let location: String
        let snippet: String
    }

    // MARK: - Public formatters

    static func listJSON(_ meetings: [Meeting]) -> String {
        encode(meetings.map(listItem(for:)))
    }

    static func listTable(_ meetings: [Meeting]) -> String {
        if meetings.isEmpty { return "(no sessions)\n" }

        var out = "ID            DATE                       DURATION  TITLE\n"
        for m in meetings {
            let id = SessionLookup.id(for: m).padding(toLength: 12, withPad: " ", startingAt: 0)
            let date = iso8601(m.date).padding(toLength: 26, withPad: " ", startingAt: 0)
            let dur = m.formattedDuration.padding(toLength: 9, withPad: " ", startingAt: 0)
            out += "\(id)  \(date)  \(dur) \(m.title)\n"
        }
        return out
    }

    static func getJSON(_ meeting: Meeting, options: MeetingMarkdownRenderer.Options) -> String {
        let detail = SessionDetail(
            id: SessionLookup.id(for: meeting),
            title: meeting.title,
            date: iso8601(meeting.date),
            durationSeconds: Int(meeting.duration),
            appSource: meeting.appSource,
            markdown: MeetingMarkdownRenderer.render(meeting, options: options)
        )
        return encode(detail)
    }

    static func searchJSON(_ matches: [SearchMatch]) -> String {
        encode(matches)
    }

    // MARK: - Search

    /// In-memory grep over each meeting's title / user notes / enhanced notes /
    /// transcript. Returns up to `limit` matches across all scopes. `scope` is one
    /// of "all", "title", "notes", "transcript" — anything else is treated as "all".
    static func search(query: String, scope: String, meetings: [Meeting], limit: Int) -> [SearchMatch] {
        let needle = query.lowercased()
        let wantTitle = (scope == "all" || scope == "title")
        let wantNotes = (scope == "all" || scope == "notes")
        let wantTranscript = (scope == "all" || scope == "transcript")

        var results: [SearchMatch] = []
        outer: for m in meetings {
            if wantTitle, let snippet = findSnippet(of: needle, in: m.title) {
                results.append(makeMatch(m: m, location: "title", snippet: snippet))
                if results.count >= limit { break outer }
            }
            if wantNotes {
                if let userNotes = m.userNotesText,
                   let snippet = findSnippet(of: needle, in: userNotes) {
                    results.append(makeMatch(m: m, location: "user-notes", snippet: snippet))
                    if results.count >= limit { break outer }
                }
                if let note = m.structuredNote {
                    let combined = note.summary + "\n" + note.sections
                        .flatMap { $0.items.map(\.text) }
                        .joined(separator: "\n")
                    if let snippet = findSnippet(of: needle, in: combined) {
                        results.append(makeMatch(m: m, location: "enhanced-notes", snippet: snippet))
                        if results.count >= limit { break outer }
                    }
                }
            }
            if wantTranscript,
               let transcript = m.transcript,
               let snippet = findSnippet(of: needle, in: transcript.rawText) {
                results.append(makeMatch(m: m, location: "transcript", snippet: snippet))
                if results.count >= limit { break outer }
            }
        }
        return results
    }

    // MARK: - Helpers

    private static func listItem(for m: Meeting) -> SessionListItem {
        let userNotesPresent = (m.userNotesText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (m.timestampedNotes?.isEmpty == false)
        return SessionListItem(
            id: SessionLookup.id(for: m),
            title: m.title,
            date: iso8601(m.date),
            durationSeconds: Int(m.duration),
            durationFormatted: m.formattedDuration,
            appSource: m.appSource,
            hasUserNotes: userNotesPresent,
            hasEnhancedNotes: m.structuredNote != nil,
            hasTranscript: (m.transcript?.rawText.isEmpty == false)
        )
    }

    private static func makeMatch(m: Meeting, location: String, snippet: String) -> SearchMatch {
        SearchMatch(
            id: SessionLookup.id(for: m),
            title: m.title,
            date: iso8601(m.date),
            location: location,
            snippet: snippet
        )
    }

    /// 40 chars of context on each side of the first match, with "..." when truncated.
    /// Match is case-insensitive; the returned snippet preserves the source's casing.
    static func findSnippet(of needle: String, in haystack: String) -> String? {
        let lower = haystack.lowercased()
        guard let range = lower.range(of: needle) else { return nil }
        let startIdx = haystack.index(range.lowerBound, offsetBy: -40, limitedBy: haystack.startIndex) ?? haystack.startIndex
        let endIdx = haystack.index(range.upperBound, offsetBy: 40, limitedBy: haystack.endIndex) ?? haystack.endIndex
        var snippet = String(haystack[startIdx..<endIdx])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if startIdx != haystack.startIndex { snippet = "..." + snippet }
        if endIdx != haystack.endIndex { snippet = snippet + "..." }
        return snippet
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\":\"encode failed: \(error.localizedDescription)\"}"
        }
    }

    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
