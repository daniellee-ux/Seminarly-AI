import SwiftUI
import AppKit

struct ChatGPTSettingsSection: View {
    @ObservedObject private var account = ChatGPTAccountStore.shared
    @ObservedObject private var settings = LLMSettings.shared

    var body: some View {
        Section("ChatGPT plan · Beta") {
            Text("Use the Codex allowance included in your ChatGPT plan. No OpenAI API key is needed. Plan limits and workspace restrictions still apply; this is not unlimited API access.")
                .font(.caption).foregroundStyle(.secondary)

            if let identity = account.account {
                LabeledContent("Account", value: identity.email ?? "ChatGPT")
                LabeledContent("Plan", value: identity.planType?.capitalized ?? "Unknown")
                Picker("Model", selection: $settings.currentModel) {
                    Text("Automatic (account default)").tag(CodexRuntime.automaticModel)
                    ForEach(account.models) { model in Text(model.displayName).tag(model.model) }
                    if settings.currentModel != CodexRuntime.automaticModel,
                       !account.models.contains(where: { $0.model == settings.currentModel }) {
                        Text("\(settings.currentModel) (unavailable — choose another)").tag(settings.currentModel)
                    }
                }
                .disabled(account.isWorking)
                if let limits = account.rateLimits {
                    Text("Usage at last refresh").font(.caption).foregroundStyle(.secondary)
                    if let primary = limits.primary { usage(primary, label: "Primary window") }
                    if let secondary = limits.secondary { usage(secondary, label: "Secondary window") }
                    if limits.isExhausted {
                        Text(ChatGPTError.rateLimited.localizedDescription).font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("Usage information is unavailable for this account.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let login = account.pendingLogin {
                Text(login.userCode == nil ? "Finish signing in in your browser." : "Enter this code on the sign-in page:")
                if let code = login.userCode { Text(code).font(.title3.monospaced()).textSelection(.enabled) }
                HStack {
                    if let url = login.url { Link("Open sign-in page", destination: url) }
                    Button("Cancel") { account.cancelSignIn() }
                }
                if login.userCode != nil {
                    Text("Device-code sign-in may need to be enabled in your ChatGPT security settings or by your workspace administrator.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    if account.isConnected {
                        Button("Refresh account") { account.refresh() }
                        Button("Sign out", role: .destructive) { account.signOut() }
                    } else {
                        Button("Sign in with ChatGPT") { account.signIn() }
                            .buttonStyle(.borderedProminent)
                        Button("Use device code") { account.signIn(deviceCode: true) }
                        Button("Refresh") { account.refresh() }
                    }
                }
                .disabled(account.isWorking)
            }
            if account.isWorking { ProgressView().controlSize(.small) }
            if let error = account.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }

            Text("Requires Codex \(CodexRuntime.minimumVersion) or later. App Server is experimental. Seminarly uses its own sign-in, stored by Codex in the macOS Keychain; signing out here does not sign out your regular Codex tools.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Codex runtime", value: account.executablePath ?? "Not found")
                .font(.caption).textSelection(.enabled)
            HStack {
                Link("Install or update Codex", destination: URL(string: "https://learn.chatgpt.com/docs/codex-cli")!)
                Button("Choose executable…") { chooseExecutable() }.disabled(account.isWorking)
                Button("Auto-detect") {
                    UserDefaults.standard.removeObject(forKey: CodexRuntime.executablePreference)
                    account.updateExecutablePath()
                    account.refresh()
                }.disabled(account.isWorking)
            }
            Text("Only the transcript and notes you choose to enhance are sent to OpenAI. Audio stays on your Mac. Temporary note-generation sessions are not added to Codex history. OpenAI's account data controls still apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { account.refresh() }
    }

    private func usage(_ window: ChatGPTRateWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(window.remainingPercent)% remaining")
            if let resets = window.resetsAt {
                Text("Resets \(Date(timeIntervalSince1970: resets).formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }.font(.caption)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: CodexRuntime.executablePreference)
        account.updateExecutablePath()
        account.refresh()
    }
}
