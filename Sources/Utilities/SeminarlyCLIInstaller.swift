import Foundation
import os

private let logger = Logger(subsystem: "ai.seminarly.Seminarly", category: "SeminarlyCLIInstaller")

/// Installs (and uninstalls) the bundled `seminarly-cli` + agent skill so a user's
/// coding agent (Claude Code, Codex, Cursor, Gemini, …) can read their Seminarly
/// sessions. This is the app-bundle-aware port of `scripts/install-global.sh`.
///
/// Install is **symlink-based**: the binary symlink points into the app bundle, so
/// the CLI auto-tracks every app update and always matches the SwiftData schema it
/// reads. Install state is therefore just *installed / not-installed* — no version
/// compare. "Installed" = our `~/.local/bin/seminarly-cli` symlink exists and
/// resolves into an app bundle's `Contents/Helpers`.
///
/// The struct is configured with its inputs (home dir, bundled binary, bundled
/// skill folder, environment) so it can be exercised against a temp directory in
/// tests; ``bundled`` is the real instance wired to `Bundle.main`.
struct SeminarlyCLIInstaller {
    /// The user's home directory (the real home — the app is not sandboxed).
    var home: URL
    /// The embedded CLI at `Seminarly.app/Contents/Helpers/seminarly-cli`, or nil
    /// if it isn't present (e.g. an unexpected build).
    var bundledBinary: URL?
    /// The embedded skill folder at `Seminarly.app/Contents/Resources/seminarly-cli`
    /// (contains `SKILL.md`), or nil if absent.
    var bundledSkillDir: URL?
    var fileManager: FileManager
    /// Process environment, used to read `PATH`. Injectable for tests.
    var environment: [String: String]

