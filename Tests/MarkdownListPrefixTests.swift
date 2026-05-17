import XCTest
@testable import Seminarly

final class MarkdownListPrefixTests: XCTestCase {

    // MARK: - Bullets

    func testPlainDashBullet() {
        let result = parseListPrefix("- item")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .bullet("-"))
        XCTAssertEqual(result?.prefixLength, 2)
    }

    func testPlainStarBullet() {
        let result = parseListPrefix("* item")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .bullet("*"))
        XCTAssertEqual(result?.prefixLength, 2)
    }

    func testNestedBulletTwoSpaces() {
        let result = parseListPrefix("  - nested")
        XCTAssertEqual(result?.leadingWhitespace, "  ")
        XCTAssertEqual(result?.marker, .bullet("-"))
        XCTAssertEqual(result?.prefixLength, 4)
    }

    func testNestedBulletFourSpaces() {
        let result = parseListPrefix("    - double nested")
        XCTAssertEqual(result?.leadingWhitespace, "    ")
        XCTAssertEqual(result?.marker, .bullet("-"))
        XCTAssertEqual(result?.prefixLength, 6)
    }

    func testTabIndentedBullet() {
        let result = parseListPrefix("\t- tab indent")
        XCTAssertEqual(result?.leadingWhitespace, "\t")
        XCTAssertEqual(result?.marker, .bullet("-"))
        XCTAssertEqual(result?.prefixLength, 3)
    }

    // MARK: - Numbered

    func testNumberedSingleDigit() {
        let result = parseListPrefix("1. first")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .numbered(1))
        XCTAssertEqual(result?.prefixLength, 3)
    }

    func testNumberedDoubleDigit() {
        let result = parseListPrefix("10. ten")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .numbered(10))
        XCTAssertEqual(result?.prefixLength, 4)
    }

    func testNumberedNested() {
        let result = parseListPrefix("  3. nested numbered")
        XCTAssertEqual(result?.leadingWhitespace, "  ")
        XCTAssertEqual(result?.marker, .numbered(3))
        XCTAssertEqual(result?.prefixLength, 5)
    }

    // MARK: - Checkboxes

    func testCheckboxUnchecked() {
        let result = parseListPrefix("- [ ] todo")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .checkbox(checked: false))
        XCTAssertEqual(result?.prefixLength, 6)
    }

    func testCheckboxChecked() {
        let result = parseListPrefix("- [x] done")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .checkbox(checked: true))
        XCTAssertEqual(result?.prefixLength, 6)
    }

    func testCheckboxCheckedCapitalX() {
        let result = parseListPrefix("- [X] capital")
        XCTAssertEqual(result?.leadingWhitespace, "")
        XCTAssertEqual(result?.marker, .checkbox(checked: true))
        XCTAssertEqual(result?.prefixLength, 6)
    }

    func testCheckboxNested() {
        let result = parseListPrefix("  - [ ] nested todo")
        XCTAssertEqual(result?.leadingWhitespace, "  ")
        XCTAssertEqual(result?.marker, .checkbox(checked: false))
        XCTAssertEqual(result?.prefixLength, 8)
    }

    // MARK: - Non-matches

    func testPlainTextReturnsNil() {
        XCTAssertNil(parseListPrefix("plain text"))
    }

    func testDashWithoutSpaceReturnsNil() {
        XCTAssertNil(parseListPrefix("-nospace"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(parseListPrefix(""))
    }

    func testOnlyWhitespaceReturnsNil() {
        XCTAssertNil(parseListPrefix("    "))
    }

    func testHeadingReturnsNil() {
        XCTAssertNil(parseListPrefix("# heading"))
    }

    func testNumberWithoutSpaceReturnsNil() {
        XCTAssertNil(parseListPrefix("1.nospace"))
    }

    func testNumberWithoutDotReturnsNil() {
        XCTAssertNil(parseListPrefix("1 first"))
    }

    // MARK: - nextLineContinuation

    func testContinuationForDashBullet() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .bullet("-"),
            prefixLength: 2
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "- ")
    }

    func testContinuationForStarBullet() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .bullet("*"),
            prefixLength: 2
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "* ")
    }

    func testContinuationForNumberedIncrements() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .numbered(1),
            prefixLength: 3
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "2. ")
    }

    func testContinuationForNumberedNineToTen() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .numbered(9),
            prefixLength: 3
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "10. ")
    }

    func testContinuationForUncheckedBoxStaysUnchecked() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .checkbox(checked: false),
            prefixLength: 6
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "- [ ] ")
    }

    func testContinuationForCheckedBoxBecomesUnchecked() {
        let prefix = ListPrefix(
            leadingWhitespace: "",
            marker: .checkbox(checked: true),
            prefixLength: 6
        )
        XCTAssertEqual(nextLineContinuation(for: prefix), "- [ ] ")
    }

    // MARK: - computeNumberForIndent

    func testComputeNumberEmptyDocument() {
        let result = computeNumberForIndent(
            lines: [],
            currentLineIndex: 0,
            targetIndent: ""
        )
        XCTAssertEqual(result, 1)
    }

    func testComputeNumberFirstLine() {
        let result = computeNumberForIndent(
            lines: ["1. first"],
            currentLineIndex: 0,
            targetIndent: ""
        )
        XCTAssertEqual(result, 1)
    }

    func testComputeNumberAfterSiblingAtRoot() {
        // "1. one", then this line should be "2. "
        let result = computeNumberForIndent(
            lines: ["1. one", ""],
            currentLineIndex: 1,
            targetIndent: ""
        )
        XCTAssertEqual(result, 2)
    }

    func testComputeNumberIndentingFirstChild() {
        // User had "1. test" / "2. " then Tabs line 1 — new indent "  ", should get 1
        let result = computeNumberForIndent(
            lines: ["1. test", "2. "],
            currentLineIndex: 1,
            targetIndent: "  "
        )
        XCTAssertEqual(result, 1)
    }

    func testComputeNumberSecondChild() {
        // Nested "  1. a" above should give sibling at same level → 2
        let result = computeNumberForIndent(
            lines: ["1. parent", "  1. first child", ""],
            currentLineIndex: 2,
            targetIndent: "  "
        )
        XCTAssertEqual(result, 2)
    }

    func testComputeNumberSkipsDeeperNested() {
        // Deeper "    1. deep" lines don't affect count at "  " level
        let result = computeNumberForIndent(
            lines: [
                "1. parent",
                "  1. child",
                "    1. deep",
                "    2. deep two",
                "",
            ],
            currentLineIndex: 4,
            targetIndent: "  "
        )
        XCTAssertEqual(result, 2)
    }

    func testComputeNumberOutdentHitsSiblingAbove() {
        // Outdenting "  1. nested" to root level with "1. one" above → 2
        let result = computeNumberForIndent(
            lines: ["1. one", "  1. nested"],
            currentLineIndex: 1,
            targetIndent: ""
        )
        XCTAssertEqual(result, 2)
    }

    func testComputeNumberBulletSiblingGivesOne() {
        // Sibling at same level but bullet, not numbered → 1
        let result = computeNumberForIndent(
            lines: ["- bullet", ""],
            currentLineIndex: 1,
            targetIndent: ""
        )
        XCTAssertEqual(result, 1)
    }

    func testComputeNumberNonListLinesTransparent() {
        // Plain text lines between siblings should be walked past
        let result = computeNumberForIndent(
            lines: ["1. one", "some text", "2. two", "more text", ""],
            currentLineIndex: 4,
            targetIndent: ""
        )
        XCTAssertEqual(result, 3)
    }

    func testComputeNumberShallowerScopeReturnsOne() {
        // "1. root" is at indent 0; from indent "  " perspective it's a parent → 1
        let result = computeNumberForIndent(
            lines: ["1. root", ""],
            currentLineIndex: 1,
            targetIndent: "  "
        )
        XCTAssertEqual(result, 1)
    }

    // MARK: - transformBlockIndent

    func testBlockIndentRenumbersConsecutiveNumbered() {
        // Select "2. two" + "3. three", Tab. Context: "1. one" above.
        let result = transformBlockIndent(
            lines: ["2. two", "3. three"],
            contextLines: ["1. one"],
            outdent: false
        )
        XCTAssertEqual(result.lines, ["  1. two", "  2. three"])
        XCTAssertEqual(result.firstLineDelta, 2)
        XCTAssertEqual(result.totalDelta, 4)
    }

    func testBlockOutdentRenumbersNested() {
        // Select "  1. a" + "  2. b", Shift-Tab. Context: "1. parent" at root.
        let result = transformBlockIndent(
            lines: ["  1. a", "  2. b"],
            contextLines: ["1. parent"],
            outdent: true
        )
        XCTAssertEqual(result.lines, ["2. a", "3. b"])
        XCTAssertEqual(result.firstLineDelta, -2)
        XCTAssertEqual(result.totalDelta, -4)
    }

    func testBlockIndentPreservesBulletMarker() {
        let result = transformBlockIndent(
            lines: ["- one", "- two"],
            contextLines: [],
            outdent: false
        )
        XCTAssertEqual(result.lines, ["  - one", "  - two"])
        XCTAssertEqual(result.totalDelta, 4)
    }

    func testBlockIndentMixedListTypes() {
        // Bullet sibling resets numbered sequence to 1
        let result = transformBlockIndent(
            lines: ["1. a", "- b", "2. c"],
            contextLines: [],
            outdent: false
        )
        XCTAssertEqual(result.lines, ["  1. a", "  - b", "  1. c"])
    }

    func testBlockIndentSkipsPlainText() {
        // Plain text lines are transparent for renumbering
        let result = transformBlockIndent(
            lines: ["1. a", "note", "2. b"],
            contextLines: [],
            outdent: false
        )
        XCTAssertEqual(result.lines, ["  1. a", "  note", "  2. b"])
    }

    func testBlockOutdentAtRootNoChange() {
        // Already at root — outdent has no effect on list items
        let result = transformBlockIndent(
            lines: ["1. a", "2. b"],
            contextLines: [],
            outdent: true
        )
        XCTAssertEqual(result.lines, ["1. a", "2. b"])
        XCTAssertEqual(result.totalDelta, 0)
    }

    func testBlockIndentCheckboxesPreserveState() {
        let result = transformBlockIndent(
            lines: ["- [ ] todo", "- [x] done"],
            contextLines: [],
            outdent: false
        )
        XCTAssertEqual(result.lines, ["  - [ ] todo", "  - [x] done"])
    }

    func testBlockIndentContinuesExternalSequence() {
        // Context has "  1. prior" at target level; block starts at 2
        let result = transformBlockIndent(
            lines: ["1. new"],
            contextLines: ["parent", "  1. prior"],
            outdent: false
        )
        // "1. new" is at root; new indent "  "; prior sibling "  1. prior" → 2
        XCTAssertEqual(result.lines, ["  2. new"])
    }
}
