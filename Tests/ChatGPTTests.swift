import XCTest
@testable import Seminarly

final class ChatGPTProtocolTests: XCTestCase {
    func testUTF8FramingAcrossEveryByteAndMultipleLines() throws {
        let message = CodexRPCMessage(method: "測試", params: .object(["text": .string("中文 🎉")]))
        var data = try JSONEncoder().encode(message)
        data.append(10)
        var buffer = CodexLineBuffer()
        var messages: [CodexRPCMessage] = []
        for byte in data { messages += try buffer.append(Data([byte])) }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.params?["text"].string, "中文 🎉")
        XCTAssertEqual(try buffer.append(data + data).count, 2)
    }

    func testInvalidAndOversizedProtocol() {
        var buffer = CodexLineBuffer()
        XCTAssertThrowsError(try buffer.append(Data("not json\n".utf8)))
        buffer = CodexLineBuffer()
        XCTAssertThrowsError(try buffer.append(Data(repeating: 65, count: CodexLineBuffer.maximumBytes + 1)))
    }

    func testLoginURLsAreRestrictedToOfficialHTTPSHosts() {
        for url in ["http://auth.openai.com/login", "https://auth.openai.com.evil.example", "https://secret@chatgpt.com/login", "file:///etc/passwd"] {
            XCTAssertNil(ChatGPTLogin(type: "chatgpt", loginId: "1", authUrl: url, verificationUrl: nil, userCode: nil).url)
        }
        XCTAssertNotNil(ChatGPTLogin(type: "chatgpt", loginId: "1", authUrl: "https://auth.openai.com/authorize", verificationUrl: nil, userCode: nil).url)
    }

    func testConfigurationIsolatedFromAPIAndCodexEnvironment() {
        let config = CodexRuntime.configuration(executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                                              profile: URL(fileURLWithPath: "/tmp/seminarly-test-profile"), work: URL(fileURLWithPath: "/tmp/seminarly-test-work"),
                                              source: ["HOME": "/Users/test", "OPENAI_API_KEY": "secret", "CODEX_HOME": "/Users/test/.codex", "CODEX_THREAD_ID": "real-thread", "RUST_LOG": "trace"])
        XCTAssertNil(config.environment["OPENAI_API_KEY"])
        XCTAssertNil(config.environment["CODEX_THREAD_ID"])
        XCTAssertNil(config.environment["RUST_LOG"])
        XCTAssertEqual(config.environment["CODEX_HOME"], "/tmp/seminarly-test-profile")
        XCTAssertTrue(config.arguments.contains("cli_auth_credentials_store=\"keyring\""))
        XCTAssertTrue(config.arguments.contains("features.skip_host_skill_discovery=true"))
        XCTAssertTrue(config.arguments.contains("features.shell_tool=false"))
        XCTAssertFalse(config.arguments.contains { $0.contains("sandbox_mode") })
    }

    func testSchemasCoverEveryTemplateAndHaveNoUnconstrainedObjects() {
        func validate(_ schema: CodexJSON) {
            if schema["type"].string == "object", case .object(let fields) = schema["properties"] {
                XCTAssertEqual(schema["additionalProperties"], .bool(false))
                XCTAssertEqual(Set(schema["required"].array.compactMap(\.string)), Set(fields.keys))
                fields.values.forEach(validate)
            } else if schema["type"].string == "array" { validate(schema["items"]) }
        }
        for template in NoteTemplate.allCases {
            let schema = NoteOutputSchema.make(for: template)
            validate(schema)
            XCTAssertEqual(schema["properties"]["title"]["type"].string, "string")
            for section in template.sectionDefinitions { XCTAssertEqual(schema["properties"][section.key]["type"].string, "array") }
        }
    }

    func testUsageAndSafeErrors() {
        XCTAssertEqual(ChatGPTRateWindow(usedPercent: 120, windowDurationMins: nil, resetsAt: nil).remainingPercent, 0)
        XCTAssertFalse(ChatGPTRateWindow(usedPercent: 100, windowDurationMins: nil, resetsAt: 1).isExhausted)
        XCTAssertEqual(ChatGPTError.server("private secret transcript"), .generationFailed)
        XCTAssertFalse(ChatGPTError.server("private secret transcript").localizedDescription.contains("secret"))
        XCTAssertEqual(ChatGPTError.server("usage limit reached"), .rateLimited)
        XCTAssertEqual(ChatGPTError.server("opaque", info: .string("usageLimitExceeded")), .rateLimited)
        XCTAssertEqual(ChatGPTError.server("opaque", info: .string("contextWindowExceeded")), .contextTooLong)
        XCTAssertEqual(ChatGPTError.server("opaque", info: .object(["httpConnectionFailed": .object(["httpStatusCode": .number(401)])])), .signedOut)
    }
}

