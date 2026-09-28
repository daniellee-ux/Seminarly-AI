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
    let assets: [GitHubReleaseAsset]

    init(tagName: String, name: String?, body: String?, htmlURL: String,
         assets: [GitHubReleaseAsset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try values.decode(String.self, forKey: .tagName)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try values.decode(String.self, forKey: .htmlURL)
        assets = try values.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
}

/// The result of comparing the running build against the latest release.
enum UpdateOutcome: Equatable {
    case updateAvailable(release: GitHubRelease, latest: SemanticVersion)
    case upToDate(current: SemanticVersion)
}

/// Pure helpers for GitHub release metadata and release-note rendering.
/// Runtime update checks use Sparkle's signed appcast through AppUpdater.
enum UpdateChecker {
    /// Safe fallback when a release has no compatible installer attached.
    nonisolated static let releasesPageURL = URL(
        string: "https://github.com/daniellee-ux/Seminarly-AI/releases/latest"
    )!

    // MARK: - Pure logic (nonisolated → unit-testable off the main actor)

    nonisolated static func downloadURL(for release: GitHubRelease,
                                       architecture: ReleaseArchitecture = .current) -> URL {
        guard SemanticVersion(release.tagName) != nil else { return releasesPageURL }
        let names = Set(release.assets.map(\.name))
        guard let name = [architecture.assetName, "Seminarly.dmg"].first(where: names.contains) else {
            // Never substitute the other CPU's binary or invent a missing asset.
            return releasesPageURL
        }
        // Build a trusted, version-pinned URL instead of opening an arbitrary URL
        // from release metadata, or racing a later change to /releases/latest.
        return URL(string: "https://github.com/daniellee-ux/Seminarly-AI/releases/download")!
            .appendingPathComponent(release.tagName)
            .appendingPathComponent(name)
    }

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

}
