import XCTest
@testable import Seminarly

final class NoteStructuringParsingTests: XCTestCase {

    func testParseLectureResponse() throws {
        let json = """
        {
            "title": "Introduction to Calculus",
            "summary": "Covered limits and derivatives.",
            "keyConcepts": ["Limits", "Derivatives"],
            "definitions": ["Limit: the value a function approaches"],
            "examples": ["lim x->0 sin(x)/x = 1"],
            "keyTakeaways": ["Derivatives are limits of difference quotients"],
            "questionsRaised": ["How do improper integrals work?"]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        XCTAssertEqual(decoded.title, "Introduction to Calculus")
        XCTAssertEqual(decoded.summary, "Covered limits and derivatives.")

        let sections = decoded.sections(for: .lecture)
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(sections[0].key, "keyConcepts")
        XCTAssertEqual(sections[0].items.map(\.text), ["Limits", "Derivatives"])
    }

    func testParseMeetingResponse() throws {
        let json = """
        {
            "title": "Q1 Planning",
            "summary": "Discussed priorities.",
            "discussionPoints": ["Revenue targets"],
            "decisions": ["Focus enterprise"],
            "actionItems": ["Hire 2 engineers"],
            "openQuestions": ["Budget?"]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .meeting)
        XCTAssertEqual(sections.count, 4)
        XCTAssertEqual(sections[0].key, "discussionPoints")
    }

    func testParsePodcastResponse() throws {
        let json = """
        {
            "title": "Tech Talk",
            "summary": "Discussion about AI trends.",
            "themes": ["AI Safety"],
            "keyInsights": ["Alignment is key"],
            "notableQuotes": ["The future is agentic"],
            "references": ["Superintelligence by Bostrom"],
            "takeaways": ["Stay informed on AI policy"]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .podcast)
        XCTAssertEqual(sections.count, 5)
    }

    func testEmptySectionsAreFilteredOut() throws {
        let json = """
        {
            "title": "Short",
            "summary": "Brief.",
            "keyConcepts": [],
            "definitions": []
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .lecture)
        XCTAssertEqual(sections.count, 0)
    }

