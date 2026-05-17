import XCTest
@testable import Seminarly

@MainActor
final class MeetingMarkdownRendererTests: XCTestCase {

    // MARK: - Header

    func testRendersTitle() {
        let m = Meeting(title: "Q3 Planning")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.hasPrefix("# Q3 Planning\n\n"))
    }

    func testIncludesDateAndDuration() {
        let m = Meeting(title: "Test", duration: 65)
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("**Date**:"))
        XCTAssertTrue(md.contains("**Duration**: 1m 5s"))
    }

    func testIncludesAppSourceWhenPresent() {
        let m = Meeting(title: "Test", appSource: "Zoom")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("**Source**: Zoom"))
    }

    func testOmitsAppSourceWhenAbsent() {
        let m = Meeting(title: "Test")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("**Source**"))
    }

    // MARK: - Enhanced notes

    func testRendersSummaryAndSections() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(
            summary: "Brief overview",
            sections: [
                NoteSection(key: "concepts", title: "Key Concepts", icon: "lightbulb", items: [
                    NoteItem(text: "Concept A"),
                    NoteItem(text: "Concept B"),
                ])
            ]
        )
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("## Summary\n\nBrief overview"))
        XCTAssertTrue(md.contains("## Key Concepts"))
        XCTAssertTrue(md.contains("- Concept A"))
        XCTAssertTrue(md.contains("- Concept B"))
    }

    func testRendersNestedChildrenWithIndent() {
        let m = Meeting(title: "Test")
        let parent = NoteItem(text: "Parent", children: [
            NoteItem(text: "Child A"),
            NoteItem(text: "Child B", children: [
                NoteItem(text: "Grandchild")
            ])
        ])
        m.structuredNote = StructuredNote(sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [parent])
        ])
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("- Parent\n"))
        XCTAssertTrue(md.contains("  - Child A\n"))
        XCTAssertTrue(md.contains("  - Child B\n"))
        XCTAssertTrue(md.contains("    - Grandchild\n"))
    }

    func testOmitsEnhancedNotesWhenStructuredNoteAbsent() {
        let m = Meeting(title: "Test")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("## Summary"))
    }

    func testOmitsSummaryHeadingWhenSummaryEmpty() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(summary: "", sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [NoteItem(text: "A")])
        ])
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertTrue(md.contains("## Topics"))
    }

    // MARK: - Source tags

    func testSourceTagsAppearWhenEnabled() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [
                NoteItem(text: "From user", source: .user),
                NoteItem(text: "From transcript", source: .transcript),
                NoteItem(text: "Legacy item"),
            ])
        ])
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertTrue(md.contains("- [user] From user"))
        XCTAssertTrue(md.contains("- [transcript] From transcript"))
        XCTAssertTrue(md.contains("- Legacy item"))
        XCTAssertFalse(md.contains("[user] Legacy item"))
    }

    func testSourceTagsHiddenByDefault() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [
                NoteItem(text: "From user", source: .user)
            ])
        ])
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("[user]"))
        XCTAssertTrue(md.contains("- From user"))
    }

    func testTranscriptRefAppendedAsParenthetical() {
        let m = Meeting(title: "Test")
        m.structuredNote = StructuredNote(sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [
                NoteItem(text: "Discussed Q3 OKRs", transcriptRef: "03:45-04:12")
            ])
        ])
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("- Discussed Q3 OKRs (03:45-04:12)"))
    }

    // MARK: - User notes

    func testIncludesPlainUserNotesWhenEnabled() {
        let m = Meeting(title: "Test")
        m.userNotesText = "These are my notes"
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertTrue(md.contains("## User Notes\n\nThese are my notes"))
    }

    func testIncludesTimestampedNotesAsBullets() {
        let m = Meeting(title: "Test")
        m.timestampedNotes = [
            TimestampedNote(timestamp: 30, text: "First point"),
            TimestampedNote(timestamp: 125, text: "Second point"),
        ]
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertTrue(md.contains("## User Notes"))
        XCTAssertTrue(md.contains("- [00:30] First point"))
        XCTAssertTrue(md.contains("- [02:05] Second point"))
    }

    func testTimestampedNotesPreferredOverRawWhenBothPresent() {
        let m = Meeting(title: "Test")
        m.userNotesText = "Plain text version"
        m.timestampedNotes = [TimestampedNote(timestamp: 10, text: "Stamped version")]
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertTrue(md.contains("- [00:10] Stamped version"))
        XCTAssertFalse(md.contains("Plain text version"))
    }

    func testIncludesUserNotesByDefault() {
        let m = Meeting(title: "Test")
        m.userNotesText = "Notes"
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("## User Notes\n\nNotes"))
    }

    func testCanExcludeUserNotesViaExplicitOption() {
        let m = Meeting(title: "Test")
        m.userNotesText = "Notes"
        let options = MeetingMarkdownRenderer.Options(includeUserNotes: false)
        let md = MeetingMarkdownRenderer.render(m, options: options)
        XCTAssertFalse(md.contains("## User Notes"))
    }

    func testInAppExportHidesSourceTagsEvenWithUserNotes() {
        let m = Meeting(title: "Test")
        m.userNotesText = "User typed this"
        m.structuredNote = StructuredNote(sections: [
            NoteSection(key: "k", title: "Topics", icon: "tag", items: [
                NoteItem(text: "From transcript", source: .transcript)
            ])
        ])
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("## User Notes"))
        XCTAssertFalse(md.contains("[transcript]"), "Source tags should stay off in the in-app default")
    }

    func testOmitsUserNotesWhenAbsent() {
        let m = Meeting(title: "Test")
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertFalse(md.contains("## User Notes"))
    }

    func testOmitsUserNotesWhenOnlyWhitespace() {
        let m = Meeting(title: "Test")
        m.userNotesText = "   \n\n  "
        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)
        XCTAssertFalse(md.contains("## User Notes"))
    }

    // MARK: - Transcript

    func testRendersDiarizedTranscript() {
        let m = Meeting(title: "Test")
        m.transcript = Transcript(
            rawText: "Hello world",
            segments: [
                TranscriptSegment(startTime: 0, endTime: 2, text: "Hello", speaker: "Speaker 1"),
                TranscriptSegment(startTime: 2, endTime: 4, text: "World", speaker: "Speaker 2"),
            ]
        )
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("[00:00] Speaker 1: Hello"))
        XCTAssertTrue(md.contains("[00:02] Speaker 2: World"))
    }

    func testRendersRawTranscriptWhenNoSegments() {
        let m = Meeting(title: "Test")
        m.transcript = Transcript(rawText: "Plain text only")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertTrue(md.contains("## Transcript\n\nPlain text only"))
    }

    func testOmitsTranscriptWhenAbsent() {
        let m = Meeting(title: "Test")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("## Transcript"))
    }

    func testOmitsTranscriptWhenEmpty() {
        let m = Meeting(title: "Test")
        m.transcript = Transcript(rawText: "")
        let md = MeetingMarkdownRenderer.render(m)
        XCTAssertFalse(md.contains("## Transcript"))
    }

    func testOmitsTranscriptWhenIncludeFalse() {
        let m = Meeting(title: "Test")
        m.transcript = Transcript(rawText: "Some content")
        let options = MeetingMarkdownRenderer.Options(
            includeUserNotes: false,
            includeEnhancedNotes: false,
            includeTranscript: false,
            showSourceTags: false
        )
        let md = MeetingMarkdownRenderer.render(m, options: options)
        XCTAssertFalse(md.contains("## Transcript"))
    }

    // MARK: - End-to-end shape

    func testAgentDefaultIncludesAllThreeDataTypes() {
        let m = Meeting(title: "Sync with Alice", duration: 1800, appSource: "Zoom")
        m.userNotesText = "Need to follow up on hiring plan"
        m.structuredNote = StructuredNote(
            summary: "Discussed Q3 hiring and team direction",
            sections: [
                NoteSection(key: "actions", title: "Action Items", icon: "checklist", items: [
                    NoteItem(text: "Schedule loop with candidate", source: .user),
                    NoteItem(text: "Send offer letter by Friday", source: .transcript, transcriptRef: "12:30"),
                ])
            ]
        )
        m.transcript = Transcript(
            rawText: "Alice: We should hire two more engineers.",
            segments: [
                TranscriptSegment(startTime: 0, endTime: 3, text: "We should hire two more engineers.", speaker: "Alice"),
            ]
        )

        let md = MeetingMarkdownRenderer.render(m, options: .agentDefault)

        XCTAssertTrue(md.contains("# Sync with Alice"))
        XCTAssertTrue(md.contains("**Source**: Zoom"))
        XCTAssertTrue(md.contains("## User Notes"))
        XCTAssertTrue(md.contains("Need to follow up on hiring plan"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("Discussed Q3 hiring"))
        XCTAssertTrue(md.contains("## Action Items"))
        XCTAssertTrue(md.contains("- [user] Schedule loop with candidate"))
        XCTAssertTrue(md.contains("- [transcript] Send offer letter by Friday (12:30)"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("Alice: We should hire two more engineers"))
    }
}
