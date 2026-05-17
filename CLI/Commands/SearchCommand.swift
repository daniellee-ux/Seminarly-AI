import ArgumentParser
import Foundation
@preconcurrency import SwiftData

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find sessions whose content matches a query (case-insensitive substring).",
        discussion: """
            Returns JSON with id, title, date, location (which field matched), and a
            snippet of surrounding context per hit. `--in` limits the scope to one
            of: all (default), title, notes, transcript.
            """
    )

    @Argument(help: "Search text — case-insensitive substring match.")
    var query: String

    @Option(
        name: [.customLong("in")],
        help: "Where to search: all (default), title, notes, transcript."
    )
    var scope: String = "all"

    @Option(name: .long, help: "Maximum number of results to return.")
    var limit: Int = 20

    @MainActor
    func run() async throws {
        let container = try SessionLookup.openReadOnlyContainer()
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let meetings = try context.fetch(descriptor)

        let matches = SessionFormatter.search(
            query: query,
            scope: scope.lowercased(),
            meetings: meetings,
            limit: limit
        )
        print(SessionFormatter.searchJSON(matches))
    }
}
