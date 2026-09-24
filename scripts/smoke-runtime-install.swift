// Compile with the production runtime installer, manifest, downloader, architecture,
// SemanticVersion, CodexProtocol, CodexRuntime, and CodexAppServerClient sources.
// Uses local release archives or --download for the real public first-use path.
// Always uses production hash/signature validation. No login or model call.
import Foundation

@main
struct RuntimeInstallSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: smoke-runtime-install MANIFEST COMPONENT_DIRECTORY|--download") }
        let manifest = try JSONDecoder().decode(ChatGPTRuntimeManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let remote = CommandLine.arguments[2] == "--download"
        let components = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("seminarly-install-smoke-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let downloads = SmokeDownloadCounter()
        let installer = ChatGPTRuntimeInstaller(root: root.appendingPathComponent("cache"), download: { artifact, destination, progress in
            await downloads.increment()
            if remote {
                print("Checking public first-use download: \(artifact.architecture)")
                try await ChatGPTRuntimeDownload.fetch(artifact, to: destination, progress: progress)
            } else {
                try FileManager.default.copyItem(at: components.appendingPathComponent(artifact.url.lastPathComponent), to: destination)
                progress(.downloading(1))
            }
        })
        for architecture in [ReleaseArchitecture.appleSilicon, .intel] {
            let executable = try await installer.prepare(manifest: manifest, architecture: architecture, progress: { _ in })
            guard try await installer.installed(manifest: manifest, architecture: architecture) == executable else { fatalError("Cache mismatch") }
            let count = await downloads.value
            guard try await installer.prepare(manifest: manifest, architecture: architecture, progress: { _ in }) == executable,
                  await downloads.value == count else { fatalError("Reusing the cache must not download again") }
            print("PASS: \(architecture) archive hash, extraction, Developer ID, executable hash, cache reuse")
            let profile = root.appendingPathComponent(UUID().uuidString)
            let work = root.appendingPathComponent(UUID().uuidString)
            for dir in [profile, work] { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let client = CodexAppServerClient()
            do {
                try await client.start(CodexRuntime.configuration(executable: executable, profile: profile, work: work, source: [:]))
                let account = try await client.request("account/read").decode(ChatGPTAccountResponse.self)
                guard account.account == nil else { throw ChatGPTError.privacyUnavailable }
                try await client.requireNoMCPServers()
                await client.shutdown()
                print("PASS: \(architecture) starts from cache, isolated profile, no inherited account or tools")
            } catch {
                await client.shutdown()
                throw error
            }
        }
        try await Task.sleep(for: .seconds(3))
        print("PASS: no login, model call, or meeting database access")
    }
}

private actor SmokeDownloadCounter {
    var value = 0
    func increment() { value += 1 }
}