    /// The real installer, wired to the running app bundle and the user's home.
    static var bundled: SeminarlyCLIInstaller {
        let fm = FileManager.default
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/seminarly-cli")
        let skill = Bundle.main.resourceURL?.appending(path: "seminarly-cli")
        return SeminarlyCLIInstaller(
            home: fm.homeDirectoryForCurrentUser,
            bundledBinary: fm.fileExists(atPath: helper.path) ? helper : nil,
            bundledSkillDir: skill.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil },
            fileManager: fm,
            environment: ProcessInfo.processInfo.environment
        )
    }

    // MARK: - Paths we own

    /// Binary symlink so the bare `seminarly-cli` name in SKILL.md resolves via $PATH.
    var binLink: URL { home.appending(path: ".local/bin/seminarly-cli") }
    /// Canonical user-level skill path — the open standard read by Codex CLI,
    /// Gemini CLI, Cursor, Kiro, Antigravity, and (now) Claude Code.
    var canonicalSkillDir: URL { home.appending(path: ".agents/skills/seminarly-cli") }
    /// Compatibility path for Claude Code's historical default skill location.
    var claudeSkillDir: URL { home.appending(path: ".claude/skills/seminarly-cli") }

    /// The single line we'd add to `~/.zshrc` if the user opts into the PATH edit.
    static let pathExportLine = #"export PATH="$HOME/.local/bin:$PATH""#

    /// Tilde-abbreviated paths the install touches — for the "what this touches"
    /// disclosure. The PATH edit is intentionally *not* here: it is a separate,
    /// explicit opt-in (see ``localBinOnPath`` / ``addLocalBinToPath()``).
    var touchedPaths: [String] {
        var paths = ["~/.local/bin/seminarly-cli", "~/.agents/skills/seminarly-cli"]
        if fileManager.fileExists(atPath: home.appending(path: ".claude").path) {
            paths.append("~/.claude/skills/seminarly-cli")
        }
        return paths
    }

    // MARK: - State

    /// Coding-agent config directories we look for to decide whether the
    /// empty-state offer is relevant. Their presence means "this user runs a
    /// coding agent," which gates the discovery surface.
    static let agentConfigDirNames = [".claude", ".codex", ".cursor", ".gemini", ".agents"]

    /// True if any known coding-agent directory exists under home.
    var hasAgentConfigDir: Bool {
        Self.agentConfigDirNames.contains { name in
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: home.appending(path: name).path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
    }

    /// True when our binary symlink exists and resolves into an app bundle.
    var isInstalled: Bool {
        // Must be a symlink (this succeeds even for a dangling one).
        guard (try? fileManager.destinationOfSymbolicLink(atPath: binLink.path)) != nil else {
            return false
        }
        let resolved = binLink.resolvingSymlinksInPath().path
        return resolved.hasSuffix("Contents/Helpers/seminarly-cli")
            && fileManager.fileExists(atPath: resolved)
    }

    /// True if `~/.local/bin` is already reachable — either exported in the
    /// environment we inherited, or referenced by a shell startup file (the common
    /// interactive case, since a GUI app's inherited PATH rarely reflects ~/.zshrc).
    var localBinOnPath: Bool {
        let localBin = home.appending(path: ".local/bin").path
        if let path = environment["PATH"], path.split(separator: ":").contains(where: { $0 == localBin }) {
            return true
        }
        return shellConfigReferencesLocalBin()
    }

    private func shellConfigReferencesLocalBin() -> Bool {
        for name in [".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".profile"] {
            let url = home.appending(path: name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if contents.contains(".local/bin") { return true }
        }
        return false
    }

    // MARK: - Install / uninstall

    func install() throws {
        guard let binary = bundledBinary else { throw InstallError.bundledBinaryMissing }
        guard let skillDir = bundledSkillDir else { throw InstallError.bundledSkillMissing }

        // Preflight so install is atomic: if any target is a real (non-symlink)
        // file/dir we'd refuse to clobber, fail *before* creating anything rather
        // than leaving a half-installed state. Stale/own symlinks are replaceable.
        var targets = [binLink, canonicalSkillDir]
        if fileManager.fileExists(atPath: home.appending(path: ".claude").path) {
            targets.append(claudeSkillDir)
        }
        if let occupied = targets.first(where: isOccupiedByRealFile) {
            throw InstallError.pathOccupied(occupied)
        }

        // 1. Binary symlink → ~/.local/bin/seminarly-cli
        try createParentDirectory(for: binLink)
        try replaceSymlink(at: binLink, withDestination: binary)

        // 2. Canonical skill dir → bundled skill folder (open standard).
        try createParentDirectory(for: canonicalSkillDir)
        try replaceSymlink(at: canonicalSkillDir, withDestination: skillDir)

        // 3. Claude Code compat dir → canonical, but only if ~/.claude exists.
        if fileManager.fileExists(atPath: home.appending(path: ".claude").path) {
            try createParentDirectory(for: claudeSkillDir)
            try replaceSymlink(at: claudeSkillDir, withDestination: canonicalSkillDir)
        }
        logger.notice("Installed seminarly-cli + skill (binary → \(binary.path, privacy: .public))")
    }

    /// Remove only the symlinks we create. Never touches a real file/dir a user put
    /// there, and never edits ~/.zshrc (PATH edits are left for the user to undo).
    func uninstall() {
        for link in [binLink, canonicalSkillDir, claudeSkillDir] {
            guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else { continue }
            try? fileManager.removeItem(at: link)
        }
        logger.notice("Uninstalled seminarly-cli + skill symlinks")
    }

    /// The one consent-sensitive bit, kept isolated from ``install()``: append the
    /// PATH line to ~/.zshrc. Idempotent; safe to call when the file is missing.
    func addLocalBinToPath() throws {
        let zshrc = home.appending(path: ".zshrc")
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(".local/bin") else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let block = "\(separator)\n# Added by Seminarly — exposes seminarly-cli on your PATH\n\(Self.pathExportLine)\n"
        try (existing + block).write(to: zshrc, atomically: true, encoding: .utf8)
        logger.notice("Appended ~/.local/bin to PATH in ~/.zshrc")
    }

    // MARK: - Helpers

    private func createParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// True if a real (non-symlink) file or directory lives at `url`. A symlink —
    /// stale, dangling, or one of ours — reports false because it's safe to replace.
    private func isOccupiedByRealFile(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil
            && fileManager.fileExists(atPath: url.path)
    }

    /// Replace whatever is at `link` with a symlink to `dest`. Replaces an existing
    /// symlink (ours or stale/dangling); refuses to clobber a real file or directory.
    private func replaceSymlink(at link: URL, withDestination dest: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            throw InstallError.pathOccupied(link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: dest)
    }

    enum InstallError: LocalizedError {
        case bundledBinaryMissing
        case bundledSkillMissing
        case pathOccupied(URL)

        var errorDescription: String? {
            switch self {
            case .bundledBinaryMissing:
                return "The bundled seminarly-cli wasn't found inside the app. Try reinstalling Seminarly."
            case .bundledSkillMissing:
                return "The bundled agent skill wasn't found inside the app. Try reinstalling Seminarly."
            case .pathOccupied(let url):
                return "\(url.path) already exists and isn't a Seminarly symlink. Remove it by hand, then try again."
            }
        }
    }
}
