import XCTest
import Sparkle
@testable import Seminarly

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testSparkleStartsWithSignedFeedConfigurationWithoutSchedulingDownloads() throws {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        try controller.updater.start()
        XCTAssertTrue(controller.updater.canCheckForUpdates)
        XCTAssertFalse(controller.updater.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.updater.automaticallyDownloadsUpdates)
        XCTAssertFalse(controller.updater.sendsSystemProfile)
    }

    func testSeparateTrustedArchitectureFeeds() {
        XCTAssertEqual(AppUpdater.feedURL(for: .appleSilicon).absoluteString,
                       "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/appcast-arm64.xml")
        XCTAssertTrue(AppUpdater.feedURL(for: .intel).path.hasSuffix("appcast-x86_64.xml"))
    }

    func testUpdateSecurityAndOptInDefaults() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUSendProfileInfo"] as? Bool, false)
    }

    func testSavePipelineBlocksUpdaterRestart() {
        AppDelegate.beginSavePipeline()
        XCTAssertTrue(AppDelegate.hasActiveRecordingWork)
        AppDelegate.endSavePipeline()
        XCTAssertFalse(AppDelegate.hasActiveRecordingWork)
    }
}
