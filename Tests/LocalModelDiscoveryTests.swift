import Foundation
import XCTest
@testable import Seminarly

final class LocalModelDiscoveryTests: XCTestCase {
    private let revisionA = String(repeating: "a", count: 40)
    private let revisionB = String(repeating: "b", count: 40)
    private let variant = "openai_whisper-large-v3-v20240930_turbo"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func bundles(at url: URL) throws {
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
        }
    }

    private func tokenizer(at url: URL) throws {
        try write("{}", at: url.appendingPathComponent("tokenizer.json"))
        try write("{}", at: url.appendingPathComponent("tokenizer_config.json"))
    }

    func testEnvironmentRootsAndDefaultAreDiscoveredWithoutReadingShellFiles() {
        let home = URL(fileURLWithPath: "/fixture/user")
        let discovery = LocalModelDiscovery.standard(home: home, documents: home.appendingPathComponent("Documents"),
            environment: ["HF_HUB_CACHE": "/external/cache", "HF_HOME": "~/hf", "XDG_CACHE_HOME": "/ignored"])
        XCTAssertEqual(discovery.hubCacheRoots.map(\.path), ["/external/cache", "/fixture/user/hf/hub", "/fixture/user/.cache/huggingface/hub"])
        let xdg = LocalModelDiscovery.standard(home: home, documents: home,
            environment: ["HF_HUB_CACHE": "relative-is-ignored", "XDG_CACHE_HOME": "/custom"])
        XCTAssertEqual(xdg.hubCacheRoots.first?.path, "/custom/huggingface/hub")
    }

    func testSnapshotPrioritySymlinksAndUnsafeRef() throws {
        let root = try temporaryRoot()
        let hub = root.appendingPathComponent("hub")
        let repo = hub.appendingPathComponent("models--moona3k--mlx-qwen3-asr-0.6b-4bit")
        let first = repo.appendingPathComponent("snapshots/" + revisionA)
        let second = repo.appendingPathComponent("snapshots/" + revisionB)
        try tokenizer(at: first)
        try tokenizer(at: second)
        try write(revisionB, at: repo.appendingPathComponent("refs/main"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: hub)
        let discovery = LocalModelDiscovery(swiftCacheRoot: root.appendingPathComponent("swift"), hubCacheRoots: [hub, alias])
        XCTAssertEqual(discovery.repositoryDirectories(QwenModelStore.modelID, preferredRevision: revisionA).map(\.path), [first.path, second.path])
        try write("../../outside", at: repo.appendingPathComponent("refs/main"))
        try tokenizer(at: repo.appendingPathComponent("snapshots/.partial"))
        XCTAssertEqual(discovery.repositoryDirectories(QwenModelStore.modelID).map(\.path), [first.path, second.path])
    }

    func testWhisperCombinesModelAndTokenizerFromDifferentCaches() throws {
        let root = try temporaryRoot()
        let swift = root.appendingPathComponent("swift")
        let hub = root.appendingPathComponent("hub")
        let model = hub.appendingPathComponent("models--argmaxinc--whisperkit-coreml/snapshots/" + revisionA + "/" + variant)
        let token = swift.appendingPathComponent("models/openai/whisper-large-v3")
        try bundles(at: model)
        try tokenizer(at: token)
        let results = LocalModelDiscovery(swiftCacheRoot: swift, hubCacheRoots: [hub]).whisperInstallations(for: variant)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.model.path, model.path)
        XCTAssertEqual(results.first?.tokenizer?.path, token.path)
    }

    func testWhisperBundledTokenizerAndMissingTokenizerDoNotDiscardWeights() throws {
        let root = try temporaryRoot()
        let model = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + variant)
        try bundles(at: model)
        let discovery = LocalModelDiscovery(swiftCacheRoot: root, hubCacheRoots: [])
        XCTAssertEqual(discovery.whisperInstallations(for: variant).first?.model.path, model.path)
        XCTAssertNil(discovery.whisperInstallations(for: variant).first?.tokenizer)
        try tokenizer(at: model)
        XCTAssertEqual(discovery.whisperInstallations(for: variant).first?.tokenizer?.path, model.path)
        try write("broken", at: model.appendingPathComponent("tokenizer.json"))
        XCTAssertNil(discovery.whisperInstallations(for: variant).first?.tokenizer)
    }

    func testIncompleteAndUnsupportedWhisperModelsAreRejected() throws {
        let root = try temporaryRoot()
        let model = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + variant)
        try bundles(at: model)
        try FileManager.default.removeItem(at: model.appendingPathComponent("TextDecoder.mlmodelc"))
        let discovery = LocalModelDiscovery(swiftCacheRoot: root, hubCacheRoots: [])
        XCTAssertTrue(discovery.whisperInstallations(for: variant).isEmpty)
        XCTAssertTrue(discovery.whisperInstallations(for: "../../custom").isEmpty)
    }

    func testTokenizerStagingDoesNotModifyReadOnlySnapshot() throws {
        let root = try temporaryRoot()
        let source = root.appendingPathComponent("snapshot")
        let cache = root.appendingPathComponent("owned")
        try tokenizer(at: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }
        try LocalModelDiscovery.cacheWhisperTokenizer(from: source, repo: "openai/whisper-large-v3", cacheRoot: cache)
        let copied = cache.appendingPathComponent("models/openai/whisper-large-v3/tokenizer.json")
        XCTAssertEqual(try Data(contentsOf: copied), Data("{}".utf8))
        try Data("changed".utf8).write(to: copied, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("tokenizer.json")), Data("{}".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted(), ["tokenizer.json", "tokenizer_config.json"])
    }
}
