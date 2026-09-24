import Foundation

/// URLSession owns partial files and removes them on failure/cancellation. No credentials,
/// cookies, or the user's ChatGPT profile are sent to the component host.
final class ChatGPTRuntimeDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (ChatGPTPreparation) -> Void

    init(expectedBytes: Int64, progress: @escaping @Sendable (ChatGPTPreparation) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    static func fetch(_ artifact: ChatGPTRuntimeManifest.Artifact, to destination: URL,
                      progress: @escaping @Sendable (ChatGPTPreparation) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = ChatGPTRuntimeDownload(expectedBytes: artifact.archiveBytes, progress: progress)
        // One automatic retry for transient network errors; integrity failures never retry.
        for attempt in 0...1 {
            do {
                progress(.downloading(0))
                let (file, response) = try await session.download(from: artifact.url, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      Self.permits(response.url),
                      try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(artifact.archiveBytes) else {
                    throw ChatGPTError.runtimeDownloadFailed
                }
                try FileManager.default.moveItem(at: file, to: destination)
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let transient = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0.code)
                } ?? false
                if attempt == 0 && transient {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                throw ChatGPTError.runtimeDownloadFailed
            }
        }
    }

    static func permits(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.permits(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expectedBytes else {
            downloadTask.cancel()
            return
        }
        progress(.downloading(min(1, Double(totalBytesWritten) / Double(expectedBytes))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
