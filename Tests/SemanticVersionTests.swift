import XCTest
@testable import Seminarly

final class SemanticVersionTests: XCTestCase {

    // MARK: - Parsing

    func testParsesPlainVersion() {
        let version = SemanticVersion("1.2.3")
        XCTAssertEqual(version?.major, 1)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 3)
        XCTAssertEqual(version?.prerelease, [])
    }

    func testStripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion("V1.2.3"), SemanticVersion("1.2.3"))
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(SemanticVersion("  1.2.3 \n"), SemanticVersion("1.2.3"))
    }

    func testIgnoresBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.2.3+build.5"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion("1.2.3-beta+exp.sha.5114f85"), SemanticVersion("1.2.3-beta"))
    }

    func testParsesPrereleaseIdentifiers() {
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2")?.prerelease, ["beta", "2"])
        XCTAssertEqual(SemanticVersion("1.0.0-rc.1")?.prerelease, ["rc", "1"])
    }

    func testDescriptionRoundTrips() {
        XCTAssertEqual(SemanticVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2")?.description, "1.0.0-beta.2")
    }

    // MARK: - Invalid input

    func testRejectsEmpty() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("   "))
        XCTAssertNil(SemanticVersion("v"))
    }

    func testRejectsNonNumericCore() {
        XCTAssertNil(SemanticVersion("1.x.0"))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("1.2.beta"))
    }

    func testRejectsTooManyComponents() {
        XCTAssertNil(SemanticVersion("1.2.3.4"))
    }

    func testRejectsEmptyPrereleaseIdentifier() {
        XCTAssertNil(SemanticVersion("1.0.0-alpha..1"))
    }

    func testRejectsTrailingDash() {
        // A bare trailing "-" must not be parsed as the stable "2.0.0".
        XCTAssertNil(SemanticVersion("2.0.0-"))
        XCTAssertNil(SemanticVersion("v2.0.0-"))
    }

    // MARK: - Ordering (the headline cases)

    func testNumericNotLexicalComparison() {
        // The bug a naive string compare would introduce: "0.1.10" < "0.1.2" lexically.
        XCTAssertLessThan(SemanticVersion("0.1.1")!, SemanticVersion("0.1.10")!)
        XCTAssertLessThan(SemanticVersion("0.1.2")!, SemanticVersion("0.1.10")!)
        XCTAssertLessThan(SemanticVersion("1.0.9")!, SemanticVersion("1.0.10")!)
    }

    func testMajorMinorPatchOrdering() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("2.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.1.0")!, SemanticVersion("1.2.0")!)
        XCTAssertLessThan(SemanticVersion("1.1.1")!, SemanticVersion("1.1.2")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.9.9")!)
    }

    func testEqualVersionsAreNeitherLessNorGreater() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion("1.2.3"))
        XCTAssertFalse(SemanticVersion("1.2.3")! < SemanticVersion("1.2.3")!)
        XCTAssertFalse(SemanticVersion("1.2.3")! > SemanticVersion("1.2.3")!)
    }

    func testVPrefixedTagComparesEqualToBareVersion() {
        XCTAssertEqual(SemanticVersion("v0.1.1"), SemanticVersion("0.1.1"))
        XCTAssertFalse(SemanticVersion("v0.1.1")! < SemanticVersion("0.1.1")!)
    }

    // MARK: - Pre-release precedence (SemVer §11.4)

    func testPrereleaseRanksBelowRelease() {
        XCTAssertLessThan(SemanticVersion("1.0.0-beta")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-rc.1")!, SemanticVersion("1.0.0")!)
    }

    func testAlphabeticalPrereleaseOrdering() {
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha")!, SemanticVersion("1.0.0-beta")!)
    }

    func testNumericPrereleaseIdentifiersCompareNumerically() {
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.1")!, SemanticVersion("1.0.0-alpha.2")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.2")!, SemanticVersion("1.0.0-alpha.10")!)
    }

    func testFewerPrereleaseIdentifiersRanksLower() {
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha")!, SemanticVersion("1.0.0-alpha.1")!)
    }

    func testNumericIdentifierRanksBelowAlphanumeric() {
        XCTAssertLessThan(SemanticVersion("1.0.0-1")!, SemanticVersion("1.0.0-alpha")!)
    }
}
