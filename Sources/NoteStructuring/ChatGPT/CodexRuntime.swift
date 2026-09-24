import Foundation

enum CodexRuntime {
    static let executablePreference = "chatGPTCodexExecutable"
    static let minimumVersion = "0.155.1"
    static let automaticModel = "automatic"
    static let permissionProfile = "seminarly-notes"

    static func executable(override: String? = nil) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Finder-launched apps do not inherit a shell's PATH. Never invoke a login shell.
        let candidates = override.map { [$0] } ?? [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home.appendingPathComponent(".npm-global/bin/codex").path,
        ]
        return candidates.first { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func configuration(override: String? = nil) throws -> CodexLaunchConfiguration {
        guard let executable = executable(override: override) else { throw ChatGPTError.runtimeMissing }
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
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
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
            arguments: settings.flatMap { ["-c", $0] } + ["app-server", "--listen", "stdio://"],
            environment: environment, workingDirectory: work, removesWorkingDirectoryOnExit: true
        )
    }
}
