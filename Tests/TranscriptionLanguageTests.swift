import XCTest
@testable import Seminarly

final class TranscriptionLanguageTests: XCTestCase {

    func testAutoWhisperCodeIsNil() {
        XCTAssertNil(TranscriptionLanguage.auto.whisperCode)
    }

    func testSpecificLanguagesReturnRawValue() {
        let cases: [(TranscriptionLanguage, String)] = [
            (.en, "en"), (.zh, "zh"), (.ja, "ja"), (.ko, "ko"),
            (.es, "es"), (.fr, "fr"), (.de, "de"), (.pt, "pt"),
        ]
        for (language, expected) in cases {
            XCTAssertEqual(language.whisperCode, expected, "\(language.rawValue) should return \(expected)")
        }
    }

    func testAllNonAutoCasesHaveWhisperCode() {
        for language in TranscriptionLanguage.allCases where language != .auto {
            XCTAssertNotNil(language.whisperCode, "\(language.rawValue) has nil whisperCode")
            XCTAssertEqual(language.whisperCode, language.rawValue)
        }
    }

    func testAllCasesHaveDisplayNames() {
        for language in TranscriptionLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty, "\(language.rawValue) has empty displayName")
        }
    }

    func testAllCasesHaveNativeNames() {
        for language in TranscriptionLanguage.allCases {
            XCTAssertFalse(language.nativeName.isEmpty, "\(language.rawValue) has empty nativeName")
        }
    }

    func testRawValueRoundTrip() {
        for language in TranscriptionLanguage.allCases {
            XCTAssertEqual(TranscriptionLanguage(rawValue: language.rawValue), language)
        }
    }

    func testIdentifiable() {
        for language in TranscriptionLanguage.allCases {
            XCTAssertEqual(language.id, language.rawValue)
        }
    }

    func testLanguageCount() {
        // 1 auto + 21 languages = 22
        XCTAssertEqual(TranscriptionLanguage.allCases.count, 22)
    }
}
