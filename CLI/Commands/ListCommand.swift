import ArgumentParser
import Foundation
@preconcurrency import SwiftData

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List sessions, newest first.",
        discussion: """
            Output is JSON by default — one object per session with id, title, date,
            duration, and `has_user_notes` / `has_enhanced_notes` / `has_transcript`
            flags. Pass --table for a plain-text summary.
            """
    )

    @Option(name: .long, help: "Only include sessions on or after this date (YYYY-MM-DD).")
    var since: String?

    @Option(name: .long, help: "Only include sessions on or before this date (YYYY-MM-DD).")
    var until: String?

    @Option(name: .long, help: "Substring match against the session title (case-insensitive).")
    var query: String?

    @Option(name: .long, help: "Maximum number of sessions to return.")
    var limit: Int?

    @Flag(name: .long, help: "Print as a plain-text table instead of JSON.")
    var table: Bool = false

    @MainActor
    func run() async throws {
        let container = try SessionLookup.openReadOnlyContainer()
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        var meetings = try context.fetch(descriptor)

        if let since, let sinceDate = parseDate(since) {
            meetings = meetings.filter { $0.date >= sinceDate }
        }
        if let until, let untilDate = parseDate(until) {
            // Include the entire `until` day.
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: untilDate) ?? untilDate
            meetings = meetings.filter { $0.date < endOfDay }
        }
        if let query {
            meetings = meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if let limit {
            meetings = Array(meetings.prefix(limit))
        }

        if table {
            print(SessionFormatter.listTable(meetings))
        } else {
            print(SessionFormatter.listJSON(meetings))
        }
    }

    private func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
