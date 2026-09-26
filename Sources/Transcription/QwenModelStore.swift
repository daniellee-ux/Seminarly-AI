import Foundation
import CryptoKit

/// One immutable model recipe. Downloads are optional and live outside the app.
enum QwenModelStore {
    static let modelID = "moona3k/mlx-qwen3-asr-0.6b-4bit"
    static let revision = "4c59c533f95c84afb796655e814709034f826f04"
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    struct File: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }
    static let files: [File] = [
        File(name: "config.json", size: 6193, sha256: "76d3ae4601ce939830b2517f4a6cadb86cc51316c3900af6b020b051c21a478c"),
        File(name: "merges.txt", size: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        File(name: "quantization_config.json", size: 60, sha256: "067339b858243ad9d5e22764b3b82c759a765c9f0aadfe4939d0c233f15b9e7d"),
        File(name: "tokenizer_config.json", size: 12487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        File(name: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        File(name: "weights.safetensors", size: 537626967, sha256: "9a62bb9830dcbcd0cf1c1f40200161d4e5f007a4cd99b83111902890a9f087d3"),
    ]
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.seminarly/Models/Qwen3-ASR-0.6B/\(revision)")
    }

    static func prepare(at directory: URL = directory,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.name)
            if try !isValid(destination, file: file) {
                let before = completed
                let delegate = DownloadProgress { bytes in
                    progress(Double(before + min(bytes, file.size)) / Double(total))
                }
                let url = URL(string: "https://huggingface.co/\(modelID)/resolve/\(revision)/\(file.name)")!
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
                defer { try? fm.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      try isValid(temporary, file: file) else {
                    throw StoreError.invalidDownload(file.name)
                }
                try Task.checkCancellation()
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temporary, to: destination)
            }
            completed += file.size
            progress(Double(completed) / Double(total))
        }
        return directory
    }

    /// Verify complete files before loading; valid local installs never contact the network.
    static func isValid(_ url: URL, file: File) throws -> Bool {
        // URL resource values may cache an old length across a repaired download.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64) -> Void
        init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    enum StoreError: LocalizedError {
        case invalidDownload(String)
        case unsupportedHardware
        var errorDescription: String? {
            switch self {
            case .invalidDownload(let file): "The Qwen model download is incomplete or damaged (\(file)). Please retry."
            case .unsupportedHardware: "Qwen requires an Apple Silicon Mac. Choose a Whisper model on this Mac."
            }
        }
    }
}
