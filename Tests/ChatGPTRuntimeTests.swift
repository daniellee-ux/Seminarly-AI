import XCTest
@testable import Seminarly

@MainActor
final class ChatGPTRuntimeTests: XCTestCase {
    private func temporaryBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seminarly-runtime-test-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testOnlyUsesExecutableInsideAppBundle() throws {
        let bundle = try temporaryBundle()
        // Missing internal code must fail closed, even on machines with a global CLI.
        XCTAssertNil(CodexRuntime.executable(in: bundle))
        let helper = bundle.appendingPathComponent("Contents/Helpers/seminarly-chatgpt")
        try Data("test fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(CodexRuntime.executable(in: bundle), helper)
    }

    func testRejectsNonExecutableAndExternalSymlink() throws {
        let bundle = try temporaryBundle()
        let helper = bundle.appendingPathComponent("Contents/Helpers/seminarly-chatgpt")
        try Data("test fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
        XCTAssertNil(CodexRuntime.executable(in: bundle))
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertNil(CodexRuntime.executable(in: bundle))
    }

    func testStandaloneConfigurationDoesNotRequireCLIOrNode() {
        let config = CodexRuntime.configuration(executable: URL(fileURLWithPath: "/test/Seminarly.app/Contents/Helpers/seminarly-chatgpt"),
                                              profile: URL(fileURLWithPath: "/tmp/profile"), work: URL(fileURLWithPath: "/tmp/work"),
                                              source: ["PATH": "/opt/homebrew/bin", "NODE_PATH": "/private/node", "OPENAI_API_KEY": "secret"])
        XCTAssertEqual(Array(config.arguments.suffix(2)), ["--listen", "stdio://"])
        XCTAssertFalse(config.arguments.contains("app-server"))
        XCTAssertEqual(config.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(config.environment["NODE_PATH"])
        XCTAssertNil(config.environment["OPENAI_API_KEY"])
    }

    func testErrorsDoNotAskUsersToInstallOrUpdateDeveloperTools() {
        let errors: [ChatGPTError] = [.runtimeMissing, .runtimeTooOld, .invalidProtocol, .invalidLoginURL,
                                     .loginFailed, .privacyUnavailable, .connectionClosed, .signedOut]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.lowercased().contains("codex"))
            XCTAssertFalse(error.localizedDescription.lowercased().contains("executable"))
        }
        XCTAssertTrue(ChatGPTError.runtimeMissing.localizedDescription.contains("Seminarly"))
        XCTAssertEqual(LLMProviderCatalog.all.first(where: { $0.id == "chatgpt-plan" })?.displayName, "ChatGPT (Beta)")
    }

    func testBuiltAppIncludesConnectionComponentAndLicenseNotices() throws {
        let executable = try XCTUnwrap(CodexRuntime.executable())
        XCTAssertTrue(executable.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Helpers/"))
        let notices = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ThirdParty/OpenAICodex")
        let license = try String(contentsOf: notices.appendingPathComponent("LICENSE"), encoding: .utf8)
        let notice = try String(contentsOf: notices.appendingPathComponent("NOTICE"), encoding: .utf8)
        XCTAssertTrue(license.contains("Apache License"))
        XCTAssertTrue(notice.contains("OpenAI"))
    }

    func testBundledServerStartsWithNoExternalDeveloperTools() async throws {
        let executable = try XCTUnwrap(CodexRuntime.executable())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seminarly-bundled-smoke-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("profile")
        let work = root.appendingPathComponent("work")
        for directory in [profile, work] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let client = CodexAppServerClient()
        do {
            let config = CodexRuntime.configuration(executable: executable, profile: profile, work: work, source: [:])
            try await client.start(config)
            let account = try await client.request("account/read").decode(ChatGPTAccountResponse.self)
            XCTAssertNil(account.account)
            await client.shutdown()
        } catch {
            await client.shutdown()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        // Allow the owned process to exit before removing its private test profile.
        try await Task.sleep(for: .seconds(3))
        try FileManager.default.removeItem(at: root)
    }
}
