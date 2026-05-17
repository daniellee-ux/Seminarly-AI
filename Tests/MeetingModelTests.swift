import XCTest
import SwiftData
@testable import Seminarly

final class MeetingModelTests: XCTestCase {

    // MARK: - Meeting property tests

    func testFormattedDuration() {
        let meeting = Meeting(title: "Test", duration: 90)
        XCTAssertEqual(meeting.formattedDuration, "1m 30s")

        let short = Meeting(title: "Short", duration: 45)
        XCTAssertEqual(short.formattedDuration, "45s")

        let zero = Meeting(title: "Zero", duration: 0)
        XCTAssertEqual(zero.formattedDuration, "0s")
    }

    func testFormattedDurationLargeValues() {
        let long = Meeting(title: "Long", duration: 3661)
        XCTAssertEqual(long.formattedDuration, "61m 1s")
    }

    func testFormattedDateIsNotEmpty() {
        let meeting = Meeting(title: "Test", date: Date())
        XCTAssertFalse(meeting.formattedDate.isEmpty)
    }

    func testIsProcessedWithoutNote() {
        let meeting = Meeting(title: "No Note")
        XCTAssertFalse(meeting.isProcessed)
    }

    func testIsProcessedWithNote() {
        let meeting = Meeting(title: "Has Note")
        meeting.structuredNote = StructuredNote(summary: "Summary")
        XCTAssertTrue(meeting.isProcessed)
    }

    func testDefaultValues() {
        let meeting = Meeting()
        XCTAssertEqual(meeting.title, "Untitled Session")
        XCTAssertEqual(meeting.duration, 0)
        XCTAssertNil(meeting.appSource)
        XCTAssertNil(meeting.appBundleID)
        XCTAssertNil(meeting.transcript)
        XCTAssertNil(meeting.structuredNote)
    }

    // MARK: - Cascade deletion tests

