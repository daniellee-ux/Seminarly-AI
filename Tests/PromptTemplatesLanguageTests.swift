import XCTest
@testable import Seminarly

/// Tests for the summary-language directive injection in PromptTemplates.
/// These complement `PromptTemplatesTests` (which assert pre-language behavior
/// is preserved with the default `.matchTranscript`).
final class PromptTemplatesLanguageTests: XCTestCase {

    // MARK: - Match Transcript (default) injects nothing

    func testMatchTranscriptOmitsLanguageDirectiveInSystemPrompt() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.systemPrompt(for: template, summaryLanguage: .matchTranscript)
            XCTAssertFalse(prompt.contains("OUTPUT LANGUAGE:"),
                           "Match-transcript should not inject language directive (\(template.rawValue))")
        }
    }

    func testMatchTranscriptOmitsLanguageRuleInUserPrompt() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test",
            template: .meeting,
            summaryLanguage: .matchTranscript
        )
        XCTAssertFalse(prompt.contains("MUST be written in"),
                       "Match-transcript should not inject language rule")
    }

    func testDefaultArgumentBehavesAsMatchTranscript() {
        // Existing call sites that don't pass summaryLanguage should be untouched.
        let withoutArg = PromptTemplates.systemPrompt(for: .meeting)
        let withMatch = PromptTemplates.systemPrompt(for: .meeting, summaryLanguage: .matchTranscript)
        XCTAssertEqual(withoutArg, withMatch)
    }

    // MARK: - Preset injects directive into both system prompt and rules block

    func testPresetInjectsLanguageNameIntoSystemPrompt() {
        let prompt = PromptTemplates.systemPrompt(for: .meeting, summaryLanguage: .ko)
        XCTAssertTrue(prompt.contains("OUTPUT LANGUAGE:"))
        XCTAssertTrue(prompt.contains("Korean"))
    }

    func testPresetInjectsLanguageRuleIntoUserPrompt() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test transcript",
            template: .meeting,
            summaryLanguage: .ko
        )
        XCTAssertTrue(prompt.contains("Korean"))
        XCTAssertTrue(prompt.contains("MUST be written in Korean"),
                      "Rules block should reinforce the language requirement")
    }

    func testPresetWorksForFreeformTemplate() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test",
            template: .freeform,
            summaryLanguage: .es
        )
        XCTAssertTrue(prompt.contains("Spanish"))
    }

    func testPresetWorksForAllTemplates() {
        for template in NoteTemplate.allCases {
            let prompt = PromptTemplates.structureNotes(
                transcript: "test",
                template: template,
                summaryLanguage: .ja
            )
            XCTAssertTrue(prompt.contains("Japanese"),
                          "Japanese directive missing for \(template.rawValue)")
        }
    }

    // MARK: - Custom freeform name flows through

    func testCustomLanguageInjectsRawName() {
        let prompt = PromptTemplates.structureNotes(
            transcript: "test",
            template: .meeting,
            summaryLanguage: .custom("Klingon")
        )
        XCTAssertTrue(prompt.contains("Klingon"))
    }

    func testCustomLanguageInjectsIntoSystemPrompt() {
        let prompt = PromptTemplates.systemPrompt(for: .meeting, summaryLanguage: .custom("Latin"))
        XCTAssertTrue(prompt.contains("Latin"))
        XCTAssertTrue(prompt.contains("OUTPUT LANGUAGE:"))
    }

    func testEmptyCustomIsTreatedAsMatchTranscript() {
        let prompt = PromptTemplates.systemPrompt(for: .meeting, summaryLanguage: .custom(""))
        XCTAssertFalse(prompt.contains("OUTPUT LANGUAGE:"),
                       "Empty custom name should not inject a language directive")
    }

    // MARK: - Enhancement path

    func testEnhanceSystemPromptInjectsLanguage() {
        let prompt = PromptTemplates.enhanceSystemPrompt(for: .meeting, summaryLanguage: .ko)
        XCTAssertTrue(prompt.contains("Korean"))
        XCTAssertTrue(prompt.contains("backbone"),
                      "Enhancement-specific instructions should still be present")
    }

    func testEnhanceWithUserNotesInjectsLanguage() {
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: "my notes",
            transcript: "the talk",
            template: .meeting,
            summaryLanguage: .es
        )
        XCTAssertTrue(prompt.contains("Spanish"))
    }

    func testEnhanceFreeformInjectsLanguage() {
        let prompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: "n",
            transcript: "t",
            template: .freeform,
            summaryLanguage: .ja
        )
        XCTAssertTrue(prompt.contains("Japanese"))
    }

    // MARK: - Helper accessors

    func testLanguageSystemDirectiveNilForMatchTranscript() {
        XCTAssertNil(PromptTemplates.languageSystemDirective(.matchTranscript))
    }

    func testLanguageSystemDirectiveContainsLanguageName() {
        let directive = PromptTemplates.languageSystemDirective(.ko)
        XCTAssertNotNil(directive)
        XCTAssertTrue(directive!.contains("Korean"))
    }

    func testLanguageRuleNilForMatchTranscript() {
        XCTAssertNil(PromptTemplates.languageRule(.matchTranscript))
    }

    func testLanguageRuleContainsLanguageName() {
        let rule = PromptTemplates.languageRule(.ko)
        XCTAssertNotNil(rule)
        XCTAssertTrue(rule!.contains("Korean"))
        XCTAssertTrue(rule!.hasPrefix("- "), "Rule should be formatted as a bullet list item")
    }
}
