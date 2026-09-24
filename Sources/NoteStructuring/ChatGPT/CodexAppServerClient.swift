import Foundation
import Darwin

struct CodexLaunchConfiguration: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    var removesWorkingDirectoryOnExit = false
}

/// One private stdio connection. Generation jobs each own a connection, so cancellation
/// terminates only that job; stdout events from different meetings cannot interleave.
actor CodexAppServerClient {
    // macOS may ask for Keychain access when a user upgrades from the external
    // CLI Beta. Give them time to respond; cancellation still interrupts promptly.
    static let authenticationTimeout: Double = 120
    nonisolated let notifications: AsyncThrowingStream<CodexRPCMessage, Error>
    private let notificationWriter: AsyncThrowingStream<CodexRPCMessage, Error>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var closed = false

    init() {
        let stream = AsyncThrowingStream<CodexRPCMessage, Error>.makeStream()
        notifications = stream.stream
        notificationWriter = stream.continuation
    }

    func start(_ configuration: CodexLaunchConfiguration) async throws {
        guard process == nil, !closed else { throw ChatGPTError.connectionClosed }
        try Task.checkCancellation()
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.executableURL = configuration.executable
        proc.arguments = configuration.arguments
        proc.environment = configuration.environment
        proc.currentDirectoryURL = configuration.workingDirectory
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // The runtime can include prompts or OAuth URLs in diagnostic output.
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { process in
            CodexProcessRegistry.shared.remove(process)
            if configuration.removesWorkingDirectoryOnExit {
                try? FileManager.default.removeItem(at: configuration.workingDirectory)
            }
        }
        let bytes = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                bytes.continuation.finish()
            } else {
                bytes.continuation.yield(data)
            }
        }
        do { try proc.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            bytes.continuation.finish()
            if configuration.removesWorkingDirectoryOnExit { try? FileManager.default.removeItem(at: configuration.workingDirectory) }
            throw ChatGPTError.runtimeMissing
        }
        CodexProcessRegistry.shared.add(proc)
        process = proc
        input = stdinPipe.fileHandleForWriting
        reader = Task { [weak self] in
            var lines = CodexLineBuffer()
            do {
                for await data in bytes.stream {
                    for message in try lines.append(data) { await self?.receive(message) }
                }
                await self?.shutdown(error: .connectionClosed)
            } catch {
                await self?.shutdown(error: .invalidProtocol)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
        }
        let result = try await request("initialize", params: .object([
            "clientInfo": .object(["name": .string("seminarly"), "title": .string("Seminarly"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]), timeout: Self.authenticationTimeout)
        guard let userAgent = result["userAgent"].string,
              let versionText = userAgent.split(separator: " ").first?.split(separator: "/").last,
              let version = SemanticVersion(String(versionText)), version >= SemanticVersion(CodexRuntime.minimumVersion)!
        else { shutdown(); throw ChatGPTError.runtimeTooOld }
        try write(CodexRPCMessage(method: "initialized", params: .object([:])))
    }

    func request(_ method: String, params: CodexJSON = .object([:]), timeout: Double = 30) async throws -> CodexJSON {
        try Task.checkCancellation()
        guard !closed, input != nil else { throw ChatGPTError.connectionClosed }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    await self?.fail(id, error: ChatGPTError.timedOut)
                }
                do { try write(CodexRPCMessage(id: .number(Double(id)), method: method, params: params)) }
                catch { fail(id, error: ChatGPTError.connectionClosed) }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
    }

    /// A system-managed MCP configuration may survive an empty profile override.
    /// Refuse it before sending meeting content, rather than exposing connector tools.
    func requireNoMCPServers() async throws {
        let status = try await request("mcpServerStatus/list")
        guard case .array(let servers) = status["data"], servers.isEmpty,
              status["nextCursor"].string == nil else { throw ChatGPTError.privacyUnavailable }
    }

    private func receive(_ message: CodexRPCMessage) {
        guard !closed else { return }
        if let id = message.id, message.method != nil {
            // No server-initiated operation is authorized by a note-generation client.
            try? write(CodexRPCMessage(id: id, error: CodexRPCError(code: -32601, message: "Seminarly does not support tools or approval requests.")))
            shutdown(error: .toolsDisabled)
        } else if case .number(let number) = message.id, number.isFinite, number >= 0,
                  number < Double(Int.max), number.rounded(.towardZero) == number {
            let id = Int(number)
            if let error = message.error { fail(id, error: ChatGPTError.server(error.message, info: error.data?["codexErrorInfo"] ?? .null)) }
            else if let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: message.result ?? .null)
            }
        } else if let method = message.method {
            // Deltas and reasoning are unnecessary; dropping them bounds queued content.
            if ["account/login/completed", "account/updated", "item/started", "item/completed", "turn/completed"].contains(method) {
                notificationWriter.yield(message)
            }
        }
    }

    private func write(_ message: CodexRPCMessage) throws {
        guard let input, !closed else { throw ChatGPTError.connectionClosed }
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func fail(_ id: Int, error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    func shutdown(error: ChatGPTError? = nil) {
        guard !closed else { return }
        closed = true
        try? input?.close()
        input = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        for id in Array(pending.keys) { fail(id, error: error ?? ChatGPTError.connectionClosed) }
        if let error { notificationWriter.finish(throwing: error) } else { notificationWriter.finish() }
        reader?.cancel()
        reader = nil
    }
}

/// Synchronous application-exit cleanup, including logins that are still awaiting a browser.
final class CodexProcessRegistry: @unchecked Sendable {
    static let shared = CodexProcessRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.withLock { if process.isRunning { processes[ObjectIdentifier(process)] = process } }
    }
    func remove(_ process: Process) { _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) } }
    func terminateAll() {
        let running = lock.withLock { Array(processes.values) }
        for process in running where process.isRunning { process.terminate() }
    }
}
