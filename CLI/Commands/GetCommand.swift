import ArgumentParser
import Foundation
@preconcurrency import SwiftData

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one session as Markdown (default) or JSON.",
        discussion: """
            ID comes from `list` output, or the literal `latest` to pick the most
            recent session.

            By default the Markdown includes all three data types (user notes,
            enhanced notes, transcript) with `[user]` / `[transcript]` source tags
            inside enhanced notes so an agent can distinguish them. Restrict with
            --include or hide tags with --no-source-tags.
            """
    )

    @Argument(help: "Session ID from `list` output, or 'latest' for the most recent.")
    var id: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Comma-separated parts to include.",
            discussion: "Choose any of: user-notes, enhanced-notes, transcript. Default is all three."
        )
    )
    var include: String = "user-notes,enhanced-notes,transcript"

    @Flag(name: .long, help: "Hide [user] / [transcript] source tags inside enhanced notes.")
    var noSourceTags: Bool = false

    @Option(name: .long, help: "Output format: md (default) or json.")
    var format: String = "md"

    @MainActor
    func run() async throws {
        let container = try SessionLookup.openReadOnlyContainer()
        let context = ModelContext(container)

        let meeting: Meeting
        if id.lowercased() == "latest" {
            guard let m = try SessionLookup.latest(in: context) else {
                throw ValidationError("No sessions found.")
            }
            meeting = m
        } else {
            guard let m = try SessionLookup.find(id: id, in: context) else {
                throw ValidationError("No session with id '\(id)'. Run `list` to see available IDs.")
            }
            meeting = m
        }

        let options = parseOptions()

        switch format.lowercased() {
        case "md":
            print(MeetingMarkdownRenderer.render(meeting, options: options))
        case "json":
            print(SessionFormatter.getJSON(meeting, options: options))
        default:
            throw ValidationError("Unknown format '\(format)'. Use 'md' or 'json'.")
        }
    }

    private func parseOptions() -> MeetingMarkdownRenderer.Options {
        let parts = include
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return MeetingMarkdownRenderer.Options(
            includeUserNotes: parts.contains("user-notes"),
            includeEnhancedNotes: parts.contains("enhanced-notes"),
            includeTranscript: parts.contains("transcript"),
            showSourceTags: !noSourceTags
        )
    }
}
