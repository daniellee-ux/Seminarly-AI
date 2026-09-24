import SwiftUI

struct ChatGPTSettingsSection: View {
    @ObservedObject private var account = ChatGPTAccountStore.shared
    @ObservedObject private var settings = LLMSettings.shared
    @State private var showsOptions = false
    @State private var showsOtherSignIn = false

    var body: some View {
        Section("ChatGPT · Beta") {
            Text("Sign in with your ChatGPT account to generate notes. No API key or manual installation needed. A connection component downloads once on first use.")
                .font(.caption).foregroundStyle(.secondary)

            if let identity = account.account {
                LabeledContent("Account", value: identity.email ?? "ChatGPT")
                LabeledContent("Plan", value: identity.planType?.capitalized ?? "Unknown")
                if let limits = account.rateLimits {
                    Text("Usage at last refresh").font(.caption).foregroundStyle(.secondary)
                    if let primary = limits.primary { usage(primary, label: "Primary window") }
                    if let secondary = limits.secondary { usage(secondary, label: "Secondary window") }
                    if limits.isExhausted {
                        Text(ChatGPTError.rateLimited.localizedDescription).font(.caption).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("Options", isExpanded: $showsOptions) {
                    modelPicker
                    Button("Refresh account") { account.refresh() }
                        .disabled(account.isWorking)
                    if account.rateLimits == nil {
                        Text("Usage information is unavailable for this account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Sign out", role: .destructive) { account.signOut() }
                    .disabled(account.isWorking)
            }

            if let login = account.pendingLogin {
                Text(login.userCode == nil ? "Finish signing in in your browser." : "Enter this code on the sign-in page:")
                if let code = login.userCode { Text(code).font(.title3.monospaced()).textSelection(.enabled) }
                HStack {
                    if let url = login.url { Link("Open sign-in page", destination: url) }
                    Button("Cancel") { account.cancelSignIn() }
                }
                if login.userCode != nil {
                    Text("This sign-in method may need to be enabled in your ChatGPT security settings or by your workspace administrator.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !account.isConnected {
                Button("Sign in with ChatGPT") { account.signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isWorking)
                DisclosureGroup("Trouble signing in?", isExpanded: $showsOtherSignIn) {
                    Button("Sign in with a one-time code") { account.signIn(deviceCode: true) }
                        .disabled(account.isWorking)
                }
            }
            if account.isWorking {
                HStack(spacing: 8) {
                    if case .downloading(let fraction) = account.preparation {
                        ProgressView(value: fraction).frame(width: 80)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(account.preparation?.message ?? (account.pendingLogin == nil ? "Connecting to ChatGPT…" : "Waiting for sign-in…"))
                        .font(.caption).foregroundStyle(.secondary)
                    if account.pendingLogin == nil && !account.isConnected {
                        Button("Cancel") { account.cancelSignIn() }
                    }
                }
                if account.preparation != nil {
                    Text("This is only needed the first time, or when the connection component changes. You can cancel and try again later.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if account.pendingLogin == nil {
                    Text("If macOS asks, allow access to your saved ChatGPT sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = account.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }

            Text("Your plan's usage limits and workspace restrictions apply. This connection is in Beta; availability may differ from the ChatGPT website.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Only the transcript and notes you choose to enhance are sent to OpenAI. Audio stays on your Mac. Your sign-in is stored securely in macOS Keychain and is separate from other apps.")
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

    private var modelPicker: some View {
        Picker("Model", selection: $settings.currentModel) {
            Text("Automatic (recommended)").tag(CodexRuntime.automaticModel)
            ForEach(account.models) { model in Text(model.displayName).tag(model.model) }
            if settings.currentModel != CodexRuntime.automaticModel,
               !account.models.contains(where: { $0.model == settings.currentModel }) {
                Text("\(settings.currentModel) (unavailable — choose another)").tag(settings.currentModel)
            }
        }
        .disabled(account.isWorking)
    }
}
