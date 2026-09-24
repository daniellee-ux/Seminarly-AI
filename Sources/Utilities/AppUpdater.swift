import AppKit
import Sparkle

/// Signed in-app installation. The existing opt-in checker owns scheduling and its
/// quiet banner; Sparkle is created only when the user asks to check/install.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?

    nonisolated static func feedURL(for architecture: ReleaseArchitecture = .current) -> URL {
        let name = architecture == .appleSilicon ? "appcast-arm64.xml" : "appcast-x86_64.xml"
        return URL(string: "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/\(name)")!
    }

    func checkForUpdates() {
        do {
            if controller == nil {
                let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                // Our default-off preference owns background checks, not Sparkle's scheduler.
                value.updater.automaticallyChecksForUpdates = false
                value.updater.automaticallyDownloadsUpdates = false
                value.updater.sendsSystemProfile = false
                try value.updater.start()
                controller = value
            }
            controller?.checkForUpdates(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Start the Updater"
            alert.informativeText = "You can still download the latest Seminarly from its releases page."
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL().absoluteString }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard !AppDelegate.hasActiveRecordingWork else {
            let alert = NSAlert()
            alert.messageText = "Finish Your Recording First"
            alert.informativeText = "Seminarly won't restart while a recording is active or being saved. Install the update after your session is saved."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        // Sparkle terminates through NSApplication: the existing save/checkpoint
        // delegate still runs, including work that begins after this check.
        return true
    }
}
