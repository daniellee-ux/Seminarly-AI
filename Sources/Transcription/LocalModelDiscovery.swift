import Foundation

/// Searches known cache layouts only. Model files owned by other tools stay read-only.
struct LocalModelDiscovery: Sendable {
    let swiftCacheRoot: URL
    let hubCacheRoots: [URL]

    static var current: Self {
        let fm = FileManager.default
        return standard(home: fm.homeDirectoryForCurrentUser,
                        documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                        environment: ProcessInfo.processInfo.environment)
    }

    static func standard(home: URL, documents: URL, environment: [String: String]) -> Self {
        func path(_ key: String) -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        var roots: [URL] = []
        if let cache = path("HF_HUB_CACHE") ?? path("HUGGINGFACE_HUB_CACHE") { roots.append(cache) }
        if let hfHome = path("HF_HOME") {
            roots.append(hfHome.appendingPathComponent("hub"))
        } else if let xdg = path("XDG_CACHE_HOME") {
            roots.append(xdg.appendingPathComponent("huggingface/hub"))
        }
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))
        return Self(swiftCacheRoot: documents.appendingPathComponent("huggingface"),
                    hubCacheRoots: unique(roots))
    }

    /// Swift Hub's flat layout, then Python Hub snapshots. No recursive home scan,
    /// shell startup files, network calls, or third-party daemon is involved.
    func repositoryDirectories(_ repo: String, preferredRevision: String? = nil) -> [URL] {
        let fm = FileManager.default
        var folders = [swiftCacheRoot.appendingPathComponent("models/\(repo)")]
        for root in hubCacheRoots {
            let repository = root.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            let snapshots = repository.appendingPathComponent("snapshots")
            var revisions: [String] = []
            if let preferredRevision { revisions.append(preferredRevision) }
            let ref = repository.appendingPathComponent("refs/main")
            if let size = try? ref.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256,
               let value = try? String(contentsOf: ref, encoding: .utf8) {
                revisions.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            revisions += ((try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []).sorted()
            // Only commit directories are followed; refs cannot escape the cache.
            for revision in revisions.filter({ Self.isRevision($0) }) {
                folders.append(snapshots.appendingPathComponent(revision))
            }
        }
        return Self.unique(folders).filter { Self.isDirectory($0) }
    }

    struct WhisperInstallation: Sendable {
        let model: URL
        let tokenizer: URL?
    }

    func whisperInstallations(for variant: String) -> [WhisperInstallation] {
        guard let repo = Self.whisperTokenizerRepo(for: variant) else { return [] }
        let tokenizers = repositoryDirectories(repo)
            + repositoryDirectories(repo.replacingOccurrences(of: "openai/", with: "openai-community/"))
        return repositoryDirectories("argmaxinc/whisperkit-coreml").compactMap { root in
            let model = root.appendingPathComponent(variant)
            guard Self.hasWhisperBundles(model) else { return nil }
            let tokenizer = ([model] + tokenizers).first(where: Self.hasTokenizer)
            return WhisperInstallation(model: model, tokenizer: tokenizer)
        }
    }

    static func whisperTokenizerRepo(for variant: String) -> String? {
        switch variant {
        case "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-large-v3-v20240930",
             "distil-whisper_distil-large-v3_turbo": "openai/whisper-large-v3"
        case "openai_whisper-small": "openai/whisper-small"
        case "openai_whisper-base": "openai/whisper-base"
        case "openai_whisper-tiny": "openai/whisper-tiny"
        default: nil
        }
    }

    static func hasWhisperBundles(_ folder: URL) -> Bool {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
            .allSatisfy { isDirectory(folder.appendingPathComponent($0)) }
    }

    static func hasTokenizer(_ folder: URL) -> Bool {
        ["tokenizer.json", "tokenizer_config.json"].allSatisfy { name in
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
            return true
        }
    }

    /// WhisperKit may download a missing tokenizer even with download:false.
    /// Stage only these small files in our existing cache, so such a repair can
    /// never write into a discovered model/snapshot directory.
    static func cacheWhisperTokenizer(from source: URL, repo: String, cacheRoot: URL) throws {
        let target = cacheRoot.appendingPathComponent("models/\(repo)")
        guard source.resolvingSymlinksInPath().path != target.resolvingSymlinksInPath().path else { return }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data(contentsOf: source.appendingPathComponent(name))
                .write(to: target.appendingPathComponent(name), options: .atomic)
        }
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRevision(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
