import XCTest
import SwiftData
@testable import Seminarly

/// Covers the JSON/table/search logic used by `seminarly-cli`. Builds in-memory
/// fixtures with `Meeting` instances — the same code path the binary runs against,
/// but without actually invoking the binary.
@MainActor
final class SessionFormatterTests: XCTestCase {

    // MARK: - SessionLookup.id

    func testIDIsTwelveHexChars() {
        let m = Meeting(title: "Test", date: Date(timeIntervalSince1970: 1700000000))
        let id = SessionLookup.id(for: m)
        XCTAssertEqual(id.count, 12)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testIDIsStableForSameTitleAndDate() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = Meeting(title: "Test", date: date)
        let b = Meeting(title: "Test", date: date)
        XCTAssertEqual(SessionLookup.id(for: a), SessionLookup.id(for: b))
    }

    func testIDChangesWithTitle() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let a = Meeting(title: "A", date: date)
        let b = Meeting(title: "B", date: date)
        XCTAssertNotEqual(SessionLookup.id(for: a), SessionLookup.id(for: b))
    }

    // MARK: - listJSON

    func testListJSONIncludesCoreFields() throws {
        let m = Meeting(title: "Test", date: Date(timeIntervalSince1970: 1700000000), duration: 1800, appSource: "Zoom")
        let json = SessionFormatter.listJSON([m])
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 1)
        let item = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(item["title"] as? String, "Test")
        XCTAssertEqual(item["app_source"] as? String, "Zoom")
        XCTAssertEqual(item["duration_seconds"] as? Int, 1800)
        XCTAssertNotNil(item["id"] as? String)
        XCTAssertNotNil(item["date"] as? String)
    }

    func testListJSONHasFlagsForEachDataType() throws {
        let m = Meeting(title: "Has all")
        m.userNotesText = "User typed this"
        m.structuredNote = StructuredNote(summary: "S")
        m.transcript = Transcript(rawText: "Hi")

        let json = SessionFormatter.listJSON([m])
        let item = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first)
        XCTAssertEqual(item["has_user_notes"] as? Bool, true)
        XCTAssertEqual(item["has_enhanced_notes"] as? Bool, true)
        XCTAssertEqual(item["has_transcript"] as? Bool, true)
    }

    func testListJSONFlagsFalseWhenMissing() throws {
        let m = Meeting(title: "Empty")
        let json = SessionFormatter.listJSON([m])
        let item = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first)
        XCTAssertEqual(item["has_user_notes"] as? Bool, false)
        XCTAssertEqual(item["has_enhanced_notes"] as? Bool, false)
        XCTAssertEqual(item["has_transcript"] as? Bool, false)
    }

    func testListJSONUserNotesFlagFalseForWhitespaceOnly() throws {
        let m = Meeting(title: "Whitespace notes")
        m.userNotesText = "   \n\n   "
        let json = SessionFormatter.listJSON([m])
        let item = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first)
        XCTAssertEqual(item["has_user_notes"] as? Bool, false)
    }

    // MARK: - listTable

    func testListTableHeaderAndRow() {
        let m = Meeting(title: "Sync with Alice", date: Date(timeIntervalSince1970: 1700000000), duration: 1800)
        let out = SessionFormatter.listTable([m])
        XCTAssertTrue(out.contains("ID"))
        XCTAssertTrue(out.contains("DATE"))
        XCTAssertTrue(out.contains("DURATION"))
        XCTAssertTrue(out.contains("TITLE"))
        XCTAssertTrue(out.contains("Sync with Alice"))
        XCTAssertTrue(out.contains("30m 0s"))
    }

    func testListTableEmpty() {
        XCTAssertTrue(SessionFormatter.listTable([]).contains("no sessions"))
    }

    // MARK: - getJSON

    func testGetJSONIncludesMarkdownField() throws {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(summary: "Hello")
        let json = SessionFormatter.getJSON(m, options: .agentDefault)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let md = try XCTUnwrap(dict["markdown"] as? String)
        XCTAssertTrue(md.contains("# Test"))
        XCTAssertTrue(md.contains("Hello"))
    }

    // MARK: - Search

    func testSearchMatchesInTitle() {
        let m = Meeting(title: "Q3 OKR review")
        let matches = SessionFormatter.search(query: "OKR", scope: "all", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].location, "title")
        XCTAssertTrue(matches[0].snippet.contains("OKR"))
    }

    func testSearchMatchesInUserNotes() {
        let m = Meeting(title: "Test")
        m.userNotesText = "Need to follow up on the hiring loop"
        let matches = SessionFormatter.search(query: "hiring", scope: "all", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].location, "user-notes")
    }

    func testSearchMatchesInEnhancedNotes() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(
            summary: "Discussed Q3 hiring plan",
            sections: [
                NoteSection(key: "actions", title: "Action Items", icon: "checklist", items: [
                    NoteItem(text: "Schedule loop with candidate")
                ])
            ]
        )
        let matches = SessionFormatter.search(query: "candidate", scope: "all", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].location, "enhanced-notes")
    }

    func testSearchMatchesInTranscript() {
        let m = Meeting(title: "Test")
        m.transcript = Transcript(rawText: "Alice said we should hire more engineers.")
        let matches = SessionFormatter.search(query: "engineers", scope: "all", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].location, "transcript")
    }

    func testSearchScopeLimitsToTitleOnly() {
        let m = Meeting(title: "Sync with Alice")
        m.transcript = Transcript(rawText: "discussed Alice's promotion")
        let matches = SessionFormatter.search(query: "Alice", scope: "title", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].location, "title")
    }

    func testSearchIsCaseInsensitive() {
        let m = Meeting(title: "TEST IN UPPERCASE")
        let matches = SessionFormatter.search(query: "uppercase", scope: "all", meetings: [m], limit: 10)
        XCTAssertEqual(matches.count, 1)
    }

    func testSearchRespectsLimit() {
        let one = Meeting(title: "alpha")
        let two = Meeting(title: "alpha-2")
        let three = Meeting(title: "alpha-3")
        let matches = SessionFormatter.search(query: "alpha", scope: "all", meetings: [one, two, three], limit: 2)
        XCTAssertEqual(matches.count, 2)
    }

    func testSnippetContainsContextEllipsesWhenTruncated() {
        let haystack = String(repeating: "padding text ", count: 20) + "MATCH" + String(repeating: " padding text", count: 20)
        let snippet = SessionFormatter.findSnippet(of: "match", in: haystack)
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet?.hasPrefix("...") ?? false)
        XCTAssertTrue(snippet?.hasSuffix("...") ?? false)
        XCTAssertTrue(snippet?.contains("MATCH") ?? false)
    }

    func testSnippetReturnsNilWhenNoMatch() {
        XCTAssertNil(SessionFormatter.findSnippet(of: "needle", in: "no match here"))
    }

    // MARK: - Read-only container (smoke test)

    func testOpenReadOnlyContainerOnTempStoreSucceeds() throws {
        // Verify the read-only container init signature works with a temp on-disk file.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seminarly-cli-test-\(UUID().uuidString).store")
        defer {
            for f in DatabaseStore.relatedFiles(for: tmpURL) {
                try? FileManager.default.removeItem(at: f)
            }
        }

        let schema = Schema([Meeting.self, Transcript.self, StructuredNote.self])
        // Seed: open writable once, insert a meeting, save, close.
        do {
            let cfg = ModelConfiguration(schema: schema, url: tmpURL)
            let container = try ModelContainer(for: schema, configurations: [cfg])
            let ctx = ModelContext(container)
            ctx.insert(Meeting(title: "Fixture", date: Date(timeIntervalSince1970: 1700000000)))
            try ctx.save()
        }

        // Re-open read-only by simulating what SessionLookup does.
        let cfg = ModelConfiguration(
            schema: schema,
            url: tmpURL,
            allowsSave: false,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let ctx = ModelContext(container)
        let fixtures = try ctx.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(fixtures.count, 1)
        XCTAssertEqual(fixtures.first?.title, "Fixture")
    }
}
