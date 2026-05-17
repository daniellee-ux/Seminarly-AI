import XCTest
@testable import Seminarly

final class TranscriptTests: XCTestCase {

    func testDiarizedTextWithSegments() {
        let transcript = Transcript(
            rawText: "Hello goodbye",
            segments: [
                TranscriptSegment(startTime: 0, endTime: 5, text: "Hello", speaker: "Speaker 1"),
                TranscriptSegment(startTime: 5, endTime: 10, text: "Goodbye", speaker: "Speaker 2"),
            ]
        )

        let result = transcript.diarizedText

        XCTAssertTrue(result.contains("[00:00] Speaker 1: Hello"))
        XCTAssertTrue(result.contains("[00:05] Speaker 2: Goodbye"))
    }

    func testDiarizedTextWithEmptySegmentsReturnsRawText() {
        let transcript = Transcript(
            rawText: "Just raw text here",
            segments: []
        )

        XCTAssertEqual(transcript.diarizedText, "Just raw text here")
    }

    func testDiarizedTextTimestampFormatting() {
        let transcript = Transcript(
            rawText: "",
            segments: [
                TranscriptSegment(startTime: 65, endTime: 70, text: "After one minute", speaker: "Speaker 1"),
                TranscriptSegment(startTime: 3661, endTime: 3670, text: "After one hour", speaker: "Speaker 2"),
            ]
        )

        let result = transcript.diarizedText

        XCTAssertTrue(result.contains("[01:05]"), "65 seconds should format as 01:05")
        XCTAssertTrue(result.contains("[61:01]"), "3661 seconds should format as 61:01")
    }
}
