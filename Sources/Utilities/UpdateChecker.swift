import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "UpdateChecker")

/// One release as returned by `GET /repos/{owner}/{repo}/releases/latest`. Only
/// the fields we use are decoded; GitHub's many other keys are ignored.
struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
    }
}

/// Why a check was started — controls how loudly results are reported.
enum UpdateCheckMode {
    /// User clicked "Check for Updates…" — report *every* outcome (including
    /// up-to-date and errors) via an `NSAlert`.
    case manual
    /// Opt-in once-a-day launch check — surface only an available update, as a
    /// quiet in-window banner; stay silent on up-to-date / errors.
    case automatic
}

/// The result of comparing the running build against the latest release.
enum UpdateOutcome: Equatable {
    case updateAvailable(release: GitHubRelease, latest: SemanticVersion)
    case upToDate(current: SemanticVersion)
}

enum UpdateCheckError: LocalizedError {
    case network(String)
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .http(let code): return "GitHub returned an unexpected response (HTTP \(code))."
        case .decoding: return "The response from GitHub couldn't be read."
        }
    }
}

/// Detection-only update awareness: asks the GitHub Releases API for the latest
/// release and, if it's newer than the running build, points the user at the
/// already-notarized DMG on the release page. No download/verify/install here —
/// that's the heavier Sparkle path (issue #21).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Set when an automatic check finds a newer release; drives the in-window
    /// `UpdateBannerView`. Manual checks present an `NSAlert` and leave this nil.
    @Published private(set) var availableUpdate: GitHubRelease?

    /// Mode of the in-flight check, or nil when idle. Tracked (rather than a plain
    /// bool) so a manual request arriving mid-check can promote the running check
    /// to `.manual` instead of being silently dropped.
    private var activeMode: UpdateCheckMode?

    nonisolated private static let releasesURL = URL(
        string: "https://api.github.com/repos/daniellee-ux/Seminarly-AI/releases/latest"
    )!

    /// Direct-download link for the latest notarized DMG. GitHub's
    /// `releases/latest/download/<asset>` redirects to the newest release's asset,
    /// so clicking it downloads the build without landing on a GitHub page. Depends
    /// on the release asset being named `Seminarly.dmg` (the packaging script's
    /// fixed name); forks should point this at their own distribution.
    nonisolated static let downloadURL = URL(
        string: "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/Seminarly.dmg"
    )!

    private init() {}

    /// The running build's marketing version (`CFBundleShortVersionString`).
    nonisolated static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Public entry points

    func checkForUpdates(mode: UpdateCheckMode) {
        if activeMode != nil {
            // A check is already running — don't fire a second network request, but
            // honor an explicit manual request by upgrading how the in-flight check
            // reports (quiet banner → alert, and surface up-to-date / errors). Keeps
            // a clicked "Check for Updates…" from looking like a no-op at launch.
            if mode == .manual { activeMode = .manual }
            return
        }
        activeMode = mode
        // Stamp the time up front so repeated launches don't re-hit GitHub even if
        // the network is slow or failing.
        if mode == .automatic {
            UpdateSettings.shared.markCheckedNow()
        }
        Task { await performCheck() }
    }

    func dismissBanner() {
        availableUpdate = nil
    }

    /// Open the direct download for the latest DMG (see `downloadURL`).
    func openDownload() {
        NSWorkspace.shared.open(Self.downloadURL)
    }

    // MARK: - Pure logic (nonisolated → unit-testable off the main actor)

    /// Decide what a freshly-fetched release means for the running build. Returns
    /// `.upToDate` whenever a version can't be parsed, so a malformed tag never
    /// produces a false "update available" prompt.
    nonisolated static func evaluate(currentVersion: String, release: GitHubRelease) -> UpdateOutcome {
        guard let current = SemanticVersion(currentVersion) else {
            logger.error("Could not parse current version '\(currentVersion, privacy: .public)'")
            return .upToDate(current: SemanticVersion("0.0.0")!)
        }
        guard let latest = SemanticVersion(release.tagName) else {
            logger.error("Could not parse release tag '\(release.tagName, privacy: .public)'")
            return .upToDate(current: current)
        }
        return latest > current
            ? .updateAvailable(release: release, latest: latest)
            : .upToDate(current: current)
    }

    /// Trim release-note markdown to a few lines for an alert; nil if empty.
    nonisolated static func shortReleaseNotes(
        _ body: String?,
        maxLines: Int = 8,
        maxCharacters: Int = 600
    ) -> String? {
        guard let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }

        var lines = trimmed.components(separatedBy: .newlines)
        var didTruncate = false
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            didTruncate = true
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
            didTruncate = true
        }
        return didTruncate ? text + "\n…" : text
    }

    /// Display name for a release: its title if present, else "Version X.Y.Z".
    nonisolated static func displayName(for release: GitHubRelease) -> String {
        if let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let tag = SemanticVersion(release.tagName)?.description ?? release.tagName
        return "Version \(tag)"
    }

    // MARK: - Networking

    /// Fetch the latest release. `nonisolated` and `URLSession`-injectable so it
    /// stays off the main actor; the GitHub API requires a `User-Agent` header.
    nonisolated static func fetchLatestRelease(session: URLSession = .shared) async throws -> GitHubRelease {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Seminarly/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.network("No response from GitHub.")
        }
        guard http.statusCode == 200 else {
            throw UpdateCheckError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding
        }
    }

    // MARK: - Orchestration

    private func performCheck() async {
        defer { activeMode = nil }
        do {
            let release = try await Self.fetchLatestRelease()
            // Read the effective mode *after* the round-trip so a manual request that
            // promoted the check while it was in flight is honored.
            let isManual = activeMode == .manual
            switch Self.evaluate(currentVersion: Self.currentVersionString, release: release) {
            case .updateAvailable(let release, let latest):
                logger.notice("Update available: \(latest.description, privacy: .public)")
                if isManual {
                    presentUpdateAlert(release: release, latest: latest)
                } else {
                    availableUpdate = release
                }
            case .upToDate(let current):
                logger.info("Up to date at \(current.description, privacy: .public)")
                if isManual { presentUpToDateAlert(current: current) }
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if activeMode == .manual { presentErrorAlert(error: error) }
        }
    }

    // MARK: - Alerts (manual checks only)

    private func presentUpdateAlert(release: GitHubRelease, latest: SemanticVersion) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        var info = "\(Self.displayName(for: release)) is available — you're on \(Self.currentVersionString)."
        if let notes = Self.shortReleaseNotes(release.body) {
            info += "\n\nWhat's new:\n\(notes)"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openDownload()
        }
    }

    private func presentUpToDateAlert(current: SemanticVersion) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Seminarly \(current.description) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
