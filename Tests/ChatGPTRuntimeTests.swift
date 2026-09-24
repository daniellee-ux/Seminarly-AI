import XCTest
import CryptoKit
@testable import Seminarly

@MainActor
final class ChatGPTRuntimeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("seminarly-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture() throws -> (root: URL, archive: URL, manifest: ChatGPTRuntimeManifest) {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let executable = source.appendingPathComponent("ChatGPTConnection.app/Contents/MacOS/seminarly-chatgpt")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("A test fixture, never executed".utf8)
        try bytes.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archive = root.appendingPathComponent("fixture.tar.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cJf", archive.path, "-C", source.path, "ChatGPTConnection.app"]
        process.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let packed = try Data(contentsOf: archive)
        let artifacts = ["arm64", "x86_64"].map { arch in
            ChatGPTRuntimeManifest.Artifact(architecture: arch,
                url: URL(string: "https://github.com/daniellee-ux/Seminarly-AI/releases/download/v0.1.12/ChatGPTConnection-0.156.1-1-\(arch).tar.xz")!,
                archiveSHA256: Self.digest(packed), archiveBytes: Int64(packed.count),
                executableSHA256: Self.digest(bytes), executableBytes: Int64(bytes.count))
        }
        return (root, archive, .init(schemaVersion: 1, version: "0.156.1", revision: 1, teamIdentifier: "TESTTEAM12", artifacts: artifacts))
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testBaseAppHasPinsAndNoticesButNoHeavyRuntime() throws {
        let manifest = try ChatGPTRuntimeManifest.load()
        try manifest.validate()
        XCTAssertEqual(try manifest.artifact(for: .appleSilicon).architecture, "arm64")
        XCTAssertEqual(try manifest.artifact(for: .intel).architecture, "x86_64")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/seminarly-chatgpt").path))
        let notices = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ThirdParty/OpenAICodex")
        XCTAssertTrue(try String(contentsOf: notices.appendingPathComponent("LICENSE"), encoding: .utf8).contains("Apache License"))
        XCTAssertTrue(try String(contentsOf: notices.appendingPathComponent("NOTICE"), encoding: .utf8).contains("OpenAI"))
    }

    func testInstallThenReuseWithoutNetworkAndRepairCorruption() async throws {
        let (root, archive, manifest) = try fixture()
        let count = DownloadCounter()
        let installer = ChatGPTRuntimeInstaller(root: root.appendingPathComponent("cache"), download: { _, target, progress in
            await count.increment()
            progress(.downloading(1))
            try FileManager.default.copyItem(at: archive, to: target)
        }, verifySignature: { _, _ in })
        let missing = try await installer.installed(manifest: manifest)
        XCTAssertNil(missing)
        let executable = try await installer.prepare(manifest: manifest, progress: { _ in })
        let again = try await installer.prepare(manifest: manifest, progress: { _ in })
        XCTAssertEqual(executable, again)
        let once = await count.value
        XCTAssertEqual(once, 1)
        try Data("corrupt".utf8).write(to: executable)
        do { _ = try await installer.installed(manifest: manifest); XCTFail("Must reject tampered cache") }
        catch { XCTAssertEqual(error as? ChatGPTError, .runtimeVerificationFailed) }
        _ = try await installer.prepare(manifest: manifest, progress: { _ in })
        let twice = await count.value
        XCTAssertEqual(twice, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path).contains { $0.hasPrefix(".") })
    }

    func testBadDownloadIsNotExtractedOrInstalled() async throws {
        let (root, _, manifest) = try fixture()
        let installer = ChatGPTRuntimeInstaller(root: root.appendingPathComponent("cache"), download: { _, target, _ in
            try Data("not an archive".utf8).write(to: target)
        }, verifySignature: { _, _ in XCTFail("Must not reach code validation") })
        do { _ = try await installer.prepare(manifest: manifest, progress: { _ in }); XCTFail("Must fail closed") }
        catch { XCTAssertEqual(error as? ChatGPTError, .runtimeVerificationFailed) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path), [])
    }

    func testCancellationCleansPartialDownloadAndCanRetry() async throws {
        let (root, archive, manifest) = try fixture()
        let count = DownloadCounter()
        let installer = ChatGPTRuntimeInstaller(root: root.appendingPathComponent("cache"), download: { _, target, _ in
            await count.increment()
            try FileManager.default.copyItem(at: archive, to: target)
            if await count.value == 1 { try await Task.sleep(for: .seconds(30)) }
        }, verifySignature: { _, _ in })
        let task = Task { try await installer.prepare(manifest: manifest, progress: { _ in }) }
        for _ in 0..<100 {
            if await count.value > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path), [])
        _ = try await installer.prepare(manifest: manifest, progress: { _ in })
    }

    func testWrongPublisherFailsAndKeepsCacheEmpty() async throws {
        let (root, archive, manifest) = try fixture()
        let installer = ChatGPTRuntimeInstaller(root: root.appendingPathComponent("cache"), download: { _, target, _ in
            try FileManager.default.copyItem(at: archive, to: target)
        }, verifySignature: { _, _ in throw ChatGPTError.runtimeVerificationFailed })
        do { _ = try await installer.prepare(manifest: manifest, progress: { _ in }); XCTFail("Must reject publisher") }
        catch { XCTAssertEqual(error as? ChatGPTError, .runtimeVerificationFailed) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path), [])
    }

    func testSymlinkRootRejectedWithoutDownloading() async throws {
        let (root, _, manifest) = try fixture()
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: root.appendingPathComponent("source"))
        let installer = ChatGPTRuntimeInstaller(root: cache, download: { _, _, _ in XCTFail("Must not download") })
        do { _ = try await installer.prepare(manifest: manifest, progress: { _ in }); XCTFail("Must reject symlink") }
        catch { XCTAssertEqual(error as? ChatGPTError, .runtimeVerificationFailed) }
    }

    func testRejectsNonRegularFilesAndMismatchedHash() throws {
        let (root, archive, manifest) = try fixture()
        let artifact = try manifest.artifact()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        XCTAssertThrowsError(try ChatGPTRuntimeInstaller.verifyFile(link, bytes: artifact.archiveBytes, digest: artifact.archiveSHA256))
        XCTAssertThrowsError(try ChatGPTRuntimeInstaller.verifyFile(archive, bytes: artifact.archiveBytes, digest: String(repeating: "0", count: 64)))
    }

    func testRedirectsRejectHTTPAndUnrelatedHosts() {
        for url in ["http://github.com/file", "https://evil.example/file", "https://github.com.evil.example/file", "https://user@github.com/file", "https://github.com:444/file"] {
            XCTAssertFalse(ChatGPTRuntimeDownload.permits(URL(string: url)))
        }
        XCTAssertTrue(ChatGPTRuntimeDownload.permits(URL(string: "https://release-assets.githubusercontent.com/asset?signature=example")))
    }

    func testManifestRejectsUnsupportedSchemaAndDuplicateArchitecture() throws {
        let (_, _, manifest) = try fixture()
        let invalid = ChatGPTRuntimeManifest(schemaVersion: 2, version: manifest.version, revision: 1,
            teamIdentifier: manifest.teamIdentifier, artifacts: manifest.artifacts)
        XCTAssertThrowsError(try invalid.validate())
        let duplicate = ChatGPTRuntimeManifest(schemaVersion: 1, version: manifest.version, revision: 1,
            teamIdentifier: manifest.teamIdentifier, artifacts: [manifest.artifacts[0], manifest.artifacts[0]])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testStandaloneConfigurationDoesNotRequireCLIOrNode() {
        let config = CodexRuntime.configuration(executable: URL(fileURLWithPath: "/test/seminarly-chatgpt"),
                                              profile: URL(fileURLWithPath: "/tmp/profile"), work: URL(fileURLWithPath: "/tmp/work"),
                                              source: ["PATH": "/opt/homebrew/bin", "NODE_PATH": "/private/node", "OPENAI_API_KEY": "secret"])
        XCTAssertEqual(Array(config.arguments.suffix(2)), ["--listen", "stdio://"])
        XCTAssertFalse(config.arguments.contains("app-server"))
        XCTAssertEqual(config.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(config.environment["NODE_PATH"])
        XCTAssertNil(config.environment["OPENAI_API_KEY"])
    }

    func testErrorsDoNotAskUsersToInstallDeveloperTools() {
        for error in [ChatGPTError.runtimeMissing, .runtimeDownloadFailed, .runtimeVerificationFailed, .runtimeTooOld] {
            XCTAssertFalse(error.localizedDescription.lowercased().contains("codex"))
            XCTAssertFalse(error.localizedDescription.lowercased().contains("executable"))
        }
    }
}

private actor DownloadCounter {
    var value = 0
    func increment() { value += 1 }
}
