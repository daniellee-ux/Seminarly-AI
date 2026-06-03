import XCTest
@testable import Seminarly

final class SummaryLanguageTests: XCTestCase {

    // MARK: - RawRepresentable round-trip

    func testRawRepresentableRoundTripForMatchTranscript() {
        let original = SummaryLanguage.matchTranscript
        XCTAssertEqual(original.rawValue, "match")
        XCTAssertEqual(SummaryLanguage(rawValue: "match"), .matchTranscript)
    }

    func testRawRepresentableRoundTripForPresets() {
        for preset in SummaryLanguage.presets {
            let raw = preset.rawValue
            let restored = SummaryLanguage(rawValue: raw)
            XCTAssertEqual(restored, preset, "Preset \(raw) failed round-trip")
        }
    }

    func testRawRepresentableRoundTripForCustom() {
        let original = SummaryLanguage.custom("Klingon")
        XCTAssertEqual(original.rawValue, "custom:Klingon")
        XCTAssertEqual(SummaryLanguage(rawValue: "custom:Klingon"), .custom("Klingon"))
    }

    func testRawRepresentableRejectsUnknownValue() {
        XCTAssertNil(SummaryLanguage(rawValue: "definitely-not-a-language"))
    }

    // MARK: - Storage code <-> SummaryLanguage

    func testStorageCodeForMatchTranscriptIsNil() {
        XCTAssertNil(SummaryLanguage.matchTranscript.storageCode)
    }

    func testStorageCodeRoundTripForPresets() {
        for preset in SummaryLanguage.presets {
            guard let code = preset.storageCode else {
                XCTFail("Preset \(preset.displayName) has nil storageCode")
                continue
            }
            XCTAssertEqual(SummaryLanguage.fromStorageCode(code), preset)
        }
    }

    func testStorageCodeForCustomCarriesName() {
        let lang = SummaryLanguage.custom("Latin")
        XCTAssertEqual(lang.storageCode, "custom:Latin")
        XCTAssertEqual(SummaryLanguage.fromStorageCode("custom:Latin"), .custom("Latin"))
    }

    func testStorageCodeForEmptyCustomIsNil() {
        XCTAssertNil(SummaryLanguage.custom("").storageCode)
        XCTAssertNil(SummaryLanguage.custom("   ").storageCode)
    }

    func testFromStorageCodeNilReturnsMatchTranscript() {
        XCTAssertEqual(SummaryLanguage.fromStorageCode(nil), .matchTranscript)
        XCTAssertEqual(SummaryLanguage.fromStorageCode(""), .matchTranscript)
    }

    // MARK: - Prompt-facing accessors

    func testPromptLanguageNameForMatchTranscriptIsNil() {
        XCTAssertNil(SummaryLanguage.matchTranscript.promptLanguageName)
    }

    func testPromptLanguageNameForPresetReturnsDisplayName() {
        XCTAssertEqual(SummaryLanguage.ko.promptLanguageName, "Korean")
        XCTAssertEqual(SummaryLanguage.zh.promptLanguageName, "Simplified Chinese (Mandarin)")
        XCTAssertEqual(SummaryLanguage.zhHant.promptLanguageName, "Traditional Chinese (Mandarin)")
        XCTAssertEqual(SummaryLanguage.yue.promptLanguageName, "Cantonese")
    }

    func testPromptStringsAreDistinctAcrossPresets() {
        let prompts = SummaryLanguage.presets.compactMap(\.promptLanguageName)
        XCTAssertEqual(prompts.count, Set(prompts).count, "Each preset must produce a distinct prompt string")
    }

    func testPromptLanguageNameForCustomReturnsTrimmedName() {
        XCTAssertEqual(SummaryLanguage.custom("  Latin  ").promptLanguageName, "Latin")
    }

    func testPromptLanguageNameForEmptyCustomIsNil() {
        XCTAssertNil(SummaryLanguage.custom("").promptLanguageName)
        XCTAssertNil(SummaryLanguage.custom("   ").promptLanguageName)
    }

    func testPresetsListContainsExpectedLanguages() {
        // Sanity: presets should include the common acceptance-criteria languages
        // and exclude .matchTranscript / .custom.
        XCTAssertTrue(SummaryLanguage.presets.contains(.ko))
        XCTAssertTrue(SummaryLanguage.presets.contains(.zh))
        XCTAssertTrue(SummaryLanguage.presets.contains(.es))
        XCTAssertFalse(SummaryLanguage.presets.contains(.matchTranscript))
    }

    // MARK: - Match transcript resolution

    func testResolvedForTranscriptKeepsExplicitLanguage() {
        let transcript = "This meeting was conducted in English."
        XCTAssertEqual(SummaryLanguage.resolvedForTranscript(.ko, transcript: transcript), .ko)
    }

    func testDetectTranscriptLanguageEnglish() {
        let transcript = "Alice reviewed the launch plan and Bob confirmed the timeline."
        XCTAssertEqual(SummaryLanguage.detectTranscriptLanguage(transcript), .en)
    }

    func testDetectTranscriptLanguageTraditionalChinese() {
        let transcript = "會議討論產品策略，市場回饋顯示繁體中文內容需要更準確。後續團隊會整理優先順序。"
        XCTAssertEqual(SummaryLanguage.detectTranscriptLanguage(transcript), .zhHant)
    }

    func testDetectTranscriptLanguageSimplifiedChinese() {
        let transcript = "会议讨论产品策略，市场反馈显示简体中文内容需要更准确。后续团队会整理优先顺序。"
        XCTAssertEqual(SummaryLanguage.detectTranscriptLanguage(transcript), .zh)
    }

    func testDetectTranscriptLanguageMixedEnglishAndTraditionalChinese() {
        let transcript = """
        The host opened with a short product intro before switching into commentary.
        這次更新會改善錄音摘要，重點是讓繁體中文輸出更穩定，也會保留使用者提到的關鍵決策。
        After that, the speaker compared the beta feedback and rollout timing.
        """
        XCTAssertEqual(SummaryLanguage.detectTranscriptLanguage(transcript), .zhHant)
    }

    func testLanguageCodeZHUsesTranscriptScriptWhenAvailable() {
        let transcript = "團隊會優先處理繁體中文摘要的準確度。"
        XCTAssertEqual(SummaryLanguage.fromLanguageCode("zh", sample: transcript), .zhHant)
    }

    func testResolvedMatchTranscriptReturnsConcreteLanguage() {
        let transcript = "会议确认下周发布，团队会继续跟进用户反馈。"
        let resolved = SummaryLanguage.resolvedForTranscript(.matchTranscript, transcript: transcript)
        XCTAssertEqual(resolved, .zh)
        XCTAssertNotEqual(resolved, .matchTranscript)
    }
}
