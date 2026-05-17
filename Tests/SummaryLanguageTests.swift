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
}
