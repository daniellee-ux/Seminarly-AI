import XCTest
@testable import Seminarly

final class NoteTemplateTests: XCTestCase {

    func testAllCasesHaveDisplayNames() {
        for template in NoteTemplate.allCases {
            XCTAssertFalse(template.displayName.isEmpty, "\(template.rawValue) has empty displayName")
        }
    }

    func testAllCasesHaveIcons() {
        for template in NoteTemplate.allCases {
            XCTAssertFalse(template.icon.isEmpty, "\(template.rawValue) has empty icon")
        }
    }

    func testAllCasesHaveDescriptions() {
        for template in NoteTemplate.allCases {
            XCTAssertFalse(template.description.isEmpty, "\(template.rawValue) has empty description")
        }
    }

    func testLectureHasSixSections() {
        XCTAssertEqual(NoteTemplate.lecture.sectionDefinitions.count, 6)
    }

    func testStudyGuideHasSixSections() {
        XCTAssertEqual(NoteTemplate.studyGuide.sectionDefinitions.count, 6)
    }

    func testMeetingHasFourSections() {
        XCTAssertEqual(NoteTemplate.meeting.sectionDefinitions.count, 4)
    }

    func testPodcastHasSixSections() {
        XCTAssertEqual(NoteTemplate.podcast.sectionDefinitions.count, 6)
    }

    func testCustomHasNoSections() {
        XCTAssertTrue(NoteTemplate.custom.sectionDefinitions.isEmpty)
    }

    func testFreeformHasNoSections() {
        XCTAssertTrue(NoteTemplate.freeform.sectionDefinitions.isEmpty)
    }

    func testFreeformIsFirstCase() {
        XCTAssertEqual(NoteTemplate.allCases.first, .freeform)
    }

    func testFreeformDisplayNameAndIcon() {
        XCTAssertEqual(NoteTemplate.freeform.displayName, "Freeform")
        XCTAssertEqual(NoteTemplate.freeform.icon, "list.bullet.indent")
    }

    func testRawValueRoundTrip() {
        for template in NoteTemplate.allCases {
            XCTAssertEqual(NoteTemplate(rawValue: template.rawValue), template)
        }
    }

    func testSectionDefinitionKeysAreUnique() {
        for template in NoteTemplate.allCases {
            let keys = template.sectionDefinitions.map(\.key)
            XCTAssertEqual(keys.count, Set(keys).count, "Duplicate keys in \(template.rawValue)")
        }
    }

    func testIdentifiable() {
        for template in NoteTemplate.allCases {
            XCTAssertEqual(template.id, template.rawValue)
        }
    }
}
