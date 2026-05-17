import XCTest
@testable import Seminarly

final class LLMResponseSanitizerTests: XCTestCase {
    func testCleanJSONPassesThroughUnchanged() {
        let input = #"{"title":"hi","summary":"x"}"#
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), input)
    }

    func testStripsLeadingAndTrailingWhitespace() {
        let input = "\n  {\"a\":1}  \n\n"
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }

    func testStripsJSONFences() {
        let input = """
        ```json
        {"a":1}
        ```
        """
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }

    func testStripsBareTripleBacktickFences() {
        let input = """
        ```
        {"a":1}
        ```
        """
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }

    func testStripsBOM() {
        let input = "\u{FEFF}{\"a\":1}"
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }

    func testCombinedWhitespaceFenceAndBOM() {
        let input = "\u{FEFF}\n```json\n{\"a\":1}\n```\n  "
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: ""), "")
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: "   "), "")
    }

    func testFenceWithoutClosingPreservesContent() {
        let input = "```json\n{\"a\":1}"
        XCTAssertEqual(LLMResponseSanitizer.extractJSON(from: input), "{\"a\":1}")
    }
}