@MainActor
final class ChatGPTConnectionTests: XCTestCase {
    private func configuration(_ scenario: String) -> CodexLaunchConfiguration {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-codex.py")
        return CodexLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, scenario],
                                        environment: ["PATH": "/usr/bin:/bin"], workingDirectory: fixture.deletingLastPathComponent())
    }

    private func generate(_ scenario: String, timeout: Double = 3) async throws -> String {
        let client = CodexAppServerClient()
        do {
            let config = configuration(scenario)
            try await client.start(config)
            return try await ChatGPTNoteProvider().send(client: client, workingDirectory: config.workingDirectory,
                                                        systemPrompt: "Structure notes", userPrompt: "Private transcript",
                                                        model: CodexRuntime.automaticModel, template: .freeform, timeout: timeout)
        } catch { await client.shutdown(); throw error }
    }

    private func waitForOperation(_ store: ChatGPTAccountStore) async throws {
        for _ in 0..<600 {
            if !store.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.cancelSignIn()
        XCTFail("Account operation did not finish")
    }

    func testCompletedFinalOnly() async throws {
        let result = try await generate("success")
        let note = try JSONDecoder().decode(FreeformNoteResponse.self, from: Data(result.utf8))
        XCTAssertEqual(note.title, "會議筆記")
        XCTAssertFalse(result.contains("Thinking"))
    }

    func testRejectsPartialFailedQuotaToolsAndPersistentThreads() async throws {
        for (scenario, expected) in [("failed", ChatGPTError.generationFailed), ("quota", .rateLimited), ("tool", .toolsDisabled),
                                     ("persistent", .privacyUnavailable), ("wrong-profile", .privacyUnavailable), ("mcp", .privacyUnavailable),
                                     ("signed-out", .signedOut), ("old", .runtimeTooOld), ("server-request", .toolsDisabled)] {
            do { _ = try await generate(scenario); XCTFail("Expected \(scenario) to fail") }
            catch { XCTAssertEqual(error as? ChatGPTError, expected, scenario) }
        }
    }

    func testGenerationTimeoutAndCancellation() async throws {
        do { _ = try await generate("hang", timeout: 0.15); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ChatGPTError, .timedOut) }
        let task = Task { try await self.generate("hang", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    }

    func testRequestTimeoutAndProcessExitResumeWaiters() async throws {
        let client = CodexAppServerClient()
        try await client.start(configuration("success"))
        do { _ = try await client.request("never-replies", timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ChatGPTError, .timedOut) }
        do { _ = try await client.request("crash"); XCTFail("Expected process exit") }
        catch { XCTAssertEqual(error as? ChatGPTError, .connectionClosed) }
        await client.shutdown()
    }

    func testLoginCompletionBeforeResponseAndAccountPagination() async throws {
        var opened = 0
        let config = configuration("login")
        let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in opened += 1 })
        store.signIn()
        try await waitForOperation(store)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.models.count, 2)
        XCTAssertEqual(store.rateLimits?.primary?.remainingPercent, 75)
        XCTAssertNil(store.pendingLogin)
        store.signOut()
        try await waitForOperation(store)
        XCTAssertFalse(store.isConnected)
    }

    func testRefreshDoesNotDownloadAndSignInPreparesBeforeOpeningBrowser() async throws {
        var preparations = 0
        var opened = 0
        let config = configuration("login")
        let store = ChatGPTAccountStore(configuration: { config }, prepareRuntime: { progress in
            preparations += 1
            progress(.downloading(0.5))
        }, openURL: { _ in
            XCTAssertEqual(preparations, 1)
            opened += 1
        })
        store.refresh()
        try await waitForOperation(store)
        XCTAssertEqual(preparations, 0)
        store.signIn()
        try await waitForOperation(store)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(opened, 1)
        XCTAssertNil(store.preparation)
    }

    func testCancelPreparationNeverOpensBrowserAndAllowsRetry() async throws {
        var attempts = 0
        var opened = 0
        let config = configuration("login")
        let store = ChatGPTAccountStore(configuration: { config }, prepareRuntime: { _ in
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(30)) }
        }, openURL: { _ in opened += 1 })
        store.signIn()
        for _ in 0..<100 {
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.cancelSignIn()
        try await waitForOperation(store)
        XCTAssertEqual(opened, 0)
        XCTAssertNil(store.preparation)
        XCTAssertNil(store.errorMessage)
        store.signIn()
        try await waitForOperation(store)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(store.isReady)
    }

    func testDownloadFailureIsFriendlyAndDoesNotOpenBrowser() async throws {
        let config = configuration("login")
        let store = ChatGPTAccountStore(configuration: { config }, prepareRuntime: { _ in
            throw ChatGPTError.runtimeDownloadFailed
        }, openURL: { _ in XCTFail("Browser must not open before a verified runtime exists") })
        store.signIn()
        try await waitForOperation(store)
        XCTAssertEqual(store.errorMessage, ChatGPTError.runtimeDownloadFailed.localizedDescription)
        XCTAssertFalse(store.isWorking)
        XCTAssertNil(store.preparation)
    }

    func testFailedLoginInvalidURLAndDeviceCodeCancellation() async throws {
        for scenario in ["login-fails", "bad-url"] {
            let config = configuration(scenario)
            let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in })
            store.signIn()
            try await waitForOperation(store)
            XCTAssertFalse(store.isConnected)
            XCTAssertNotNil(store.errorMessage)
        }
        let config = configuration("login-waits")
        let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in })
        store.signIn(deviceCode: true)
        for _ in 0..<200 {
            if store.pendingLogin != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.pendingLogin?.userCode, "ABCD-1234")
        store.cancelSignIn()
        try await waitForOperation(store)
        XCTAssertNil(store.pendingLogin)
        XCTAssertFalse(store.isConnected)
        XCTAssertNil(store.errorMessage)
    }

    func testLogoutFailureDoesNotPretendCredentialsWereRemoved() async throws {
        let config = configuration("logout-fails-hang")
        let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in })
        store.refresh()
        try await waitForOperation(store)
        XCTAssertTrue(store.isConnected)
        let generation = Task { try await store.generate(systemPrompt: "Notes", userPrompt: "Transcript", model: CodexRuntime.automaticModel, template: .freeform) }
        try await Task.sleep(for: .milliseconds(150))
        store.signOut()
        try await waitForOperation(store)
        do { _ = try await generation.value; XCTFail("Expected generation to stop") }
        catch { XCTAssertEqual(error as? ChatGPTError, .signedOut) }
        XCTAssertTrue(store.isConnected)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.errorMessage?.contains("secret") ?? true)
    }

    func testCanCancelSignInBeforeBrowserURLArrives() async throws {
        let config = configuration("login-start-hangs")
        let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in XCTFail("Browser must not open") })
        store.signIn()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.isWorking)
        XCTAssertNil(store.pendingLogin)
        store.cancelSignIn()
        try await waitForOperation(store)
        XCTAssertFalse(store.isWorking)
        XCTAssertFalse(store.isConnected)
        XCTAssertNil(store.errorMessage)
    }

    func testSignOutStopsInFlightGeneration() async throws {
        let config = configuration("hang")
        let store = ChatGPTAccountStore(configuration: { config }, openURL: { _ in })
        store.refresh()
        try await waitForOperation(store)
        let task = Task { try await store.generate(systemPrompt: "Notes", userPrompt: "Transcript", model: CodexRuntime.automaticModel, template: .freeform) }
        try await Task.sleep(for: .milliseconds(150))
        store.signOut()
        try await waitForOperation(store)
        do { _ = try await task.value; XCTFail("Signed-out generation must not finish") }
        catch { XCTAssertEqual(error as? ChatGPTError, .signedOut) }
        XCTAssertFalse(store.isConnected)
    }

    func testParallelConnectionsDoNotCancelEachOther() async throws {
        let cancelled = Task { try await self.generate("hang", timeout: 5) }
        let completed = Task { try await self.generate("success") }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        _ = try? await cancelled.value
        let result = try await completed.value
        XCTAssertTrue(result.contains("會議筆記"))
    }
}
