import XCTest
@testable import Seminarly

final class UpdateCheckerTests: XCTestCase {

    private func makeRelease(
        tag: String,
        name: String? = nil,
        body: String? = nil,
        htmlURL: String = "https://github.com/daniellee-ux/Seminarly-AI/releases/tag/x"
    ) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: name, body: body, htmlURL: htmlURL)
    }

    // MARK: - GitHubRelease decoding

    func testDecodesRealisticPayloadAndIgnoresUnknownKeys() throws {
        let json = """
        {
          "tag_name": "v0.1.2",
          "name": "Release v0.1.2",
          "body": "## What's new\\n- Fixed a crash",
          "html_url": "https://github.com/daniellee-ux/Seminarly-AI/releases/tag/v0.1.2",
          "prerelease": false,
          "draft": false,
          "id": 12345,
          "assets": []
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v0.1.2")
        XCTAssertEqual(release.name, "Release v0.1.2")
        XCTAssertEqual(release.htmlURL, "https://github.com/daniellee-ux/Seminarly-AI/releases/tag/v0.1.2")
        XCTAssertEqual(release.body, "## What's new\n- Fixed a crash")
    }

    func testDecodesPayloadWithNullOptionalFields() throws {
        let json = """
        { "tag_name": "v1.0.0", "name": null, "body": null, "html_url": "https://example.com" }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.0.0")
        XCTAssertNil(release.name)
        XCTAssertNil(release.body)
    }

    // MARK: - evaluate(currentVersion:release:)

    func testNewerReleaseIsUpdateAvailable() {
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "v0.2.0"))
        guard case .updateAvailable(_, let latest) = outcome else {
            return XCTFail("Expected .updateAvailable, got \(outcome)")
        }
        XCTAssertEqual(latest, SemanticVersion("0.2.0")!)
    }

    func testEqualVersionIsUpToDate() {
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "v0.1.1"))
        guard case .upToDate = outcome else { return XCTFail("Expected .upToDate, got \(outcome)") }
    }

    func testOlderReleaseIsUpToDate() {
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "v0.1.0"))
        guard case .upToDate = outcome else { return XCTFail("Expected .upToDate, got \(outcome)") }
    }

    func testPatchBumpAcrossDoubleDigitsIsUpdateAvailable() {
        // Guards the numeric-vs-lexical comparison end to end (0.1.1 -> 0.1.10).
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "0.1.10"))
        guard case .updateAvailable = outcome else { return XCTFail("Expected .updateAvailable, got \(outcome)") }
    }

    func testUnparseableReleaseTagIsTreatedAsUpToDate() {
        // A malformed tag must never produce a false "update available" prompt.
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "nightly-build"))
        guard case .upToDate = outcome else { return XCTFail("Expected .upToDate, got \(outcome)") }
    }

    func testTrailingDashTagIsTreatedAsUpToDate() {
        // A malformed "vX.Y.Z-" tag must not surface as a stable update.
        let outcome = UpdateChecker.evaluate(currentVersion: "0.1.1", release: makeRelease(tag: "v2.0.0-"))
        guard case .upToDate = outcome else { return XCTFail("Expected .upToDate, got \(outcome)") }
    }

    // MARK: - displayName / shortReleaseNotes

    func testDisplayNamePrefersReleaseName() {
        let release = makeRelease(tag: "v0.2.0", name: "Big Update")
        XCTAssertEqual(UpdateChecker.displayName(for: release), "Big Update")
    }

    func testDisplayNameFallsBackToVersion() {
        XCTAssertEqual(UpdateChecker.displayName(for: makeRelease(tag: "v0.2.0")), "Version 0.2.0")
        XCTAssertEqual(UpdateChecker.displayName(for: makeRelease(tag: "v0.2.0", name: "   ")), "Version 0.2.0")
    }

    func testShortReleaseNotesTruncatesByLines() {
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let notes = UpdateChecker.shortReleaseNotes(body, maxLines: 5, maxCharacters: 1000)
        let unwrapped = try? XCTUnwrap(notes)
        XCTAssertTrue(unwrapped?.contains("line 1") == true)
        XCTAssertTrue(unwrapped?.contains("line 5") == true)
        XCTAssertFalse(unwrapped?.contains("line 6") == true)
        XCTAssertTrue(unwrapped?.contains("…") == true)
    }

    func testShortReleaseNotesIsNilForEmptyOrNil() {
        XCTAssertNil(UpdateChecker.shortReleaseNotes(nil))
        XCTAssertNil(UpdateChecker.shortReleaseNotes("   \n  "))
    }

    func testShortReleaseNotesPassesThroughShortBody() {
        XCTAssertEqual(UpdateChecker.shortReleaseNotes("- One change"), "- One change")
    }

    // MARK: - Download URL

    func testDownloadURLPointsAtLatestAsset() {
        // The Download button relies on GitHub's latest-asset redirect; guard the
        // exact string (the constant is force-unwrapped, so a typo crashes at launch).
        XCTAssertEqual(
            UpdateChecker.downloadURL.absoluteString,
            "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/Seminarly.dmg"
        )
    }

    // MARK: - UpdateSettings.isDue (pure timing)

    func testIsDueWhenNeverChecked() {
        XCTAssertTrue(UpdateSettings.isDue(lastCheck: nil, now: Date(), interval: 86_400))
    }

    func testIsDueAfterIntervalElapsed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastCheck = now.addingTimeInterval(-90_000) // 25h ago
        XCTAssertTrue(UpdateSettings.isDue(lastCheck: lastCheck, now: now, interval: 86_400))
    }

    func testNotDueWithinInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastCheck = now.addingTimeInterval(-3_600) // 1h ago
        XCTAssertFalse(UpdateSettings.isDue(lastCheck: lastCheck, now: now, interval: 86_400))
    }
}
