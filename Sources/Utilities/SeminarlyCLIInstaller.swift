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
/// compare. "Installed" = both our binary and skill symlinks exist and resolve
/// into the app bundle (the CLI without its skill is a broken half-install).
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
        if claudeDirExists {
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
        Self.agentConfigDirNames.contains { isExistingDirectory(home.appending(path: $0)) }
    }

    /// True if `~/.claude` exists *as a directory* — gates the optional Claude Code
    /// compat link. A plain file there must not pull the link into the install (it
    /// would then fail to `mkdir ~/.claude/skills` and abort the whole install).
    private var claudeDirExists: Bool { isExistingDirectory(home.appending(path: ".claude")) }

    /// True only when *both* our binary and canonical-skill symlinks exist and
    /// resolve into an app bundle. Requiring both means a partially-removed install
    /// (e.g. the user deleted the skill link, or it failed to link) reads as "not
    /// installed", so the UI re-offers Install instead of hiding it — the CLI without
    /// its skill leaves the advertised agent access broken.
    var isInstalled: Bool {
        guard let binary = bundledBinary, let skillDir = bundledSkillDir else { return false }
        return symlink(binLink, resolvesTo: binary)
            && symlink(canonicalSkillDir, resolvesTo: skillDir)
    }

    /// True if `link` is a symlink whose target exists and is the *same file* as
    /// `target` — i.e. it points at this running app's bundle, not merely any path
    /// with the right suffix. A leftover link to an older `Seminarly.app` copy must
    /// not count as installed, or we'd hide repair and run a stale CLI/schema.
    private func symlink(_ link: URL, resolvesTo target: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else { return false }
        return fileManager.fileExists(atPath: target.path)
            && link.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
    }

    /// Whether the app is running from a durable location. Launched from a mounted
    /// DMG or a Gatekeeper App Translocation path, `Bundle.main.bundleURL` is a
    /// temporary/read-only location; symlinking into it would dangle the moment the
    /// user ejects the DMG or moves the app. Install refuses until it's stable.
    var isBundleLocationStable: Bool {
        guard let binary = bundledBinary else { return false }
        // Gatekeeper App Translocation copies the app to a randomized temp mount.
        if binary.path.contains("/AppTranslocation/") { return false }
        // A read-only volume is almost certainly a mounted disk image.
        let bundle = binary.deletingLastPathComponent()  // …/Contents/Helpers
            .deletingLastPathComponent()                 // …/Contents
            .deletingLastPathComponent()                 // …/Seminarly.app
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return false
        }
        return true
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
        for name in shellStartupFileNames {
            let url = home.appending(path: name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if Self.hasActiveLocalBinLine(in: contents) { return true }
        }
        return false
    }

    /// The user's login shell name (e.g. "zsh", "bash"), from `$SHELL`. Empty if
    /// unset; treated as zsh (the macOS default) everywhere it's consulted.
    private var loginShellName: String {
        environment["SHELL"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    }

    /// Whether we can configure PATH automatically for this shell. bash and zsh
    /// (and an unset `$SHELL`, treated as the macOS-default zsh) use `export PATH=…`
    /// in known files. fish, tcsh, etc. use different syntax and locations, so we
    /// don't auto-edit them — the UI shows manual guidance rather than claiming
    /// success on a file the shell never reads.
    var canAddToPathAutomatically: Bool {
        ["", "zsh", "bash"].contains(loginShellName)
    }

    /// Startup files the user's *actual* login shell reads. Scanning a bash user's
    /// `~/.bash_profile` for a zsh user (or vice-versa) would wrongly conclude PATH
    /// is set, since the active shell never sources it. Unsupported shells scan
    /// nothing — we won't guess at files we can't reliably edit — so `localBinOnPath`
    /// falls back to the inherited environment only and never claims false success.
    private var shellStartupFileNames: [String] {
        switch loginShellName {
        case "bash":    return [".bash_profile", ".bash_login", ".bashrc", ".profile"]
        case "", "zsh": return [".zshrc", ".zprofile", ".zshenv"]
        default:        return []
        }
    }

    /// The startup file `addLocalBinToPath()` writes to — chosen so it's one of the
    /// files `localBinOnPath` scans, keeping the write and the read consistent (a
    /// bash user's PATH line must land somewhere bash actually sources).
    var pathFileToEdit: URL {
        if loginShellName == "bash" {
            // A bash login shell sources only the FIRST of these that exists. Append
            // to the existing one so creating ~/.bash_profile doesn't shadow (and
            // silently disable) a user's existing ~/.bash_login. Default to
            // ~/.bash_profile when none exist — the conventional file to create.
            let candidates = [".bash_profile", ".bash_login", ".profile"]
            let existing = candidates.first { fileManager.fileExists(atPath: home.appending(path: $0).path) }
            return home.appending(path: existing ?? ".bash_profile")
        }
        return home.appending(path: ".zshrc")
    }

    /// Tilde-path of ``pathFileToEdit`` for UI copy (e.g. "~/.zshrc").
    var pathFileDisplayName: String { "~/\(pathFileToEdit.lastPathComponent)" }

    /// A copy-pasteable line that puts `~/.local/bin` on PATH in the user's shell
    /// syntax — so the manual instructions shown for unsupported shells are actually
    /// correct (pasting bash `export` into fish/tcsh would not work).
    var pathExportSnippet: String {
        switch loginShellName {
        case "fish":         return #"fish_add_path "$HOME/.local/bin""#
        case "tcsh", "csh":  return #"setenv PATH "$HOME/.local/bin:$PATH""#
        default:             return Self.pathExportLine
        }
    }

    /// True if any *active* (non-comment) line actually puts `.local/bin` on `PATH`.
    /// Requires both `.local/bin` and `PATH` on the same line, so neither a `#`
    /// comment nor an unrelated mention (e.g. `mkdir -p "$HOME/.local/bin"`) counts —
    /// otherwise we'd wrongly conclude it's on PATH, hide the opt-in, and leave the
    /// CLI installed but unresolvable by name in a new shell.
    static func hasActiveLocalBinLine(in contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.contains(".local/bin") else { return false }
            // Require an actual `PATH=` assignment, not merely the substring "PATH":
            // `export LOCAL_BIN_PATH="$HOME/.local/bin"` sets a different variable and
            // must not count. The boundary excludes `…_PATH=` while allowing
            // `export PATH=` / `PATH=` at line start.
            return line.range(of: #"(^|[^A-Za-z0-9_])PATH="#, options: .regularExpression) != nil
        }
    }

    // MARK: - Install / uninstall

    func install() throws {
        guard let binary = bundledBinary else { throw InstallError.bundledBinaryMissing }
        guard let skillDir = bundledSkillDir else { throw InstallError.bundledSkillMissing }
        // Don't symlink into a DMG / translocated copy — those paths vanish.
        guard isBundleLocationStable else { throw InstallError.bundleLocationUnstable }

        // The *required* links: the binary and the canonical skill. The install
        // succeeds or fails on these together.
        let required = [(link: binLink, destination: binary),
                        (link: canonicalSkillDir, destination: skillDir)]

        // Preflight so install is atomic — do everything that can fail *before*
        // creating any symlink: (1) refuse to clobber a real file/dir at a target,
        // and (2) create every parent directory up front, so e.g. a regular file at
        // ~/.agents can't leave the binary linked but the skill not. Stale/own
        // symlinks are replaceable, so they don't count as occupied.
        if let occupied = required.first(where: { isOccupiedByRealFile($0.link) })?.link {
            throw InstallError.pathOccupied(occupied)
        }
        for (link, _) in required {
            try createParentDirectory(for: link)
        }
        for (link, destination) in required {
            try replaceSymlink(at: link, withDestination: destination)
        }

        // The Claude Code compat link is *optional* and best-effort: a leftover real
        // file/dir there (or a failing mkdir) must not block the install for every
        // other agent, so skip it on any problem instead of aborting.
        if claudeDirExists, !isOccupiedByRealFile(claudeSkillDir) {
            do {
                try createParentDirectory(for: claudeSkillDir)
                try replaceSymlink(at: claudeSkillDir, withDestination: canonicalSkillDir)
            } catch {
                logger.notice("Skipped optional Claude compat link: \(error.localizedDescription, privacy: .public)")
            }
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
    /// PATH line to the shell startup file. Idempotent; safe when the file is
    /// missing. Only valid for shells we support (see ``canAddToPathAutomatically``).
    func addLocalBinToPath() throws {
        guard canAddToPathAutomatically else { throw InstallError.unsupportedShellForPathEdit }
        let target = pathFileToEdit
        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        guard !Self.hasActiveLocalBinLine(in: existing) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let block = Data("\(separator)\n# Added by Seminarly — exposes seminarly-cli on your PATH\n\(Self.pathExportLine)\n".utf8)

        // Append in place. If the file is a symlink (dotfile managers do this), open
        // and append to its *target* rather than atomically replacing the symlink
        // with a regular file, which would silently break the user's dotfile setup.
        if fileManager.fileExists(atPath: target.path) {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: block)
        } else {
            try createParentDirectory(for: target)
            try block.write(to: target)
        }
        logger.notice("Appended ~/.local/bin to PATH in \(target.lastPathComponent, privacy: .public)")
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

    /// True if a directory (not a file, not absent) exists at `url`.
    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
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
        case bundleLocationUnstable
        case unsupportedShellForPathEdit
        case pathOccupied(URL)

        var errorDescription: String? {
            switch self {
            case .bundledBinaryMissing:
                return "The bundled seminarly-cli wasn't found inside the app. Try reinstalling Seminarly."
            case .bundledSkillMissing:
                return "The bundled agent skill wasn't found inside the app. Try reinstalling Seminarly."
            case .bundleLocationUnstable:
                return "Move Seminarly to your Applications folder, then install — it's running from a temporary or read-only location (such as the disk image), and the link would break when that goes away."
            case .unsupportedShellForPathEdit:
                return "Add ~/.local/bin to your PATH in your shell's startup file — Seminarly only edits PATH automatically for bash and zsh."
            case .pathOccupied(let url):
                return "\(url.path) already exists and isn't a Seminarly symlink. Remove it by hand, then try again."
            }
        }
    }
}
