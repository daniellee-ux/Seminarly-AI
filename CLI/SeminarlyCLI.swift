import ArgumentParser
import Foundation

@main
struct SeminarlyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seminarly-cli",
        abstract: "Read Seminarly session data — user notes, enhanced notes, and transcripts — for coding agents.",
        discussion: """
            All commands open the local SwiftData store read-only. Works whether the
            Seminarly app is running or not. No network calls.

            Use `list` to discover available session IDs, then `get <id>` to read one.
            Pass --help on any subcommand for full options.
            """,
        version: "0.1.0",
        subcommands: [ListCommand.self, GetCommand.self, SearchCommand.self, PathCommand.self]
    )
}
