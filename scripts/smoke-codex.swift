// Compile with CodexProtocol.swift, CodexAppServerClient.swift, CodexRuntime.swift,
// and SemanticVersion.swift; see docs/chatgpt-plan.md. Does not log in or call a model.
import Foundation

@main
struct CodexSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the absolute bundled seminarly-chatgpt executable path") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("seminarly-codex-smoke-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("profile")
        let work = root.appendingPathComponent("work")
        for directory in [profile, work] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let client = CodexAppServerClient()
        let config = CodexRuntime.configuration(executable: URL(fileURLWithPath: CommandLine.arguments[1]), profile: profile, work: work)
        do {
            try await client.start(config)
            print("PASS: versioned initialize/initialized handshake")
            let account = try await client.request("account/read").decode(ChatGPTAccountResponse.self)
            guard account.account == nil else { throw ChatGPTError.privacyUnavailable }
            print("PASS: private profile does not inherit a signed-in account")
            try await client.requireNoMCPServers()
            print("PASS: no inherited MCP server tools")
            let thread = try await client.request("thread/start", params: .object([
                "cwd": .string(work.path), "ephemeral": .bool(true),
                "approvalPolicy": .string("never"), "permissions": .string(CodexRuntime.permissionProfile),
                "baseInstructions": .string("Only structure supplied text. Do not use tools."),
            ]), timeout: 60)
            guard thread["thread"]["ephemeral"].bool == true,
                  thread["activePermissionProfile"]["id"].string == CodexRuntime.permissionProfile,
                  thread["approvalPolicy"].string == "never" else { throw ChatGPTError.privacyUnavailable }
            print("PASS: ephemeral thread and restricted named permissions profile")
            await client.shutdown()
        } catch {
            await client.shutdown()
            print("FAIL: \(error.localizedDescription)")
            throw error
        }
        // Only remove this script's uniquely named, unauthenticated test profile.
        try? await Task.sleep(for: .seconds(3))
        try fm.removeItem(at: root)
        print("PASS: temporary test profile cleaned up; no login or model request made")
    }
}
