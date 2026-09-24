import Foundation

/// This manifest is sealed into Seminarly's code signature, never fetched from a server.
/// Updating executable code requires shipping a new app with new pins.
struct ChatGPTRuntimeManifest: Codable, Sendable {
    let schemaVersion: Int
    let version: String
    let revision: Int
    let teamIdentifier: String
    let artifacts: [Artifact]

    struct Artifact: Codable, Sendable {
        let architecture: String
        let url: URL
        let archiveSHA256: String
        let archiveBytes: Int64
        let executableSHA256: String
        let executableBytes: Int64
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "ChatGPTRuntime", withExtension: "json") else {
            throw ChatGPTError.runtimeMissing
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        let alphanumeric = CharacterSet.alphanumerics
        guard schemaVersion == 1, revision > 0,
              SemanticVersion(version) != nil, version.allSatisfy({ $0.isNumber || $0 == "." }),
              teamIdentifier.count == 10, teamIdentifier.unicodeScalars.allSatisfy(alphanumeric.contains),
              artifacts.count == 2, Set(artifacts.map(\.architecture)) == ["arm64", "x86_64"] else {
            throw ChatGPTError.runtimeVerificationFailed
        }
        for artifact in artifacts {
            let prefix = "/daniellee-ux/Seminarly-AI/releases/download/"
            guard artifact.url.scheme == "https", artifact.url.host == "github.com",
                  artifact.url.user == nil, artifact.url.password == nil, artifact.url.port == nil,
                  artifact.url.query == nil, artifact.url.fragment == nil,
                  artifact.url.path.hasPrefix(prefix),
                  artifact.url.lastPathComponent == "ChatGPTConnection-\(version)-\(revision)-\(artifact.architecture).tar.xz",
                  Self.isDigest(artifact.archiveSHA256), Self.isDigest(artifact.executableSHA256),
                  (1...100_000_000).contains(artifact.archiveBytes),
                  (1...300_000_000).contains(artifact.executableBytes) else {
                throw ChatGPTError.runtimeVerificationFailed
            }
        }
    }

    func artifact(for architecture: ReleaseArchitecture = .current) throws -> Artifact {
        let name = architecture == .appleSilicon ? "arm64" : "x86_64"
        guard let artifact = artifacts.first(where: { $0.architecture == name }) else {
            throw ChatGPTError.runtimeVerificationFailed
        }
        return artifact
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum ChatGPTPreparation: Equatable, Sendable {
    case downloading(Double)
    case verifying

    var message: String {
        switch self {
        case .downloading: "Preparing ChatGPT…"
        case .verifying: "Verifying ChatGPT connection…"
        }
    }
}
