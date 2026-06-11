import XCTest
@testable import Seminarly

/// Exercises the install/uninstall logic against a temp directory standing in for
/// the user's home, with a fake app bundle providing the binary + skill.
final class SeminarlyCLIInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var home: URL!
    private var bundleBinary: URL!
    private var bundleSkillDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SeminarlyInstallerTests-\(UUID().uuidString)", isDirectory: true)
        home = tempDir.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // Fake app bundle: the binary must live at a path ending in
        // Contents/Helpers/seminarly-cli for `isInstalled`'s suffix check.
        let helpers = tempDir.appendingPathComponent("Seminarly.app/Contents/Helpers", isDirectory: true)
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        bundleBinary = helpers.appendingPathComponent("seminarly-cli")
        XCTAssertTrue(fm.createFile(atPath: bundleBinary.path, contents: Data("#!/bin/sh\n".utf8)))

        bundleSkillDir = tempDir.appendingPathComponent("Seminarly.app/Contents/Resources/seminarly-cli", isDirectory: true)
        try fm.createDirectory(at: bundleSkillDir, withIntermediateDirectories: true)
        try "skill".write(to: bundleSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if fm.fileExists(atPath: tempDir.path) {
            try fm.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeInstaller(
        environment: [String: String] = [:],
        binary: URL?? = nil,
        skill: URL?? = nil
    ) -> SeminarlyCLIInstaller {
        SeminarlyCLIInstaller(
            home: home,
            bundledBinary: binary ?? .some(bundleBinary),
            bundledSkillDir: skill ?? .some(bundleSkillDir),
            fileManager: fm,
            environment: environment
        )
    }

    private func symlinkTarget(_ url: URL) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: url.path)
    }

    // MARK: - install

    func testInstallCreatesBinaryAndCanonicalSkillSymlinks() throws {
        let installer = makeInstaller()
        try installer.install()

        XCTAssertEqual(symlinkTarget(installer.binLink), bundleBinary.path)
        XCTAssertEqual(symlinkTarget(installer.canonicalSkillDir), bundleSkillDir.path)
        XCTAssertTrue(installer.isInstalled)
    }

    func testInstallSkipsClaudeCompatWhenClaudeDirAbsent() throws {
        let installer = makeInstaller()
        try installer.install()
        XCTAssertNil(symlinkTarget(installer.claudeSkillDir))
    }

    func testInstallCreatesClaudeCompatWhenClaudeDirPresent() throws {
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let installer = makeInstaller()
        try installer.install()
        // Compat dir points at the canonical dir (which in turn points at the bundle).
        XCTAssertEqual(symlinkTarget(installer.claudeSkillDir), installer.canonicalSkillDir.path)
    }

    func testInstallSkipsClaudeCompatWhenClaudeIsRegularFile() throws {
        let installer = makeInstaller()
        // ~/.claude as a plain file must not pull in the optional compat link and
        // abort the whole install — the required binary + skill links still land.
        XCTAssertTrue(fm.createFile(atPath: home.appendingPathComponent(".claude").path, contents: Data()))

        try installer.install() // must NOT throw
        XCTAssertEqual(symlinkTarget(installer.binLink), bundleBinary.path)
        XCTAssertEqual(symlinkTarget(installer.canonicalSkillDir), bundleSkillDir.path)
        XCTAssertNil(symlinkTarget(installer.claudeSkillDir))
        XCTAssertTrue(installer.isInstalled)
    }

    func testInstallIsIdempotent() throws {
        let installer = makeInstaller()
        try installer.install()
        try installer.install() // must not throw on a second run
        XCTAssertEqual(symlinkTarget(installer.binLink), bundleBinary.path)
        XCTAssertTrue(installer.isInstalled)
    }

    func testInstallReplacesPreexistingSymlink() throws {
        let installer = makeInstaller()
        try fm.createDirectory(at: installer.binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stale = tempDir.appendingPathComponent("stale-target")
        XCTAssertTrue(fm.createFile(atPath: stale.path, contents: Data()))
        try fm.createSymbolicLink(at: installer.binLink, withDestinationURL: stale)

        try installer.install()
        XCTAssertEqual(symlinkTarget(installer.binLink), bundleBinary.path)
    }

    func testInstallRefusesToClobberRealFile() throws {
        let installer = makeInstaller()
        try fm.createDirectory(at: installer.binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: installer.binLink.path, contents: Data("real".utf8)))

        XCTAssertThrowsError(try installer.install()) { error in
            guard case SeminarlyCLIInstaller.InstallError.pathOccupied = error else {
                return XCTFail("expected .pathOccupied, got \(error)")
            }
        }
        // The user's real file is untouched.
        XCTAssertEqual(try? String(contentsOf: installer.binLink, encoding: .utf8), "real")
    }

    func testInstallIsAtomicWhenSkillDirOccupied() throws {
        let installer = makeInstaller()
        // A real (non-symlink) directory where the canonical skill would go —
        // e.g. a prior manual setup that copied SKILL.md instead of symlinking.
        try fm.createDirectory(at: installer.canonicalSkillDir, withIntermediateDirectories: true)
        try "mine".write(to: installer.canonicalSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try installer.install()) { error in
            guard case SeminarlyCLIInstaller.InstallError.pathOccupied = error else {
                return XCTFail("expected .pathOccupied, got \(error)")
            }
        }
        // Atomic: the binary symlink must NOT have been created on the failed run.
        XCTAssertNil(symlinkTarget(installer.binLink))
        XCTAssertFalse(installer.isInstalled)
    }

    func testInstallIsAtomicWhenSkillParentIsRegularFile() throws {
        let installer = makeInstaller()
        // ~/.agents is a regular file, so creating ~/.agents/skills can't succeed —
        // and that failure must happen before any symlink is created.
        XCTAssertTrue(fm.createFile(atPath: home.appendingPathComponent(".agents").path, contents: Data()))

        XCTAssertThrowsError(try installer.install())
        XCTAssertNil(symlinkTarget(installer.binLink))
        XCTAssertFalse(installer.isInstalled)
    }

    func testInstallThrowsWhenBundledBinaryMissing() {
        let installer = makeInstaller(binary: .some(nil))
        XCTAssertThrowsError(try installer.install()) { error in
            guard case SeminarlyCLIInstaller.InstallError.bundledBinaryMissing = error else {
                return XCTFail("expected .bundledBinaryMissing, got \(error)")
            }
        }
    }

    func testInstallRefusesTranslocatedBundle() {
        // Gatekeeper App Translocation runs the app from a randomized temp path;
        // symlinking into it would dangle once the user moves the app.
        let translocated = URL(fileURLWithPath:
            "/private/var/folders/ab/AppTranslocation/ABC-123/d/Seminarly.app/Contents/Helpers/seminarly-cli")
        let installer = makeInstaller(binary: .some(translocated))
        XCTAssertFalse(installer.isBundleLocationStable)
        XCTAssertThrowsError(try installer.install()) { error in
            guard case SeminarlyCLIInstaller.InstallError.bundleLocationUnstable = error else {
                return XCTFail("expected .bundleLocationUnstable, got \(error)")
            }
        }
        XCTAssertNil(symlinkTarget(installer.binLink))
    }

    // MARK: - uninstall

    func testUninstallRemovesOurSymlinks() throws {
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let installer = makeInstaller()
        try installer.install()
        XCTAssertTrue(installer.isInstalled)

        installer.uninstall()
        XCTAssertNil(symlinkTarget(installer.binLink))
        XCTAssertNil(symlinkTarget(installer.canonicalSkillDir))
        XCTAssertNil(symlinkTarget(installer.claudeSkillDir))
        XCTAssertFalse(installer.isInstalled)
    }

    func testUninstallLeavesRealDirectoriesAlone() throws {
        let installer = makeInstaller()
        // A real (non-symlink) directory where the canonical skill would go.
        try fm.createDirectory(at: installer.canonicalSkillDir, withIntermediateDirectories: true)
        let sentinel = installer.canonicalSkillDir.appendingPathComponent("user.md")
        try "mine".write(to: sentinel, atomically: true, encoding: .utf8)

        installer.uninstall()
        XCTAssertEqual(try? String(contentsOf: sentinel, encoding: .utf8), "mine")
    }

    // MARK: - isInstalled (dangling)

    func testIsInstalledFalseWhenSymlinkDangles() throws {
        let installer = makeInstaller()
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
        // Delete the bundle the symlink points into.
        try fm.removeItem(at: tempDir.appendingPathComponent("Seminarly.app"))
        XCTAssertFalse(installer.isInstalled)
    }

    func testIsInstalledFalseWhenLinkPointsAtDifferentBundle() throws {
        // A leftover link from another Seminarly.app copy must not read as installed
        // for *this* app — otherwise repair is hidden and a stale CLI keeps running.
        let otherHelpers = tempDir.appendingPathComponent("Other/Seminarly.app/Contents/Helpers", isDirectory: true)
        try fm.createDirectory(at: otherHelpers, withIntermediateDirectories: true)
        let otherBinary = otherHelpers.appendingPathComponent("seminarly-cli")
        XCTAssertTrue(fm.createFile(atPath: otherBinary.path, contents: Data()))

        let installer = makeInstaller()
        try fm.createDirectory(at: installer.binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: installer.binLink, withDestinationURL: otherBinary)
        // The link has the right suffix but points at a different bundle.
        XCTAssertFalse(installer.isInstalled)
    }

    func testIsInstalledFalseWhenSkillLinkMissing() throws {
        let installer = makeInstaller()
        try installer.install()
        XCTAssertTrue(installer.isInstalled)
        // A CLI without its skill is a broken half-install — remove just the skill
        // link; isInstalled must report false so the UI re-offers Install.
        try fm.removeItem(at: installer.canonicalSkillDir)
        XCTAssertNotNil(symlinkTarget(installer.binLink))   // binary link still present
        XCTAssertFalse(installer.isInstalled)
    }

    // MARK: - coding-agent detection

    func testHasAgentConfigDirFalseWhenNonePresent() {
        XCTAssertFalse(makeInstaller().hasAgentConfigDir)
    }

    func testHasAgentConfigDirTrueWhenAgentDirExists() throws {
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        XCTAssertTrue(makeInstaller().hasAgentConfigDir)
    }

    func testHasAgentConfigDirIgnoresPlainFile() throws {
        // A file (not a directory) named like an agent dir shouldn't count.
        XCTAssertTrue(fm.createFile(atPath: home.appendingPathComponent(".cursor").path, contents: Data()))
        XCTAssertFalse(makeInstaller().hasAgentConfigDir)
    }

    // MARK: - PATH detection + opt-in

    func testLocalBinOnPathViaEnvironment() {
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:\(home.appendingPathComponent(".local/bin").path):/bin"])
        XCTAssertTrue(installer.localBinOnPath)
    }

    func testLocalBinOnPathViaShellConfig() throws {
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        XCTAssertTrue(makeInstaller().localBinOnPath)
    }

    func testLocalBinNotOnPath() {
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertFalse(installer.localBinOnPath)
    }

    func testLocalBinOnPathIgnoresCommentedShellLine() throws {
        // A mention only inside a comment must NOT count as already-on-PATH.
        try "# export PATH=\"$HOME/.local/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertFalse(installer.localBinOnPath)
    }

    func testLocalBinOnPathIgnoresNonPathMention() throws {
        // An active line that mentions the dir but doesn't touch PATH (e.g. mkdir)
        // must not count as on-PATH.
        try "mkdir -p \"$HOME/.local/bin\"\n".write(
            to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertFalse(installer.localBinOnPath)
    }

    func testAddLocalBinToPathAppendsWhenOnlyCommentPresent() throws {
        let zshrc = home.appendingPathComponent(".zshrc")
        try "# a note mentioning .local/bin but not active\n".write(to: zshrc, atomically: true, encoding: .utf8)
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertFalse(installer.localBinOnPath)   // comment doesn't count

        try installer.addLocalBinToPath()
        let contents = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(contents.contains(SeminarlyCLIInstaller.pathExportLine))
        XCTAssertTrue(installer.localBinOnPath)    // now an active line exists
    }

    func testLocalBinOnPathIgnoresOtherShellProfile() throws {
        // A zsh user's stale ~/.bash_profile must not count — zsh won't source it.
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let installer = makeInstaller(environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"])
        XCTAssertFalse(installer.localBinOnPath)
    }

    func testLocalBinOnPathViaBashProfileForBashUser() throws {
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let installer = makeInstaller(environment: ["SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"])
        XCTAssertTrue(installer.localBinOnPath)
    }

    func testAddLocalBinToPathAppendsOnceIdempotently() throws {
        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        try installer.addLocalBinToPath()
        try installer.addLocalBinToPath() // second call is a no-op

        let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        let occurrences = zshrc.components(separatedBy: SeminarlyCLIInstaller.pathExportLine).count - 1
        XCTAssertEqual(occurrences, 1)
        // Once written, the shell-config heuristic should report it as on PATH.
        XCTAssertTrue(installer.localBinOnPath)
    }

    func testAddLocalBinToPathPreservesSymlinkedZshrc() throws {
        // Dotfile managers symlink ~/.zshrc to a tracked file; appending must follow
        // the symlink, not replace it with a regular file.
        let dotfiles = home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realZshrc = dotfiles.appendingPathComponent("zshrc")
        try "# managed zshrc\n".write(to: realZshrc, atomically: true, encoding: .utf8)
        let zshrc = home.appendingPathComponent(".zshrc")
        try fm.createSymbolicLink(at: zshrc, withDestinationURL: realZshrc)

        let installer = makeInstaller(environment: ["PATH": "/usr/bin:/bin"])
        try installer.addLocalBinToPath()

        // The symlink is preserved...
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: zshrc.path))
        // ...and the PATH line landed in the symlink target.
        let target = try String(contentsOf: realZshrc, encoding: .utf8)
        XCTAssertTrue(target.contains(SeminarlyCLIInstaller.pathExportLine))
    }

    // MARK: - touchedPaths

    func testTouchedPathsIncludesClaudeOnlyWhenPresent() throws {
        XCTAssertFalse(makeInstaller().touchedPaths.contains { $0.contains(".claude") })
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertTrue(makeInstaller().touchedPaths.contains { $0.contains(".claude") })
    }
}
