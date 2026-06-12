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

    /// Extract the user-facing "what's new" from a GitHub release body: drop the
    /// duplicate title line and everything from the first boilerplate boundary
    /// (install steps, requirements, changelog link, or a `---` rule). Markdown is
    /// preserved for rendering. Returns nil if empty. Pure → unit-tested.
    nonisolated static func releaseNotesSummary(_ body: String?) -> String? {
        guard let raw = body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        var kept: [String] = []
        for original in raw.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespaces)
            if isBoilerplateBoundary(line) { break }
            if kept.isEmpty && isTitleLine(line) { continue }   // drop leading title
            kept.append(line)
        }

        while kept.first?.isEmpty == true { kept.removeFirst() }
        while kept.last?.isEmpty == true { kept.removeLast() }
        var collapsed: [String] = []
        for line in kept where !(line.isEmpty && collapsed.last?.isEmpty == true) {
            collapsed.append(line)
        }
        let result = collapsed.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    /// A section header that starts release-notes boilerplate, or a horizontal rule.
    nonisolated private static func isBoilerplateBoundary(_ line: String) -> Bool {
        if line == "---" || line == "***" || line == "___" { return true }
        let label = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ ")).lowercased()
        return ["updating", "installing", "install", "requires", "full changelog", "changelog"]
            .contains { label.hasPrefix($0) }
    }

    /// The leading "**Seminarly vX** — …" / "# Seminarly X" line — it duplicates the
    /// alert's headline, so it's dropped.
    nonisolated private static func isTitleLine(_ line: String) -> Bool {
        (line.hasPrefix("#") || line.hasPrefix("**")) && line.lowercased().contains("seminarly")
    }

    /// Render the extracted "what's new" into a styled attributed string for the
    /// update alert's accessory — headings emphasized, `-`/`*` items as bullets, and
    /// inline `**bold**` / `*italic*` / `` `code` `` applied (no raw markdown shown).
    nonisolated static func renderedReleaseNotes(_ body: String?) -> NSAttributedString? {
        guard let summary = releaseNotesSummary(body) else { return nil }

        let baseSize = NSFont.systemFontSize(for: .small)
        let baseFont = NSFont.systemFont(ofSize: baseSize)
        let headingFont = NSFont.systemFont(ofSize: baseSize + 1, weight: .semibold)

        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.headIndent = 14
        bulletStyle.paragraphSpacing = 2

        let out = NSMutableAttributedString()
        for (index, line) in summary.components(separatedBy: .newlines).enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let text = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                appendInline(text, font: headingFont, paragraph: nil, into: out)
            } else if let item = bulletBody(line) {
                out.append(NSAttributedString(string: "•  ", attributes: [
                    .font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bulletStyle,
                ]))
                appendInline(item, font: baseFont, paragraph: bulletStyle, into: out)
            } else {
                appendInline(line, font: baseFont, paragraph: nil, into: out)
            }
        }
        return out
    }

    nonisolated private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// Append `text`, applying inline `**bold**` / `*italic*` / `` `code` `` runs.
    nonisolated private static func appendInline(
        _ text: String, font: NSFont, paragraph: NSParagraphStyle?, into out: NSMutableAttributedString
    ) {
        var bold = false, italic = false, code = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var styled = font
            if code {
                styled = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if bold { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                if !traits.isEmpty {
                    styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits),
                                    size: font.pointSize) ?? font
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: NSColor.labelColor]
            if let paragraph { attrs[.paragraphStyle] = paragraph }
            out.append(NSAttributedString(string: buffer, attributes: attrs))
            buffer = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                flush(); bold.toggle(); i += 2
            } else if chars[i] == "*" {
                flush(); italic.toggle(); i += 1
            } else if chars[i] == "`" {
                flush(); code.toggle(); i += 1
            } else {
                buffer.append(chars[i]); i += 1
            }
        }
        flush()
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
        // Render the notes into a scrollable accessory so nothing is trimmed and the
        // markdown shows formatted rather than as raw syntax.
        if let notes = Self.renderedReleaseNotes(release.body) {
            info += "\n\nWhat's new:"
            alert.accessoryView = makeNotesAccessory(notes)
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openDownload()
        }
    }

    /// A bordered, scrollable, read-only text view for the alert's release notes.
    /// Sized to content up to a cap, then scrolls — so long notes are never trimmed.
    private func makeNotesAccessory(_ notes: NSAttributedString) -> NSScrollView {
        let width: CGFloat = 360
        let textHeight = notes.boundingRect(
            with: NSSize(width: width - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let height = min(170, max(54, ceil(textHeight) + 18))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(notes)

        scrollView.documentView = textView
        return scrollView
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
