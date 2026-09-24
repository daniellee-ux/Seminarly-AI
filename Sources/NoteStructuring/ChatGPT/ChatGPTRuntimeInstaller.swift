import Foundation
import CryptoKit
import Security

/// A private, versioned cache outside the app bundle survives normal Seminarly updates.
/// It never searches PATH or uses a separately installed developer tool.
actor ChatGPTRuntimeInstaller {
    static let shared = ChatGPTRuntimeInstaller()
    typealias Progress = @Sendable (ChatGPTPreparation) -> Void
    typealias Download = @Sendable (ChatGPTRuntimeManifest.Artifact, URL, @escaping Progress) async throws -> Void
    typealias Verify = @Sendable (URL, String) throws -> Void

    private let root: URL
    private let download: Download
    private let verifySignature: Verify
    private var preparing = false

    init(root: URL? = nil,
         download: @escaping Download = { try await ChatGPTRuntimeDownload.fetch($0, to: $1, progress: $2) },
         verifySignature: @escaping Verify = { try ChatGPTRuntimeInstaller.verifySignature($0, team: $1) }) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.seminarly/ChatGPTComponents", isDirectory: true)
        self.download = download
        self.verifySignature = verifySignature
    }

    func installed(manifest: ChatGPTRuntimeManifest, architecture: ReleaseArchitecture = .current) throws -> URL? {
        try manifest.validate()
        let artifact = try manifest.artifact(for: architecture)
        let directory = directory(for: artifact, manifest: manifest)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try Self.checkDirectory(root)
        return try validate(directory, manifest: manifest, artifact: artifact)
    }

    func prepare(manifest: ChatGPTRuntimeManifest, architecture: ReleaseArchitecture = .current,
                 progress: @escaping Progress) async throws -> URL {
        try manifest.validate()
        try Task.checkCancellation()
        // AccountStore serializes sign-in; also fail closed for accidental concurrent callers.
        guard !preparing else { throw ChatGPTError.runtimeDownloadFailed }
        preparing = true
        defer { preparing = false }
        let fm = FileManager.default
        let artifact = try manifest.artifact(for: architecture)
        let destination = directory(for: artifact, manifest: manifest)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.checkDirectory(root)
        if let existing = try? installed(manifest: manifest, architecture: architecture) { return existing }

        let stage = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("component.tar.xz")
        try await download(artifact, archive, progress)
        try Task.checkCancellation()
        progress(.verifying)
        try Self.verifyFile(archive, bytes: artifact.archiveBytes, digest: artifact.archiveSHA256)
        // Never unpack until the archive matches the hash sealed into the signed app.
        try await Self.extract(archive, into: stage)
        try Task.checkCancellation()
        _ = try validate(stage, manifest: manifest, artifact: artifact)
        try fm.removeItem(at: archive)
        // Only a corrupt cache entry for this exact pin is replaced. The sign-in profile
        // and all other versions remain untouched. A crash cannot publish a partial install.
        if fm.fileExists(atPath: destination.path) {
            let rejected = root.appendingPathComponent(".rejected-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: rejected)
            defer { try? fm.removeItem(at: rejected) }
            try fm.moveItem(at: stage, to: destination)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
        return try validate(destination, manifest: manifest, artifact: artifact)
    }

    private func directory(for artifact: ChatGPTRuntimeManifest.Artifact, manifest: ChatGPTRuntimeManifest) -> URL {
        root.appendingPathComponent("\(manifest.version)-\(manifest.revision)-\(artifact.architecture)-\(artifact.archiveSHA256)", isDirectory: true)
    }

    private func validate(_ directory: URL, manifest: ChatGPTRuntimeManifest,
                          artifact: ChatGPTRuntimeManifest.Artifact) throws -> URL {
        let bundle = directory.appendingPathComponent("ChatGPTConnection.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/seminarly-chatgpt")
        for path in [directory, bundle, bundle.appendingPathComponent("Contents"), bundle.appendingPathComponent("Contents/MacOS")] {
            try Self.checkDirectory(path)
        }
        try Self.verifyFile(executable, bytes: artifact.executableBytes, digest: artifact.executableSHA256)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ChatGPTError.runtimeVerificationFailed }
        try verifySignature(bundle, manifest.teamIdentifier)
        return executable
    }

    static func checkDirectory(_ url: URL) throws {
        // Reject symlink parents as well as the final component. This also catches a
        // cache root swapped after creation; canonical /private temp roots work in tests.
        // standardizedFileURL rewrites /private/var back to the /var symlink on
        // macOS, so preserve the caller's path while inspecting each ancestor.
        var cursor = url
        while cursor.path != "/" {
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ChatGPTError.runtimeVerificationFailed }
            cursor.deleteLastPathComponent()
        }
    }

    static func verifyFile(_ url: URL, bytes: Int64, digest: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == Int(bytes) else {
            throw ChatGPTError.runtimeVerificationFailed
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ChatGPTError.runtimeVerificationFailed
        }
    }

    static func verifySignature(_ bundle: URL, team: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"ai.seminarly.chatgpt\""
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw ChatGPTError.runtimeVerificationFailed
        }
    }

    private static func extract(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xJf", archive.path, "-C", directory.path, "--no-same-owner"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Actor-isolated synchronous launch; cancellation is checked while polling,
        // and no continuation or raw subprocess output escapes into the UI.
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw ChatGPTError.runtimeVerificationFailed }
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw error
        }
    }
}
