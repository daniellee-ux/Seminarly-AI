import CryptoKit
import Foundation
@preconcurrency import SwiftData

/// Read-only helpers for opening the Seminarly SwiftData store and looking up
/// sessions by their short, human-friendly ID.
@MainActor
enum SessionLookup {

    /// Open the SwiftData store at `DatabaseStore.storeURL` in read-only mode.
    /// `allowsSave: false` prevents writes; `cloudKitDatabase: .none` disables sync.
    static func openReadOnlyContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, Transcript.self, StructuredNote.self])
        let config = ModelConfiguration(
            schema: schema,
            url: DatabaseStore.storeURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Short, stable-ish ID derived from the meeting's date + title. 12 hex chars
    /// (48 bits) keeps collisions astronomically unlikely for any realistic library
    /// while staying short enough to paste. Recomputed each `list`, so renaming a
    /// session shifts its ID — the agent re-fetches `list` before `get` anyway.
    static func id(for meeting: Meeting) -> String {
        let raw = "\(meeting.date.timeIntervalSince1970)|\(meeting.title)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Find a meeting by the short ID. O(n) — fine for typical libraries.
    static func find(id needle: String, in context: ModelContext) throws -> Meeting? {
        let all = try context.fetch(FetchDescriptor<Meeting>())
        return all.first { id(for: $0) == needle }
    }

    /// Fetch the most recent session by date, or nil if the store is empty.
    static func latest(in context: ModelContext) throws -> Meeting? {
        var descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
