import XCTest
@testable import Seminarly

final class TranscriptSegmentCodableTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let segment = TranscriptSegment(
            startTime: 10.5,
            endTime: 15.2,
            text: "Hello, how are you?",
            speaker: "Speaker 1"
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(decoded.startTime, 10.5)
        XCTAssertEqual(decoded.endTime, 15.2)
        XCTAssertEqual(decoded.text, "Hello, how are you?")
        XCTAssertEqual(decoded.speaker, "Speaker 1")
    }

    func testNilSpeakerEncodesCorrectly() throws {
        let segment = TranscriptSegment(
            startTime: 0,
            endTime: 5,
            text: "No speaker"
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertNil(decoded.speaker)
        XCTAssertEqual(decoded.text, "No speaker")
    }

    func testArrayRoundTripPreservesOrder() throws {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 5, text: "First"),
            TranscriptSegment(startTime: 5, endTime: 10, text: "Second"),
            TranscriptSegment(startTime: 10, endTime: 15, text: "Third"),
        ]

        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].text, "First")
        XCTAssertEqual(decoded[1].text, "Second")
        XCTAssertEqual(decoded[2].text, "Third")
    }
}

final class NoteSectionCodableTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let section = NoteSection(
            key: "keyConcepts",
            title: "Key Concepts",
            icon: "lightbulb",
            items: [NoteItem(text: "Concept A"), NoteItem(text: "Concept B")]
        )

        let data = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(NoteSection.self, from: data)

        XCTAssertEqual(decoded.key, "keyConcepts")
        XCTAssertEqual(decoded.title, "Key Concepts")
        XCTAssertEqual(decoded.icon, "lightbulb")
        XCTAssertEqual(decoded.items.map(\.text), ["Concept A", "Concept B"])
    }

    func testEmptyItemsArray() throws {
        let section = NoteSection(
            key: "empty",
            title: "Empty",
            icon: "circle",
            items: []
        )

        let data = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(NoteSection.self, from: data)

        XCTAssertTrue(decoded.items.isEmpty)
    }
}

final class SectionDefinitionCodableTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let def = SectionDefinition(
            key: "themes",
            title: "Themes",
            icon: "tag",
            promptHint: "Main themes discussed"
        )

        let data = try JSONEncoder().encode(def)
        let decoded = try JSONDecoder().decode(SectionDefinition.self, from: data)

        XCTAssertEqual(decoded.key, "themes")
        XCTAssertEqual(decoded.title, "Themes")
        XCTAssertEqual(decoded.icon, "tag")
        XCTAssertEqual(decoded.promptHint, "Main themes discussed")
    }
}