    @MainActor
    func testDeletingMeetingCascadesToTranscriptAndNote() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Meeting.self, Transcript.self, StructuredNote.self,
            configurations: config
        )
        let context = container.mainContext

        let meeting = Meeting(title: "Cascade Test")
        let transcript = Transcript(rawText: "Hello world")
        let note = StructuredNote(summary: "Summary")
        meeting.transcript = transcript
        meeting.structuredNote = note
        context.insert(meeting)
        try context.save()

        // Verify all three objects exist
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Meeting>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transcript>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StructuredNote>()), 1)

        // Delete the meeting
        context.delete(meeting)
        try context.save()

        // Verify cascade: all related objects should be deleted
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Meeting>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transcript>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StructuredNote>()), 0)
    }

    // MARK: - StructuredNote property tests

    func testStructuredNoteDefaults() {
        let note = StructuredNote()
        XCTAssertEqual(note.summary, "")
        XCTAssertEqual(note.templateType, NoteTemplate.freeform.rawValue)
        XCTAssertTrue(note.sections.isEmpty)
    }

    func testStructuredNoteWithSections() {
        let sections = [
            NoteSection(key: "keyConcepts", title: "Key Concepts", icon: "lightbulb", items: [NoteItem(text: "Concept A"), NoteItem(text: "Concept B")]),
            NoteSection(key: "definitions", title: "Definitions", icon: "text.book.closed", items: [NoteItem(text: "Term: Definition")]),
        ]
        let note = StructuredNote(
            summary: "Lecture summary",
            templateType: NoteTemplate.lecture.rawValue,
            sections: sections
        )
        XCTAssertEqual(note.summary, "Lecture summary")
        XCTAssertEqual(note.sections.count, 2)
        XCTAssertEqual(note.sections[0].items.count, 2)
        XCTAssertEqual(note.resolvedTemplate, .lecture)
    }

    func testResolvedTemplateFromType() {
        let note = StructuredNote(templateType: NoteTemplate.meeting.rawValue)
        XCTAssertEqual(note.resolvedTemplate, .meeting)

        let podcastNote = StructuredNote(templateType: NoteTemplate.podcast.rawValue)
        XCTAssertEqual(podcastNote.resolvedTemplate, .podcast)
    }

    // MARK: - StructuredNote Data-backed sections round-trip

    func testSectionsRoundTrip() {
        let sections = [
            NoteSection(key: "themes", title: "Themes", icon: "tag", items: [NoteItem(text: "AI"), NoteItem(text: "Machine Learning")]),
            NoteSection(key: "quotes", title: "Quotes", icon: "quote.bubble", items: [NoteItem(text: "\"Hello world\"")]),
        ]
        let note = StructuredNote(summary: "Test", sections: sections)

        // Verify computed getter reads back what was set via init
        XCTAssertEqual(note.sections.count, 2)
        XCTAssertEqual(note.sections[0].key, "themes")
        XCTAssertEqual(note.sections[0].items.map(\.text), ["AI", "Machine Learning"])
        XCTAssertEqual(note.sections[1].key, "quotes")
        XCTAssertEqual(note.sections[1].items.map(\.text), ["\"Hello world\""])
    }

    func testSectionsSetterRoundTrip() {
        let note = StructuredNote(summary: "Empty")
        XCTAssertTrue(note.sections.isEmpty)

        // Set sections via computed setter
        note.sections = [
            NoteSection(key: "key1", title: "Title 1", icon: "star", items: [NoteItem(text: "Item A")]),
        ]
        XCTAssertEqual(note.sections.count, 1)
        XCTAssertEqual(note.sections[0].key, "key1")
        XCTAssertEqual(note.sections[0].items.map(\.text), ["Item A"])

        // Overwrite with new sections
        note.sections = [
            NoteSection(key: "key2", title: "Title 2", icon: "bolt", items: [NoteItem(text: "X"), NoteItem(text: "Y"), NoteItem(text: "Z")]),
            NoteSection(key: "key3", title: "Title 3", icon: "leaf", items: []),
        ]
        XCTAssertEqual(note.sections.count, 2)
        XCTAssertEqual(note.sections[1].items, [])
    }

    @MainActor
    func testSectionsPersistedThroughSwiftData() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Meeting.self, Transcript.self, StructuredNote.self,
            configurations: config
        )
        let context = container.mainContext

        let sections = [
            NoteSection(key: "concepts", title: "Concepts", icon: "lightbulb", items: [NoteItem(text: "A"), NoteItem(text: "B")]),
        ]
        let meeting = Meeting(title: "Persistence Test")
        let note = StructuredNote(summary: "Summary", sections: sections)
        meeting.structuredNote = note
        note.meeting = meeting
        context.insert(meeting)
        try context.save()

        // Fetch back and verify sections survived persistence
        let fetched = try context.fetch(FetchDescriptor<StructuredNote>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].sections.count, 1)
        XCTAssertEqual(fetched[0].sections[0].key, "concepts")
        XCTAssertEqual(fetched[0].sections[0].items.map(\.text), ["A", "B"])
    }

    // MARK: - TimestampedNote Tests

    func testTimestampedNoteEncodeDecode() throws {
        let notes = [
            TimestampedNote(timestamp: 30.0, text: "First point"),
            TimestampedNote(timestamp: 90.5, text: "Second point"),
        ]
        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode([TimestampedNote].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].timestamp, 30.0)
        XCTAssertEqual(decoded[0].text, "First point")
        XCTAssertEqual(decoded[1].timestamp, 90.5)
    }

    func testTimestampedNoteFormattedTimestamp() {
        XCTAssertEqual(TimestampedNote(timestamp: 0, text: "").formattedTimestamp, "00:00")
        XCTAssertEqual(TimestampedNote(timestamp: 65, text: "").formattedTimestamp, "01:05")
        XCTAssertEqual(TimestampedNote(timestamp: 3661, text: "").formattedTimestamp, "61:01")
    }

    func testTimestampedNoteFormatForPrompt() {
        let notes = [
            TimestampedNote(timestamp: 30, text: "Budget discussion"),
            TimestampedNote(timestamp: 125, text: "# Action Items"),
        ]
        let formatted = TimestampedNote.formatForPrompt(notes)
        XCTAssertEqual(formatted, "[00:30] Budget discussion\n[02:05] # Action Items")
    }

    func testMeetingTimestampedNotesRoundTrip() {
        let meeting = Meeting(title: "Test")
        XCTAssertNil(meeting.timestampedNotes)

        let notes = [
            TimestampedNote(timestamp: 10, text: "Hello"),
            TimestampedNote(timestamp: 60, text: "World"),
        ]
        meeting.timestampedNotes = notes

        let loaded = meeting.timestampedNotes
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?[0].text, "Hello")
        XCTAssertEqual(loaded?[1].timestamp, 60)
    }

    func testMeetingTimestampedNotesNilClearsData() {
        let meeting = Meeting(title: "Test")
        meeting.timestampedNotes = [TimestampedNote(timestamp: 5, text: "Note")]
        XCTAssertNotNil(meeting.timestampedNotesData)

        meeting.timestampedNotes = nil
        XCTAssertNil(meeting.timestampedNotesData)
    }

    // MARK: - Session typealias

    func testSessionTypealiasExists() {
        let session: Session = Meeting(title: "Test Session")
        XCTAssertEqual(session.title, "Test Session")
    }
}
