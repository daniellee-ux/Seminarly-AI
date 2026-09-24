import Foundation

enum CodexRuntime {
    static let minimumVersion = "0.155.1"
    static let automaticModel = "automatic"
    static let permissionProfile = "seminarly-notes"

    /// Always use the version shipped and signed with Seminarly. A global CLI or a
    /// saved executable preference from the earlier Beta must not change this runtime.
    static func executable(in bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let url = bundleURL.appendingPathComponent("Contents/Helpers/seminarly-chatgpt")
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return nil }
        return url
    }

    static func configuration() throws -> CodexLaunchConfiguration {
        guard let executable = executable() else { throw ChatGPTError.runtimeMissing }
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let profile = support.appendingPathComponent("ai.seminarly/ChatGPT", isDirectory: true)
        let work = fm.temporaryDirectory.appendingPathComponent("ai.seminarly-chatgpt-\(UUID().uuidString)", isDirectory: true)
        for directory in [profile, work] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return configuration(executable: executable, profile: profile, work: work)
    }

    /// Separate profile/keyring namespace; no API keys, Codex launch context, or shell secrets
    /// are inherited. CODEX_HOME is an official runtime setting, not the user's ~/.codex.
    static func configuration(executable: URL, profile: URL, work: URL,
                              source: [String: String] = ProcessInfo.processInfo.environment) -> CodexLaunchConfiguration {
        var environment = source.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
        environment["CODEX_HOME"] = profile.path
        environment["PATH"] = "/usr/bin:/bin"
        let settings = [
            "cli_auth_credentials_store=\"keyring\"", "forced_login_method=\"chatgpt\"",
            "model_provider=\"openai\"", "approval_policy=\"never\"",
            "default_permissions=\"\(permissionProfile)\"",
            "permissions.\(permissionProfile).filesystem= { \":minimal\" = \"read\", \":workspace_roots\" = \"read\" }",
            "permissions.\(permissionProfile).network.enabled=false",
            "web_search=\"disabled\"", "tools.view_image=false", "project_doc_max_bytes=0", "mcp_servers={}",
            "history.persistence=\"none\"", "analytics.enabled=false", "otel.log_user_prompt=false",
            "shell_environment_policy.inherit=\"none\"", "features.skip_host_skill_discovery=true",
        ] + ["shell_tool", "unified_exec", "apply_patch_freeform", "apps", "plugins", "remote_plugin",
             "hooks", "skill_search", "skill_mcp_dependency_install", "goals", "multi_agent", "multi_agent_v2",
             "memories", "browser_use", "browser_use_external", "in_app_browser", "computer_use",
             "image_generation", "workspace_dependencies", "tool_suggest", "code_mode", "code_mode_host",
             "view_image", "shell_snapshot", "sleep_tool", "in_app_chat", "in_app_local_automation"]
            .map { "features.\($0)=false" }
        return CodexLaunchConfiguration(
            executable: executable,
            // The bundled binary is the standalone App Server, not the terminal CLI.
            arguments: settings.flatMap { ["-c", $0] } + ["--listen", "stdio://"],
            environment: environment, workingDirectory: work, removesWorkingDirectoryOnExit: true
        )
    }
}
