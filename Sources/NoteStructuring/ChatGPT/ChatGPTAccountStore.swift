import Foundation
import AppKit

@MainActor
final class ChatGPTAccountStore: ObservableObject {
    static let shared = ChatGPTAccountStore()
    @Published private(set) var account: ChatGPTAccount?
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var rateLimits: ChatGPTRateLimits?
    @Published private(set) var pendingLogin: ChatGPTLogin?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var executablePath: String?

    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var accountClient: CodexAppServerClient?
    private var generations: [UUID: CodexAppServerClient] = [:]
    private var accountGeneration = 0
    private let configuration: @MainActor () throws -> CodexLaunchConfiguration
    private let openURL: @MainActor (URL) -> Void

    init(configuration: (@MainActor () throws -> CodexLaunchConfiguration)? = nil,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.configuration = configuration ?? {
            try CodexRuntime.configuration(override: UserDefaults.standard.string(forKey: CodexRuntime.executablePreference))
        }
        self.openURL = openURL
        updateExecutablePath()
    }

    var isConnected: Bool { account?.type == "chatgpt" }
    var isReady: Bool { isConnected && !isWorking }

    func updateExecutablePath() {
        executablePath = CodexRuntime.executable(override: UserDefaults.standard.string(forKey: CodexRuntime.executablePreference))?.path
    }

    func refresh() {
        guard !isWorking else { return }
        run { store, client, _ in try await store.readAccount(client) }
    }

    func signIn(deviceCode: Bool = false) {
        guard !isWorking, generations.isEmpty else { return }
        run { store, client, _ in
            let result = try await client.request("account/login/start", params: .object(deviceCode ?
                ["type": .string("chatgptDeviceCode")] :
                ["type": .string("chatgpt"), "useHostedLoginSuccessPage": .bool(true), "appBrand": .string("chatgpt")]))
            let login = try result.decode(ChatGPTLogin.self)
            guard let url = login.url else { throw ChatGPTError.invalidLoginURL }
            try Task.checkCancellation()
            store.pendingLogin = login
            store.openURL(url)
            // Subscribe before login/start (the client buffers notifications), so a quick
            // callback arriving before the request response is not lost.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in client.notifications {
                        try Task.checkCancellation()
                        guard event.method == "account/login/completed", let params = event.params,
                              params["loginId"].string == login.loginId else { continue }
                        guard params["success"].bool == true else { throw ChatGPTError.loginFailed }
                        return
                    }
                    throw ChatGPTError.connectionClosed
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    await client.shutdown(error: .timedOut)
                    throw ChatGPTError.timedOut
                }
                defer { group.cancelAll() }
                do { try await group.next() }
                catch { await client.shutdown(); throw error }
            }
            try await store.readAccount(client)
            guard store.isConnected else { throw ChatGPTError.loginFailed }
        }
    }

    func cancelSignIn() {
        guard isWorking else { return }
        let client = accountClient
        let login = pendingLogin
        operation?.cancel()
        // Keep controls disabled until this operation has fully shut down. Starting a
        // second browser callback while the first is cancelling can sign in the wrong account.
        Task {
            if let client {
                if let login {
                    _ = try? await client.request("account/login/cancel", params: .object(["loginId": .string(login.loginId)]), timeout: 3)
                }
                await client.shutdown()
            }
        }
    }

    func signOut() {
        guard !isWorking else { return }
        accountGeneration += 1
        let active = Array(generations.values)
        Task {
            for generation in active { await generation.shutdown(error: .signedOut) }
        }
        run(clearAccountOnFailure: false) { store, client, _ in
            _ = try await client.request("account/logout")
            store.account = nil
            store.models = []
            store.rateLimits = nil
        }
    }

    private func run(clearAccountOnFailure: Bool = true,
                     _ action: @escaping @MainActor (ChatGPTAccountStore, CodexAppServerClient, CodexLaunchConfiguration) async throws -> Void) {
        let id = UUID()
        operationID = id
        isWorking = true
        errorMessage = nil
        operation = Task {
            let client = CodexAppServerClient()
            accountClient = client
            defer {
                if operationID == id {
                    isWorking = false
                    pendingLogin = nil
                    accountClient = nil
                    operation = nil
                }
            }
            do {
                let config = try configuration()
                updateExecutablePath()
                try await client.start(config)
                try await action(self, client, config)
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled {
                    errorMessage = Self.safeError(error).localizedDescription
                    // Failed validation must not leave an apparently usable stale account.
                    if clearAccountOnFailure {
                        account = nil
                        models = []
                        rateLimits = nil
                    }
                }
            }
            await client.shutdown()
        }
    }

    private func readAccount(_ client: CodexAppServerClient) async throws {
        let result = try await client.request("account/read", params: .object(["refreshToken": .bool(true)]))
        let current = try result.decode(ChatGPTAccountResponse.self).account
        try Task.checkCancellation()
        guard current?.type == "chatgpt" else {
            account = nil; models = []; rateLimits = nil
            return
        }
        var available: [ChatGPTModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            let response = try await client.request("model/list", params: .object([
                "includeHidden": .bool(false), "cursor": cursor.map(CodexJSON.string) ?? .null, "limit": .number(100),
            ]))
            let page = try response.decode(ChatGPTModelsPage.self)
            available += page.data
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw ChatGPTError.invalidProtocol }
            guard seenCursors.count <= 20 else { throw ChatGPTError.invalidProtocol }
        } while cursor != nil
        // Some workspace plans do not expose rate limits. Unknown does not mean zero.
        let limits = try? await client.request("account/rateLimits/read").decode(ChatGPTRateLimitsResponse.self)
        try Task.checkCancellation()
        models = available
        rateLimits = limits?.codex
        account = current
    }

    func generate(systemPrompt: String, userPrompt: String, model: String, template: NoteTemplate) async throws -> String {
        guard isReady else { throw ChatGPTError.signedOut }
        let client = CodexAppServerClient()
        let id = UUID()
        let generation = accountGeneration
        generations[id] = client
        defer { generations[id] = nil }
        do {
            let config = try configuration()
            try await client.start(config)
            let result = try await ChatGPTNoteProvider().send(client: client, workingDirectory: config.workingDirectory,
                                                            systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, template: template)
            try Task.checkCancellation()
            guard generation == accountGeneration else { throw ChatGPTError.signedOut }
            return result
        } catch {
            await client.shutdown()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let safe = Self.safeError(error)
            // A cancelled old generation must not invalidate a newly signed-in account,
            // or pretend a failed logout actually removed credentials.
            if generation == accountGeneration {
                if safe == .signedOut { account = nil }
                errorMessage = safe.localizedDescription
            }
            throw safe
        }
    }

    private static func safeError(_ error: Error) -> ChatGPTError {
        if let error = error as? ChatGPTError { return error }
        if error is DecodingError { return .invalidProtocol }
        return .connectionClosed
    }
}