    func testMalformedJSONThrows() {
        let badJSON = "{ not valid json at all"
        let data = badJSON.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TemplatedNoteResponse.self, from: data))
    }

    func testMissingTitleThrows() {
        let json = """
        {
            "summary": "No title field"
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TemplatedNoteResponse.self, from: data))
    }

    func testEnhancedResponseParsesSameAsStandard() throws {
        // Enhancement uses the same JSON format — verify it parses identically
        let json = """
        {
            "title": "Q2 Budget Review",
            "summary": "Budget approved with modifications based on user's notes about Q2 priorities.",
            "discussionPoints": ["Budget allocation for engineering"],
            "decisions": ["Q2 budget approved at $500k"],
            "actionItems": ["Sarah to finalize vendor contracts by March 15"],
            "openQuestions": ["Will the new headcount be approved?"]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        XCTAssertEqual(decoded.title, "Q2 Budget Review")
        let sections = decoded.sections(for: .meeting)
        XCTAssertEqual(sections.count, 4)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = """
        {
            "title": "Test",
            "summary": "Test summary",
            "unknownField": ["value1"],
            "keyConcepts": ["Concept"]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .lecture)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].key, "keyConcepts")
    }

    // MARK: - NoteItem Source Attribution

    func testNoteItemDecodesFromPlainString() throws {
        let json = "\"A plain string item\""
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(NoteItem.self, from: data)
        XCTAssertEqual(item.text, "A plain string item")
        XCTAssertNil(item.source)
        XCTAssertNil(item.transcriptRef)
    }

    func testNoteItemDecodesFromObjectWithSource() throws {
        let json = """
        {"text": "Budget discussed", "source": "user", "transcriptRef": "03:45-04:12"}
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(NoteItem.self, from: data)
        XCTAssertEqual(item.text, "Budget discussed")
        XCTAssertEqual(item.source, .user)
        XCTAssertEqual(item.transcriptRef, "03:45-04:12")
    }

    func testNoteItemDecodesObjectWithoutTranscriptRef() throws {
        let json = """
        {"text": "AI-added insight", "source": "transcript"}
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(NoteItem.self, from: data)
        XCTAssertEqual(item.text, "AI-added insight")
        XCTAssertEqual(item.source, .transcript)
        XCTAssertNil(item.transcriptRef)
    }

    func testEnhancedResponseWithSourceAttribution() throws {
        let json = """
        {
            "title": "Team Standup",
            "summary": "Daily standup covering sprint progress.",
            "discussionPoints": [
                {"text": "Sprint velocity is on track", "source": "user", "transcriptRef": "01:20-02:05"},
                {"text": "Backend migration 80% complete", "source": "transcript", "transcriptRef": "05:30-06:15"}
            ],
            "decisions": [
                {"text": "Ship by Friday", "source": "user"}
            ],
            "actionItems": [
                {"text": "Update staging env — Mike", "source": "transcript", "transcriptRef": "08:00-08:30"}
            ],
            "openQuestions": []
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .meeting)
        XCTAssertEqual(sections.count, 3) // openQuestions empty → filtered out

        // Verify source attribution
        let discussion = sections[0]
        XCTAssertEqual(discussion.items[0].source, .user)
        XCTAssertEqual(discussion.items[0].transcriptRef, "01:20-02:05")
        XCTAssertEqual(discussion.items[1].source, .transcript)
    }

    func testMixedPlainStringAndObjectItems() throws {
        // Claude might return a mix of plain strings and objects in edge cases
        let json = """
        {
            "title": "Mixed",
            "summary": "Test mixed formats.",
            "keyConcepts": [
                "Plain string item",
                {"text": "Object item", "source": "user"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
        let sections = decoded.sections(for: .lecture)
        XCTAssertEqual(sections[0].items.count, 2)
        XCTAssertEqual(sections[0].items[0].text, "Plain string item")
        XCTAssertNil(sections[0].items[0].source)
        XCTAssertEqual(sections[0].items[1].text, "Object item")
        XCTAssertEqual(sections[0].items[1].source, .user)
    }

    // MARK: - Freeform Response Parsing

    func testParseFreeformResponse() throws {
        let json = """
        {
            "title": "Team Sync",
            "summary": "Covered sprint progress and blockers.",
            "topics": [
                {
                    "title": "Sprint Progress",
                    "items": [
                        {
                            "text": "Backend migration is 80% complete",
                            "source": "transcript",
                            "transcriptRef": "01:20-02:05",
                            "children": [
                                {"text": "Auth service done", "source": "transcript"},
                                {"text": "User service in progress", "source": "transcript"}
                            ]
                        },
                        {"text": "Frontend on track", "source": "transcript"}
                    ]
                },
                {
                    "title": "Blockers",
                    "items": [
                        {"text": "Database migration needs review", "source": "transcript", "transcriptRef": "05:30-06:00"}
                    ]
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FreeformNoteResponse.self, from: data)

        XCTAssertEqual(decoded.title, "Team Sync")
        XCTAssertEqual(decoded.topics.count, 2)

        let sections = decoded.sections()
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "Sprint Progress")
        XCTAssertEqual(sections[0].items.count, 2)

        // Verify children on first item
        let firstItem = sections[0].items[0]
        XCTAssertEqual(firstItem.text, "Backend migration is 80% complete")
        XCTAssertEqual(firstItem.children?.count, 2)
        XCTAssertEqual(firstItem.children?[0].text, "Auth service done")

        // Second item has no children
        XCTAssertEqual(sections[0].items[1].text, "Frontend on track")
        XCTAssertNil(sections[0].items[1].children)
    }

    func testFreeformResponseFiltersEmptyTopics() throws {
        let json = """
        {
            "title": "Short Session",
            "summary": "Not much happened.",
            "topics": [
                {"title": "Empty Topic", "items": []},
                {"title": "Real Topic", "items": [{"text": "Something", "source": "transcript"}]}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FreeformNoteResponse.self, from: data)
        let sections = decoded.sections()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Real Topic")
    }

    func testFreeformResponseWithoutChildren() throws {
        // Items without children should decode fine — children is optional
        let json = """
        {
            "title": "Flat",
            "summary": "No nesting.",
            "topics": [
                {"title": "Only Topic", "items": [
                    {"text": "Point 1", "source": "transcript"},
                    {"text": "Point 2", "source": "transcript"}
                ]}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FreeformNoteResponse.self, from: data)
        let sections = decoded.sections()
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].items.count, 2)
        XCTAssertNil(sections[0].items[0].children)
        XCTAssertNil(sections[0].items[1].children)
    }

    func testNoteItemRoundTripsWithChildren() throws {
        let original = NoteItem(
            text: "Parent point",
            source: .transcript,
            transcriptRef: "00:10-00:30",
            children: [
                NoteItem(text: "Child one", source: .transcript),
                NoteItem(text: "Child two", source: .user, transcriptRef: "00:15-00:20")
            ]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteItem.self, from: encoded)
        XCTAssertEqual(decoded.text, "Parent point")
        XCTAssertEqual(decoded.children?.count, 2)
        XCTAssertEqual(decoded.children?[0].text, "Child one")
        XCTAssertEqual(decoded.children?[1].source, .user)
        XCTAssertEqual(decoded.children?[1].transcriptRef, "00:15-00:20")
    }

    func testLegacyNoteItemWithoutChildrenDecodesCleanly() throws {
        // Existing stored JSON (pre-children field) must still decode with children=nil
        let json = """
        {"text": "Legacy item", "source": "user", "transcriptRef": "01:00-01:30"}
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(NoteItem.self, from: data)
        XCTAssertEqual(item.text, "Legacy item")
        XCTAssertEqual(item.source, .user)
        XCTAssertEqual(item.transcriptRef, "01:00-01:30")
        XCTAssertNil(item.children)
    }
}
