import Foundation
import Network

/// Sparkle's downloader uses an XPC process and cannot consume file URLs or the
/// app's URLCache. Serve only one opaque cache URL on loopback during a manual
/// update session. Sparkle still validates the original signed enclosure.
final class CachedUpdateServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.seminarly.cached-update")
    private let fileURL: URL
    private let path: String
    // All mutable state below is confined to queue.
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var awaitingRequest = Set<UUID>()
    private var startContinuation: CheckedContinuation<URL, Error>?

    init(fileURL: URL, downloadFilename: String) {
        self.fileURL = fileURL
        // Preserve the enclosure extension: Sparkle chooses an unarchiver using
        // the downloaded response filename (including .delta for patches).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let name = String(downloadFilename.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
        self.path = "/" + UUID().uuidString + "/" + name
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    startContinuation = continuation
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener.port {
                                self.finishStarting(.success(URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)")!))
                            }
                        case .failed(let error):
                            self.finishStarting(.failure(error))
                            self.stopOnQueue()
                        case .cancelled:
                            self.finishStarting(.failure(CancellationError()))
                        default: break
                        }
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.startContinuation != nil else { return }
                        self.finishStarting(.failure(URLError(.timedOut)))
                        self.stopOnQueue()
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func finishStarting(_ result: Result<URL, Error>) {
        startContinuation?.resume(with: result)
        startContinuation = nil
    }

    private func stopOnQueue() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        awaitingRequest.removeAll()
        finishStarting(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        awaitingRequest.insert(id)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: id)
                self?.awaitingRequest.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            // Limit stalled requests without timing out an active large download.
            if self?.awaitingRequest.contains(id) == true { connection?.cancel() }
        }
    }

    private func receiveRequest(on connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8_192 else { connection.cancel(); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                self.awaitingRequest.remove(id)
                let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard request.count == 3, request[0] == "GET", request[1] == self.path else {
                    connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                self.sendFile(on: connection)
            } else if complete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, id: id, buffer: buffer)
            }
        }
    }

    private func sendFile(on connection: NWConnection) {
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? file.close(); connection.cancel(); return }
                self.sendChunk(from: file, on: connection)
            })
        } catch { connection.cancel() }
    }

    private func sendChunk(from file: FileHandle, on connection: NWConnection) {
        do {
            guard let data = try file.read(upToCount: 256 * 1_024), !data.isEmpty else {
                try? file.close()
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? file.close(); connection.cancel(); return }
                self.sendChunk(from: file, on: connection)
            })
        } catch { try? file.close(); connection.cancel() }
    }
}
