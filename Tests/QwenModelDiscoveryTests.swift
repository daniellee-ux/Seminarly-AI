import Foundation
import CryptoKit
import XCTest
@testable import Seminarly

final class QwenModelDiscoveryTests: XCTestCase {
    private enum TestError: Error { case unexpectedDownload }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ name: String, contents: String) -> QwenModelStore.File {
        let data = Data(contents.utf8)
        return .init(name: name, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testCompleteReadOnlySnapshotWithBlobSymlinkAvoidsDownloadAndCopy() async throws {
        let root = try root()
        let snapshot = root.appendingPathComponent("snapshot")
        let owned = root.appendingPathComponent("owned")
        let blob = root.appendingPathComponent("blobs/hash")
        try write("abc", to: blob)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("weights.safetensors"), withDestinationURL: blob)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: snapshot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot.path) }
        let result = try await QwenModelStore.prepare(at: owned, candidates: [snapshot],
            manifest: [file("weights.safetensors", contents: "abc")],
            download: { _, _ in throw TestError.unexpectedDownload }, progress: { _ in })
        XCTAssertEqual(result, snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.path), ["weights.safetensors"])
    }

    func testCorruptCandidateIsSkippedAndOwnedValidInstallWins() async throws {
        let root = try root()
        let bad = root.appendingPathComponent("bad")
        let good = root.appendingPathComponent("good")
        let owned = root.appendingPathComponent("owned")
        try write("abd", to: bad.appendingPathComponent("weights"))
        try write("abc", to: good.appendingPathComponent("weights"))
        let manifest = [file("weights", contents: "abc")]
        let found = try await QwenModelStore.prepare(at: owned, candidates: [bad, good], manifest: manifest,
            download: { _, _ in throw TestError.unexpectedDownload }, progress: { _ in })
        XCTAssertEqual(found, good)
        try write("abc", to: owned.appendingPathComponent("weights"))
        let cached = try await QwenModelStore.prepare(at: owned, candidates: [good], manifest: manifest,
            download: { _, _ in throw TestError.unexpectedDownload }, progress: { _ in })
        XCTAssertEqual(cached, owned)
    }

    func testPartialSnapshotReusesWeightsAndDownloadsOnlyMissingConfiguration() async throws {
        let root = try root()
        let snapshot = root.appendingPathComponent("snapshot")
        let owned = root.appendingPathComponent("owned")
        try write("abc", to: snapshot.appendingPathComponent("weights"))
        let manifest = [file("weights", contents: "abc"), file("config", contents: "{}")]
        let result = try await QwenModelStore.prepare(at: owned, candidates: [snapshot], manifest: manifest,
            download: { file, progress in
                guard file.name == "config" else { throw TestError.unexpectedDownload }
                let temp = root.appendingPathComponent("download")
                try Data("{}".utf8).write(to: temp)
                progress(2)
                return temp
            }, progress: { _ in })
        XCTAssertEqual(result, owned)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: owned.appendingPathComponent("weights").path), snapshot.appendingPathComponent("weights").resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config").path))
    }

    func testDeletedExternalSourceRepairsDanglingLinkInOwnedCacheOnly() async throws {
        let root = try root()
        let owned = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("deleted/weights")
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("weights"), withDestinationURL: missing)
        let result = try await QwenModelStore.prepare(at: owned, candidates: [], manifest: [file("weights", contents: "abc")],
            download: { _, _ in
                let temp = root.appendingPathComponent("download")
                try Data("abc".utf8).write(to: temp)
                return temp
            }, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("weights")), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: result.appendingPathComponent("weights").path))
    }

    func testInvalidDownloadIsNotPublished() async throws {
        let root = try root()
        let owned = root.appendingPathComponent("owned")
        do {
            _ = try await QwenModelStore.prepare(at: owned, candidates: [], manifest: [file("weights", contents: "abc")],
                download: { _, _ in
                    let temp = root.appendingPathComponent("download")
                    try Data("bad".utf8).write(to: temp)
                    return temp
                }, progress: { _ in })
            XCTFail("Expected checksum validation failure")
        } catch QwenModelStore.StoreError.invalidDownload { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owned.path), [])
    }

    func testCancelledDiscoveryNeverDownloadsOrPublishes() async throws {
        let root = try root()
        let owned = root.appendingPathComponent("owned")
        let manifest = [file("weights", contents: "abc")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await QwenModelStore.prepare(at: owned, candidates: [], manifest: manifest,
                download: { _, _ in throw TestError.unexpectedDownload }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }
}
