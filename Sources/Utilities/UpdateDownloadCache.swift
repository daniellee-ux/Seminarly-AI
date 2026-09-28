import Foundation

/// Metadata comes only from Sparkle's verified, architecture-specific appcast.
/// Cached bytes are still untrusted: Sparkle verifies the archive before extraction.
struct UpdateDownload: Codable, Equatable, Sendable {
    let version: String
    let displayVersion: String
    let url: URL
    let contentLength: UInt64
}

struct CachedUpdate: Codable, Equatable, Sendable {
    let update: UpdateDownload
    let sourceBuild: String
    let filename: String
    let fileURL: URL

    var hasExpectedSize: Bool {
        // URL.resourceValues can retain a stale size after another process
        // modifies or removes the file. Read fresh filesystem attributes here.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.uint64Value == update.contentLength
    }
}

actor UpdateDownloadCache {
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private let directory: URL
    private let sourceBuild: String
    private let download: Download

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.seminarly.Seminarly/Updates", isDirectory: true),
         sourceBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
         download: @escaping Download = { try await URLSession.shared.download(for: $0) }) {
        self.directory = directory
        self.sourceBuild = sourceBuild
        self.download = download
    }

    func existingDownload() -> CachedUpdate? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("download.json")),
              let cached = try? JSONDecoder().decode(CachedUpdate.self, from: data),
              cached.sourceBuild == sourceBuild,
              UUID(uuidString: cached.filename) != nil,
              cached.fileURL == directory.appendingPathComponent(cached.filename),
              cached.hasExpectedSize
        else { return nil }
        return cached
    }

    func prepare(_ update: UpdateDownload) async throws -> CachedUpdate {
        try Task.checkCancellation()
        if let cached = existingDownload(), cached.update == update { return cached }
        guard update.url.scheme == "https", update.contentLength > 0,
              update.contentLength <= 2 * 1_024 * 1_024 * 1_024 else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: update.url)
        request.timeoutInterval = 120
        request.setValue("Seminarly", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await download(request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize.map(UInt64.init) == update.contentLength else {
            throw URLError(.cannotDecodeContentData)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = UUID().uuidString
        let fileURL = directory.appendingPathComponent(filename)
        let cached = CachedUpdate(update: update, sourceBuild: sourceBuild, filename: filename, fileURL: fileURL)
        try fm.moveItem(at: temporaryURL, to: fileURL)
        do {
            try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("download.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: fileURL)
            throw error
        }
        // Bound disk use across app releases, including obsolete delta bases.
        for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent != filename && UUID(uuidString: file.lastPathComponent) != nil {
            try? fm.removeItem(at: file)
        }
        return cached
    }

    func discard(_ cached: CachedUpdate) {
        let metadata = directory.appendingPathComponent("download.json")
        guard let data = try? Data(contentsOf: metadata),
              (try? JSONDecoder().decode(CachedUpdate.self, from: data)) == cached,
              UUID(uuidString: cached.filename) != nil,
              cached.fileURL == directory.appendingPathComponent(cached.filename) else { return }
        try? FileManager.default.removeItem(at: metadata)
        try? FileManager.default.removeItem(at: cached.fileURL)
    }

}
