import AppKit
import Sparkle

/// Sparkle owns feed/architecture/version selection, signatures and installation.
/// Background checks only probe its signed feed; installation is user initiated.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?
    private var informationCheckInProgress = false
    private var manualCheckPending = false
    private var manualStartTask: Task<Void, Never>?
    private var cacheServer: CachedUpdateServer?
    private var cachedTransportWasUsed = false
    private var servedUpdate: (cached: CachedUpdate, localURL: URL)?

    lazy var automatic = AutomaticUpdateCoordinator(settings: .shared, cache: UpdateDownloadCache()) { [weak self] in
        try self?.checkForUpdateInformation() ?? false
    }

    nonisolated static func feedURL(for architecture: ReleaseArchitecture = .current) -> URL {
        let name = architecture == .appleSilicon ? "appcast-arm64.xml" : "appcast-x86_64.xml"
        return URL(string: "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/\(name)")!
    }

    private func updaterController() throws -> SPUStandardUpdaterController {
        if let controller { return controller }
        let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // Sparkle's automatic download also arms installation on quit. Keep it
        // disabled: our cache must not start an installer before user consent.
        value.updater.automaticallyChecksForUpdates = false
        value.updater.automaticallyDownloadsUpdates = false
        value.updater.sendsSystemProfile = false
        try value.updater.start()
        controller = value
        return value
    }

    private func checkForUpdateInformation() throws -> Bool {
        let updater = try updaterController().updater
        guard manualStartTask == nil, !informationCheckInProgress,
              !updater.sessionInProgress, updater.canCheckForUpdates else { return false }
        informationCheckInProgress = true
        updater.checkForUpdateInformation()
        return true
    }

    func checkForUpdates() {
        automatic.prepareForManualUpdate()
        if informationCheckInProgress {
            // A click during a background probe must still open the manual UI.
            manualCheckPending = true
            return
        }
        guard manualStartTask == nil else { return }
        manualStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.manualStartTask = nil }
            do {
                let controller = try self.updaterController()
                if !controller.updater.sessionInProgress {
                    self.stopServingCache()
                    if let cached = self.automatic.cachedUpdate {
                        let server = CachedUpdateServer(fileURL: cached.fileURL, downloadFilename: cached.update.url.lastPathComponent)
                        do {
                            let url = try await server.start()
                            self.cacheServer = server
                            self.servedUpdate = (cached, url)
                        } catch {
                            server.stop()
                            // Cache delivery is optional; Sparkle can download
                            // and verify the same signed archive normally.
                        }
                    }
                }
                controller.checkForUpdates(nil)
            } catch {
                self.stopServingCache()
                let alert = NSAlert()
                alert.messageText = "Couldn't Start the Updater"
                alert.informativeText = "You can still download the latest Seminarly from its releases page."
                alert.addButton(withTitle: "Open Releases")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) }
            }
        }
    }

    private func stopServingCache() {
        cacheServer?.stop()
        cacheServer = nil
        servedUpdate = nil
        cachedTransportWasUsed = false
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL().absoluteString }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard informationCheckInProgress, !manualCheckPending else { return }
        // Sparkle may offer a safe manual fallback for a feed with a bad
        // signature. Such a feed must never trigger an automatic download.
        guard item.signingValidationStatus == .succeeded else { return }
        if let download = Self.backgroundDownload(for: item) {
            automatic.foundUpdate(download)
        } else {
            automatic.foundInformationalUpdate(version: item.displayVersionString)
        }
    }

    static func backgroundDownload(for item: SUAppcastItem) -> UpdateDownload? {
        guard item.signingValidationStatus == .succeeded,
              !item.isInformationOnlyUpdate, !item.isMajorUpgrade,
              let url = item.fileURL, url.scheme == "https" else { return nil }
        return UpdateDownload(version: item.versionString, displayVersion: item.displayVersionString,
                              url: url, contentLength: item.contentLength)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        automatic.clearAvailableUpdate()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { automatic.clearAvailableUpdate() }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard let servedUpdate,
              Self.canServe(servedUpdate.cached, for: item.versionString,
                            url: request.url, contentLength: item.contentLength) else { return }
        // Only the transport changes. Sparkle retains the signed item, its
        // expected length, Ed25519 signature and delta/full-download fallback.
        cachedTransportWasUsed = true
        request.url = servedUpdate.localURL
    }

    nonisolated static func canServe(_ cached: CachedUpdate, for version: String, url: URL?, contentLength: UInt64) -> Bool {
        cached.update.version == version && cached.update.url == url
            && cached.update.contentLength == contentLength && cached.hasExpectedSize
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if updateCheck == .updateInformation {
            informationCheckInProgress = false
            automatic.finishedChecking()
            if manualCheckPending {
                manualCheckPending = false
                checkForUpdates()
            }
        } else {
            // A corrupt cached full archive must not poison every later retry.
            if error != nil, cachedTransportWasUsed { automatic.invalidateCachedUpdate() }
            stopServingCache()
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard !AppDelegate.hasActiveRecordingWork else {
            let alert = NSAlert()
            alert.messageText = "Finish Your Recording First"
            alert.informativeText = "Seminarly won't restart while a recording is active or being saved. Install the update after your session is saved."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        // The existing save/checkpoint delegate also handles work that begins
        // after this check but before Sparkle requests application termination.
        return true
    }
}
