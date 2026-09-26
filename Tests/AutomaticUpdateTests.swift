import XCTest
import Sparkle
import CryptoKit
@testable import Seminarly

@MainActor
final class AutomaticUpdateTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func settings() -> UpdateSettings {
        let name = "AutomaticUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UpdateSettings(defaults: defaults)
    }

    private func update(length: UInt64 = 4) -> UpdateDownload {
        UpdateDownload(version: "16", displayVersion: "0.1.15",
            url: URL(string: "https://github.com/daniellee-ux/Seminarly-AI/releases/download/v0.1.15/arm64-15.delta")!,
            contentLength: length)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testOptInSchedulesWithoutAWindowAndThrottlesDaily() async throws {
        let settings = settings()
        var checks = 0
        let cache = UpdateDownloadCache(directory: try temporaryDirectory(), sourceBuild: "15")
        let coordinator = AutomaticUpdateCoordinator(settings: settings, cache: cache) { checks += 1; return true }
        coordinator.start()
        coordinator.checkIfDue()
        XCTAssertEqual(checks, 0)
        settings.automaticallyCheckForUpdates = true
        try await waitUntil { checks == 1 }
        coordinator.finishedChecking()
        let firstCheck = try XCTUnwrap(settings.lastCheckDate)
        coordinator.checkIfDue(now: firstCheck.addingTimeInterval(3_600))
        XCTAssertEqual(checks, 1)
        coordinator.checkIfDue(now: firstCheck.addingTimeInterval(86_401))
        XCTAssertEqual(checks, 2)
        settings.automaticallyCheckForUpdates = false
        coordinator.finishedChecking()
        coordinator.checkIfDue(now: firstCheck.addingTimeInterval(172_802))
        XCTAssertEqual(checks, 2)
    }

    func testBusyManualUpdaterDoesNotConsumeDailyCheck() async throws {
        let settings = settings()
        settings.automaticallyCheckForUpdates = true
        let coordinator = AutomaticUpdateCoordinator(settings: settings,
            cache: UpdateDownloadCache(directory: try temporaryDirectory()), check: { false })
        coordinator.start()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(settings.lastCheckDate)
        settings.automaticallyCheckForUpdates = false
    }

    func testBackgroundDownloadIsCachedAndManualActionOnlyExposesTheCache() async throws {
        let directory = try temporaryDirectory()
        let settings = settings()
        settings.automaticallyCheckForUpdates = true
        let cache = UpdateDownloadCache(directory: directory, sourceBuild: "15") { request in
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3, 4]).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = AutomaticUpdateCoordinator(settings: settings, cache: cache, check: { true })
        coordinator.start()
        try await waitUntil { coordinator.status == .checking }
        coordinator.foundUpdate(update())
        try await waitUntil { coordinator.status == .ready("0.1.15") }
        let cached = try XCTUnwrap(coordinator.cachedUpdate)
        XCTAssertEqual(try Data(contentsOf: cached.fileURL), Data([1, 2, 3, 4]))
        coordinator.dismissBanner()
        XCTAssertTrue(coordinator.bannerDismissed)
        coordinator.prepareForManualUpdate()
        XCTAssertEqual(coordinator.cachedUpdate, cached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.fileURL.path))
        // Skipping or withdrawing a release clears its cached reminder, so it
        // cannot reappear on the next launch despite Sparkle's skipped version.
        coordinator.clearAvailableUpdate()
        XCTAssertNil(coordinator.cachedUpdate)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertTrue(coordinator.bannerDismissed)
        settings.automaticallyCheckForUpdates = false
    }

    func testDisablingCancelsDownloadAndIgnoresLateCompletion() async throws {
        let directory = try temporaryDirectory()
        let settings = settings()
        settings.automaticallyCheckForUpdates = true
        let cache = UpdateDownloadCache(directory: directory, sourceBuild: "15") { request in
            // Simulate a transport that returns even after cancellation.
            try? await Task.sleep(for: .milliseconds(100))
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3, 4]).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let coordinator = AutomaticUpdateCoordinator(settings: settings, cache: cache, check: { true })
        coordinator.start()
        try await waitUntil { coordinator.status == .checking }
        coordinator.foundUpdate(update())
        try await Task.sleep(for: .milliseconds(20))
        settings.automaticallyCheckForUpdates = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNil(coordinator.cachedUpdate)
        let cached = await cache.existingDownload()
        XCTAssertNil(cached)
    }

    func testFailedDownloadLeavesManualUpdateAvailable() async throws {
        let settings = settings()
        settings.automaticallyCheckForUpdates = true
        let cache = UpdateDownloadCache(directory: try temporaryDirectory()) { _ in throw URLError(.notConnectedToInternet) }
        let coordinator = AutomaticUpdateCoordinator(settings: settings, cache: cache, check: { true })
        coordinator.start()
        try await waitUntil { coordinator.status == .checking }
        coordinator.foundUpdate(update())
        try await waitUntil { coordinator.status == .available("0.1.15") }
        XCTAssertNil(coordinator.cachedUpdate)
        settings.automaticallyCheckForUpdates = false
    }

    func testCacheSurvivesRelaunchWithoutDownloadingAgainAndRejectsAnotherBaseBuild() async throws {
        let directory = try temporaryDirectory()
        let cache = UpdateDownloadCache(directory: directory, sourceBuild: "15") { request in
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3, 4]).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = try await cache.prepare(update())
        let reopened = UpdateDownloadCache(directory: directory, sourceBuild: "15") { _ in throw URLError(.notConnectedToInternet) }
        let second = try await reopened.prepare(update())
        XCTAssertEqual(first, second)
        let newBuild = UpdateDownloadCache(directory: directory, sourceBuild: "16")
        let oldDelta = await newBuild.existingDownload()
        XCTAssertNil(oldDelta)
        try Data([1]).write(to: first.fileURL)
        let truncated = await reopened.existingDownload()
        XCTAssertNil(truncated)
    }

    func testTruncatedAndHTTPFailureResponsesNeverBecomeReady() async throws {
        for status in [200, 404] {
            let directory = try temporaryDirectory()
            let cache = UpdateDownloadCache(directory: directory) { request in
                let file = directory.appendingPathComponent(UUID().uuidString)
                try Data([1]).write(to: file)
                return (file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await cache.prepare(update()); XCTFail("Invalid download accepted") }
            catch { XCTAssertTrue(error is URLError) }
            let cached = await cache.existingDownload()
            XCTAssertNil(cached)
        }
    }

    func testCacheSubstitutionRequiresExactEnclosureAndExistingFile() throws {
        let file = try temporaryDirectory().appendingPathComponent("archive")
        try Data([1, 2, 3, 4]).write(to: file)
        let descriptor = update()
        let cached = CachedUpdate(update: descriptor, sourceBuild: "15", filename: "archive", fileURL: file)
        XCTAssertTrue(AppUpdater.canServe(cached, for: "16", url: descriptor.url, contentLength: 4))
        XCTAssertFalse(AppUpdater.canServe(cached, for: "17", url: descriptor.url, contentLength: 4))
        XCTAssertFalse(AppUpdater.canServe(cached, for: "16", url: URL(string: "https://example.com/other.delta"), contentLength: 4))
        XCTAssertFalse(AppUpdater.canServe(cached, for: "16", url: descriptor.url, contentLength: 5))
        try Data([1]).write(to: file)
        XCTAssertFalse(AppUpdater.canServe(cached, for: "16", url: descriptor.url, contentLength: 4))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(AppUpdater.canServe(cached, for: "16", url: descriptor.url, contentLength: 4))
    }

    func testInvalidatingFailedCacheMakesNextAttemptDownloadAgain() async throws {
        let directory = try temporaryDirectory()
        let cache = UpdateDownloadCache(directory: directory, sourceBuild: "15") { request in
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3, 4]).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let old = try await cache.prepare(update())
        await cache.discard(old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.path))
        let new = try await cache.prepare(update())
        XCTAssertNotEqual(old.fileURL, new.fileURL)
        // A late failure from an older session cannot delete a replacement.
        await cache.discard(old)
        let existing = await cache.existingDownload()
        XCTAssertEqual(existing, new)
    }

    func testCachePrunesObsoleteDeltaBasesAfterAppUpdate() async throws {
        let directory = try temporaryDirectory()
        let download: UpdateDownloadCache.Download = { request in
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3, 4]).write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let oldCache = UpdateDownloadCache(directory: directory, sourceBuild: "14", download: download)
        let old = try await oldCache.prepare(update())
        let newCache = UpdateDownloadCache(directory: directory, sourceBuild: "15", download: download)
        let new = try await newCache.prepare(update())
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.fileURL.path))
    }

    func testSignedSparkleProbeSelectsCachedDeltaAndRejectsTamperedFeedForPrefetch() async throws {
        for tamper in [false, true] {
            let directory = try temporaryDirectory()
            let key = Curve25519.Signing.PrivateKey()
            let archiveSignature = try key.signature(for: Data([1, 2, 3, 4])).base64EncodedString()
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel><title>Update test</title><item>
            <sparkle:version>16</sparkle:version><sparkle:shortVersionString>0.1.15</sparkle:shortVersionString>
            <enclosure url="https://example.invalid/Seminarly.dmg" length="8" type="application/octet-stream" sparkle:edSignature="\(archiveSignature)"/>
            <sparkle:deltas><enclosure url="https://example.invalid/arm64-15.delta" length="4" sparkle:deltaFrom="15" sparkle:edSignature="\(archiveSignature)"/></sparkle:deltas>
            </item></channel></rss>
            """
            let content = Data(xml.utf8)
            let signature = try key.signature(for: content).base64EncodedString()
            let servedXML = tamper ? xml.replacingOccurrences(of: "0.1.15", with: "0.1.16") : xml
            let signed = servedXML + "<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(content.count)\n-->"
            let feed = directory.appendingPathComponent("appcast.xml")
            try Data(signed.utf8).write(to: feed)
            let server = CachedUpdateServer(fileURL: feed, downloadFilename: "appcast.xml")
            defer { server.stop() }
            let feedURL = try await server.start()
            let bundleURL = directory.appendingPathComponent("Fixture.app")
            let executable = bundleURL.appendingPathComponent("Contents/MacOS/Fixture")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let identifier = "ai.seminarly.update-fixture.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults(suiteName: identifier)?.removePersistentDomain(forName: identifier) }
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleName": "Fixture", "CFBundleExecutable": "Fixture",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "15", "CFBundleShortVersionString": "0.1.14",
                "SUFeedURL": feedURL.absoluteString, "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
                "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
                "SUEnableAutomaticChecks": false, "SUAllowsAutomaticUpdates": false, "SUSendProfileInfo": false,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: bundleURL))
            let probe = SignedFeedProbe()
            let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: Bundle.main, userDriver: driver, delegate: probe)
            try updater.start()
            updater.checkForUpdateInformation()
            try await waitUntil { probe.finished }
            if tamper {
                // Informational probes reject an invalid signature outright;
                // no item can reach the prefetcher, even via a safe fallback.
                XCTAssertNil(probe.item)
                XCTAssertNotNil(probe.error)
            } else {
                let item = try XCTUnwrap(probe.item, "Probe error: \(String(describing: probe.error))")
                XCTAssertEqual(item.signingValidationStatus, .succeeded)
                XCTAssertTrue(item.isDeltaUpdate)
                let selected = try XCTUnwrap(AppUpdater.backgroundDownload(for: item))
                XCTAssertEqual(selected.url.lastPathComponent, "arm64-15.delta")
                XCTAssertEqual(selected.contentLength, 4)
                XCTAssertEqual(selected.version, "16")
            }
            XCTAssertFalse(updater.automaticallyDownloadsUpdates)
            XCTAssertFalse(updater.sessionInProgress)
        }
    }

    func testLoopbackDeliveryPreservesEveryByteAndArchiveExtension() async throws {
        let file = try temporaryDirectory().appendingPathComponent("archive")
        let bytes = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let server = CachedUpdateServer(fileURL: file, downloadFilename: "arm64-15.delta")
        defer { server.stop() }
        let url = try await server.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        let (downloaded, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.suggestedFilename, "arm64-15.delta")
        XCTAssertEqual(downloaded, bytes)
        let (_, denied) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("other.delta"))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
    }
}


@MainActor
private final class SignedFeedProbe: NSObject, SPUUpdaterDelegate {
    var item: SUAppcastItem?
    var finished = false
    var error: Error?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { self.item = item }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        self.error = error
        finished = true
    }
}
