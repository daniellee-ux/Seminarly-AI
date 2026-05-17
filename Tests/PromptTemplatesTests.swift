import XCTest
@testable import Seminarly

final class PromptTemplatesTests: XCTestCase {

    func testSystemPromptIsNotEmptyForAllTemplates() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.systemPrompt(for: template)
            XCTAssertFalse(prompt.isEmpty, "System prompt empty for \(template.rawValue)")
        }
    }

    func testStructureNotesContainsTranscript() {
        let transcript = "Alice said hello. Bob said goodbye."
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.structureNotes(transcript: transcript, template: template)
            XCTAssertTrue(prompt.contains(transcript), "Transcript missing for \(template.rawValue)")
        }
    }

    func testLectureTemplateContainsExpectedFields() {
        let prompt = PromptTemplates.structureNotes(transcript: "test", template: .lecture)
        let expectedKeys = ["keyConcepts", "definitions", "examples", "connections", "keyTakeaways", "questionsRaised"]
        for key in expectedKeys {
            XCTAssertTrue(prompt.contains("\"\(key)\""), "Lecture prompt missing key: \(key)")
        }
    }

    func testMeetingTemplateContainsExpectedFields() {
        let prompt = PromptTemplates.structureNotes(transcript: "test", template: .meeting)
        let expectedKeys = ["discussionPoints", "decisions", "actionItems", "openQuestions"]
        for key in expectedKeys {
            XCTAssertTrue(prompt.contains("\"\(key)\""), "Meeting prompt missing key: \(key)")
        }
    }

    func testStudyGuideTemplateContainsExpectedFields() {
        let prompt = PromptTemplates.structureNotes(transcript: "test", template: .studyGuide)
        let expectedKeys = ["topics", "keyPoints", "questionsAndAnswers", "practiceProblems", "memoryAids", "furtherStudy"]
        for key in expectedKeys {
            XCTAssertTrue(prompt.contains("\"\(key)\""), "Study guide prompt missing key: \(key)")
        }
    }

    func testPodcastTemplateContainsExpectedFields() {
        let prompt = PromptTemplates.structureNotes(transcript: "test", template: .podcast)
        let expectedKeys = ["guestBackground", "themes", "keyInsights", "notableQuotes", "references", "takeaways"]
        for key in expectedKeys {
            XCTAssertTrue(prompt.contains("\"\(key)\""), "Podcast prompt missing key: \(key)")
        }
    }

    func testCustomInstructionsIncluded() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test",
            template: .custom,
            customInstructions: "Focus on vocabulary words"
        )
        XCTAssertTrue(prompt.contains("Focus on vocabulary words"))
    }

    func testAllTemplatesContainTitleAndSummaryFields() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.structureNotes(transcript: "test", template: template)
            XCTAssertTrue(prompt.contains("\"title\""), "Missing title for \(template.rawValue)")
            XCTAssertTrue(prompt.contains("\"summary\""), "Missing summary for \(template.rawValue)")
        }
    }

    // MARK: - Enhancement Prompt Tests

    func testEnhanceWithUserNotesContainsBothInputs() {
        let userNotes = "Budget was approved for Q2"
        let transcript = "Alice said the budget looks good. Bob agreed."
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: userNotes,
            transcript: transcript,
            template: .meeting
        )
        XCTAssertTrue(prompt.contains(userNotes), "Enhancement prompt missing user notes")
        XCTAssertTrue(prompt.contains(transcript), "Enhancement prompt missing transcript")
    }

    func testEnhanceWithUserNotesContainsTemplateFields() {
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: "test notes",
            transcript: "test transcript",
            template: .meeting
        )
        let expectedKeys = ["discussionPoints", "decisions", "actionItems", "openQuestions"]
        for key in expectedKeys {
            XCTAssertTrue(prompt.contains("\"\(key)\""), "Enhancement prompt missing key: \(key)")
        }
    }

    func testEnhanceSystemPromptContainsPriorityInstructions() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.enhanceSystemPrompt(for: template)
            XCTAssertTrue(prompt.contains("backbone"), "Enhancement system prompt missing priority instructions for \(template.rawValue)")
            XCTAssertTrue(prompt.contains("handwritten notes"), "Enhancement system prompt missing notes reference for \(template.rawValue)")
        }
    }

    func testEnhanceWithCustomInstructions() {
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: "my notes",
            transcript: "some transcript",
            template: .custom,
            customInstructions: "Focus on key metrics"
        )
        XCTAssertTrue(prompt.contains("Focus on key metrics"))
    }

    func testEnhancePromptContainsTitleAndSummary() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.enhanceWithUserNotes(
                userNotes: "notes",
                transcript: "transcript",
                template: template
            )
            XCTAssertTrue(prompt.contains("\"title\""), "Enhancement missing title for \(template.rawValue)")
            XCTAssertTrue(prompt.contains("\"summary\""), "Enhancement missing summary for \(template.rawValue)")
        }
    }

    func testOriginalStructureNotesUnchanged() {
        // Verify existing method still works identically (no regression)
        let prompt = PromptTemplates.structureNotes(transcript: "test data", template: .lecture)
        XCTAssertTrue(prompt.contains("test data"))
        XCTAssertTrue(prompt.contains("\"keyConcepts\""))
        XCTAssertFalse(prompt.contains("User's notes"), "structureNotes should not contain user notes block")
    }

    // MARK: - Timestamp Cross-Reference Tests

    func testEnhanceSystemPromptContainsTimestampCrossRef() {
        let prompt = PromptTemplates.enhanceSystemPrompt(for: .meeting)
        XCTAssertTrue(prompt.contains("cross-reference"), "Enhancement prompt should mention timestamp cross-referencing")
    }

    func testTimestampedNotesFormattedInPrompt() {
        let notes = TimestampedNote.formatForPrompt([
            TimestampedNote(timestamp: 90, text: "Budget approved"),
            TimestampedNote(timestamp: 225, text: "# Action Items"),
        ])
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: notes,
            transcript: "test transcript",
            template: .meeting
        )
        XCTAssertTrue(prompt.contains("[01:30] Budget approved"), "Prompt should contain formatted timestamp")
        XCTAssertTrue(prompt.contains("[03:45] # Action Items"), "Prompt should contain formatted timestamp")
    }

    // MARK: - Freeform Template

    func testFreeformStructurePromptContainsTopicsSchema() {
        let prompt = PromptTemplates.structureNotes(transcript: "test transcript", template: .freeform)
        XCTAssertTrue(prompt.contains("\"topics\""), "Freeform prompt should contain topics key")
        XCTAssertTrue(prompt.contains("\"children\""), "Freeform prompt should hint at children for nesting")
        XCTAssertTrue(prompt.contains("\"title\""), "Freeform prompt should contain title field")
        XCTAssertTrue(prompt.contains("\"summary\""), "Freeform prompt should contain summary field")
        XCTAssertTrue(prompt.contains("test transcript"), "Freeform prompt should embed transcript")
    }

    func testFreeformStructurePromptOmitsFixedSectionKeys() {
        let prompt = PromptTemplates.structureNotes(transcript: "test", template: .freeform)
        // Should NOT contain any of the fixed-template section keys
        let fixedKeys = ["keyConcepts", "discussionPoints", "guestBackground", "practiceProblems"]
        for key in fixedKeys {
            XCTAssertFalse(prompt.contains("\"\(key)\""), "Freeform prompt should not contain fixed key: \(key)")
        }
    }

    func testFreeformEnhancePromptContainsUserNotesAndTopics() {
        let userNotes = "Budget was approved"
        let transcript = "Alice discussed budget."
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: userNotes,
            transcript: transcript,
            template: .freeform
        )
        XCTAssertTrue(prompt.contains(userNotes), "Freeform enhance prompt missing user notes")
        XCTAssertTrue(prompt.contains(transcript), "Freeform enhance prompt missing transcript")
        XCTAssertTrue(prompt.contains("\"topics\""), "Freeform enhance prompt should contain topics key")
        XCTAssertTrue(prompt.contains("\"children\""), "Freeform enhance prompt should hint at children")
    }

    func testFreeformPromptAcceptsCustomInstructions() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test",
            template: .freeform,
            customInstructions: "Focus on architectural decisions"
        )
        XCTAssertTrue(prompt.contains("Focus on architectural decisions"))
    }
}
