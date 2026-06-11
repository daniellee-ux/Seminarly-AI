import SwiftUI

struct SettingsView: View {
    @StateObject private var templateSettings = TemplateSettings.shared
    @StateObject private var llmSettings = LLMSettings.shared
    var onDismiss: () -> Void = {}
    @State private var apiKey: String = ""
    @State private var hasExistingKey = false
    @State private var showingKey = false
    @State private var saveStatus: String?
    @State private var modelDraft: String = ""
    @State private var modelSaveStatus: String?
    @StateObject private var transcriptionSettings = TranscriptionSettings.shared
    @StateObject private var summaryLanguageSettings = SummaryLanguageSettings.shared
    @AppStorage("autoDetectAudioSources") private var autoDetectEnabled = true

    /// Selection-only proxy: holds either a preset case, `.matchTranscript`, or
    /// the sentinel `.custom("")` (meaning "show the custom field"). Decoupling
    /// the picker selection from `summaryLanguageSettings.defaultLanguage`
    /// lets the user pick "Custom…" before they've typed anything.
    @State private var summaryLanguagePickerSelection: SummaryLanguage = .matchTranscript
    @State private var summaryLanguageCustomDraft: String = ""

    // Coding Agents (bundled seminarly-cli + skill) install state.
    @State private var cliInstalled = false
    @State private var cliOnPath = true
    @State private var cliTouchedPaths: [String] = []
    @State private var cliPathFile = "~/.zshrc"
    @State private var cliCanAutoPath = true
    @State private var cliPathSnippet = SeminarlyCLIInstaller.pathExportLine
    @State private var cliStatus: String?
    @State private var cliError: String?

    let whisperModels = [
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3-v20240930",
        "distil-whisper_distil-large-v3_turbo",
        "openai_whisper-small",
        "openai_whisper-base",
        "openai_whisper-tiny",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Default Template") {
                    Picker("Template", selection: $templateSettings.defaultTemplate) {
                        ForEach(NoteTemplate.allCases) { template in
                            Label(template.displayName, systemImage: template.icon)
                                .tag(template)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(templateSettings.defaultTemplate.description)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)

                    if templateSettings.defaultTemplate == .custom {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Custom Instructions:")
                                .font(Typography.caption)
                                .foregroundStyle(SeminarlyColors.textSecondary)
                            TextEditor(text: $templateSettings.customInstructions)
                                .frame(height: 80)
                                .font(Typography.mono)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(SeminarlyColors.border, lineWidth: 0.5)
                                )
                        }
                    }
                }

                Section("AI Provider") {
                    Picker("Provider", selection: $llmSettings.selectedProviderID) {
                        ForEach(LLMProviderCatalog.all) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: llmSettings.selectedProviderID) { _, _ in
                        refreshAPIKeyState()
                        modelDraft = llmSettings.currentModel
                        modelSaveStatus = nil
                    }

                    TextField(
                        llmSettings.currentDescriptor.modelFieldLabel,
                        text: $modelDraft,
                        prompt: Text(llmSettings.currentDescriptor.modelPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveModel() }

                    HStack {
                        Button {
                            saveModel()
                        } label: {
                            Text("Save Model")
                                .font(Typography.captionMedium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) == llmSettings.currentModel)
                        .opacity(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) == llmSettings.currentModel ? 0.4 : 1.0)

                        Button {
                            resetModel()
                        } label: {
                            Text("Reset")
                                .font(Typography.captionMedium)
                                .foregroundStyle(SeminarlyColors.textSecondary)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(SeminarlyColors.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if let status = modelSaveStatus {
                            Text(status)
                                .font(Typography.caption)
                                .foregroundStyle(SeminarlyColors.success)
                        }
                    }

                    Text(llmSettings.currentDescriptor.modelFieldLabel == "Endpoint ID"
                        ? "Provision an Endpoint ID in the Volcengine ARK console and paste it here."
                        : "Edit to use a different model from this provider.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("API Key for \(llmSettings.currentDescriptor.displayName)") {
                    HStack {
                        if showingKey {
                            TextField("Enter to replace stored key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Enter to replace stored key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showingKey.toggle()
                        } label: {
                            Image(systemName: showingKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Button {
                            saveAPIKey()
                        } label: {
                            Text("Save Key")
                                .font(Typography.captionMedium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(apiKey.isEmpty)
                        .opacity(apiKey.isEmpty ? 0.4 : 1.0)

                        if hasExistingKey {
                            Button {
                                removeAPIKey()
                            } label: {
                                Text("Remove Key")
                                    .font(Typography.captionMedium)
                                    .foregroundStyle(SeminarlyColors.destructive)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xxs)
                                    .background(SeminarlyColors.surface, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        if let status = saveStatus {
                            Text(status)
                                .font(Typography.caption)
                                .foregroundStyle(status.contains("Error") ? SeminarlyColors.destructive : SeminarlyColors.success)
                        } else {
                            Text(hasExistingKey ? "Key stored in Keychain" : "No key configured")
                                .font(Typography.caption)
                                .foregroundStyle(hasExistingKey ? SeminarlyColors.success : SeminarlyColors.textSecondary)
                        }
                    }

                    Text("Your API key is stored securely in the macOS Keychain. Each provider has its own key.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("Whisper Model") {
                    Picker("Model", selection: $transcriptionSettings.whisperModel) {
                        ForEach(whisperModels, id: \.self) { model in
                            Text(whisperModelDisplayName(model)).tag(model)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Takes effect on next app launch. Turbo is recommended (fastest, latest). Models are cached after first download.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("Transcription Language") {
                    Picker("Default Language", selection: $transcriptionSettings.defaultLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language == .auto ? language.displayName : "\(language.displayName) (\(language.nativeName))")
                                .tag(language)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Default language for transcription. Can be overridden per recording. Use Auto to let Whisper detect the language.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("Summary Language") {
                    Picker("Default Language", selection: $summaryLanguagePickerSelection) {
                        Text(SummaryLanguage.matchTranscript.displayName)
                            .tag(SummaryLanguage.matchTranscript)
                        Divider()
                        ForEach(SummaryLanguage.presets, id: \.rawValue) { language in
                            Text("\(language.displayName) (\(language.nativeName))")
                                .tag(language)
                        }
                        Divider()
                        // Sentinel — `.custom("")` selects "Custom…" so the field appears
                        Text("Custom…")
                            .tag(SummaryLanguage.custom(""))
                    }
                    .pickerStyle(.menu)
                    .onChange(of: summaryLanguagePickerSelection) { _, newValue in
                        applySummaryLanguageSelection(newValue)
                    }

                    if isSummaryCustomSelected {
                        TextField("e.g., Korean, Klingon, Latin", text: $summaryLanguageCustomDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Typography.caption)
                            .onSubmit { commitSummaryCustomDraft() }
                            .onChange(of: summaryLanguageCustomDraft) { _, _ in
                                commitSummaryCustomDraft()
                            }
                    }

                    Text("Language for AI-generated summary notes. Independent of the transcription language. Match Transcript detects the transcript language before generation.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("Audio Detection") {
                    Toggle("Automatically detect audio sources", isOn: $autoDetectEnabled)

                    Text("When enabled, Seminarly will prompt you when a meeting app or other audio source starts playing.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }

                Section("Seminarly CLI and Skills") {
                    cliAndSkillsSection
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    Text("Seminarly uses local transcription (WhisperKit) and on-device audio capture (Core Audio Taps). Only the AI note-structuring call requires network access; costs depend on your selected provider's pricing.")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(SeminarlyColors.background)
            .padding(Spacing.md)
        }
        .background(SeminarlyColors.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .onAppear {
            refreshAPIKeyState()
            modelDraft = llmSettings.currentModel
            syncSummaryLanguagePickerFromSettings()
            refreshCLIState()
        }
    }

    // MARK: - Coding Agents

    @ViewBuilder
    private var cliAndSkillsSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(cliInstalled ? "Installed" : "Not installed")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(cliInstalled ? SeminarlyColors.success : SeminarlyColors.textPrimary)
                Text("Let your coding agent — Claude Code, Codex, Cursor, Gemini — read your sessions by installing the seminarly-cli command and its agent skill.")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            if cliInstalled {
                Button {
                    uninstallCLI()
                } label: {
                    Text("Uninstall")
                        .font(Typography.captionMedium)
                        .foregroundStyle(SeminarlyColors.destructive)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(SeminarlyColors.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    installCLI()
                } label: {
                    Text("Install")
                        .font(Typography.captionMedium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }

        DisclosureGroup("What this touches") {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(cliTouchedPaths, id: \.self) { path in
                    Text(path)
                        .font(Typography.mono)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
                Text("Symlinks, not copies — the CLI tracks every app update. Uninstall removes them. Your shell PATH is never changed here; that stays a separate opt-in below.")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
            }
        }
        .font(Typography.caption)

        // Isolated PATH opt-in — surfaced only once installed and only if needed.
        if cliInstalled && !cliOnPath {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("`~/.local/bin` isn't on your PATH, so `seminarly-cli` won't resolve in a new shell yet.")
                    .font(Typography.caption)
                    .foregroundStyle(SeminarlyColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if cliCanAutoPath {
                    HStack(spacing: Spacing.sm) {
                        Button {
                            addCLIToPath()
                        } label: {
                            Text("Add to PATH")
                                .font(Typography.captionMedium)
                                .foregroundStyle(SeminarlyColors.textPrimary)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(SeminarlyColors.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Text("appends one line to \(cliPathFile)")
                            .font(Typography.caption)
                            .foregroundStyle(SeminarlyColors.textTertiary)
                    }
                } else {
                    // Non-bash/zsh shell (fish, tcsh, …): we can't safely auto-edit,
                    // so guide with that shell's own syntax (see cliPathSnippet).
                    Text("Add `~/.local/bin` to your PATH in your shell — e.g.:")
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(cliPathSnippet)
                    .font(Typography.mono)
                    .foregroundStyle(SeminarlyColors.textTertiary)
                    .textSelection(.enabled)
            }
        }

        if let cliError {
            Text(cliError)
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.destructive)
                .fixedSize(horizontal: false, vertical: true)
        } else if let cliStatus {
            Text(cliStatus)
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.success)
        }
    }

    private func refreshCLIState() {
        let installer = SeminarlyCLIInstaller.bundled
        cliInstalled = installer.isInstalled
        cliOnPath = installer.localBinOnPath
        cliTouchedPaths = installer.touchedPaths
        cliPathFile = installer.pathFileDisplayName
        cliCanAutoPath = installer.canAddToPathAutomatically
        cliPathSnippet = installer.pathExportSnippet
    }

    private func installCLI() {
        do {
            try SeminarlyCLIInstaller.bundled.install()
            cliError = nil
            cliStatus = "Installed — your coding agent can now read your sessions."
        } catch {
            cliStatus = nil
            cliError = error.localizedDescription
        }
        refreshCLIState()
        autoClearCLIStatus()
    }

    private func uninstallCLI() {
        SeminarlyCLIInstaller.bundled.uninstall()
        cliError = nil
        cliStatus = "Uninstalled."
        refreshCLIState()
        autoClearCLIStatus()
    }

    private func addCLIToPath() {
        do {
            try SeminarlyCLIInstaller.bundled.addLocalBinToPath()
            cliError = nil
            cliStatus = "Added to PATH — restart your shell or run: source \(cliPathFile)"
        } catch {
            cliStatus = nil
            cliError = error.localizedDescription
        }
        refreshCLIState()
        autoClearCLIStatus()
    }

    private func autoClearCLIStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            cliStatus = nil
        }
    }

    /// Reflect the stored-key state for the currently selected provider without
    /// auto-filling the SecureField. Called on .onAppear and whenever the user
    /// switches providers.
    private func refreshAPIKeyState() {
        let account = llmSettings.currentDescriptor.keychainAccount
        hasExistingKey = KeychainStore.exists(for: account)
        apiKey = ""
        saveStatus = nil
    }

    private func saveModel() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != llmSettings.currentModel else { return }
        llmSettings.currentModel = trimmed
        modelDraft = trimmed
        modelSaveStatus = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            modelSaveStatus = nil
        }
    }

    private func resetModel() {
        llmSettings.resetCurrentModelToDefault()
        modelDraft = llmSettings.currentModel
        modelSaveStatus = "Reset"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            modelSaveStatus = nil
        }
    }

    private var isSummaryCustomSelected: Bool {
        if case .custom = summaryLanguagePickerSelection { return true }
        return false
    }

    /// Reflects the persisted setting into the picker selection + custom draft.
    private func syncSummaryLanguagePickerFromSettings() {
        let stored = summaryLanguageSettings.defaultLanguage
        if case .custom(let name) = stored {
            summaryLanguagePickerSelection = .custom("")
            summaryLanguageCustomDraft = name.isEmpty
                ? summaryLanguageSettings.lastCustomLanguage
                : name
        } else {
            summaryLanguagePickerSelection = stored
            summaryLanguageCustomDraft = summaryLanguageSettings.lastCustomLanguage
        }
    }

    /// Persists picker changes to the settings singleton. For "Custom…", the
    /// stored value updates only when the draft is non-empty (commitSummaryCustomDraft).
    private func applySummaryLanguageSelection(_ selection: SummaryLanguage) {
        if case .custom = selection {
            // Show the field but don't override the persisted setting until the
            // user types something — otherwise selecting "Custom…" with an empty
            // draft would silently downgrade to .matchTranscript.
            commitSummaryCustomDraft()
        } else {
            summaryLanguageSettings.defaultLanguage = selection
        }
    }

    private func commitSummaryCustomDraft() {
        let trimmed = summaryLanguageCustomDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        summaryLanguageSettings.defaultLanguage = .custom(trimmed)
    }

    private func saveAPIKey() {
        let account = llmSettings.currentDescriptor.keychainAccount
        do {
            try KeychainStore.save(apiKey, for: account)
            hasExistingKey = true
            apiKey = ""
            saveStatus = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveStatus = nil
            }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func removeAPIKey() {
        let account = llmSettings.currentDescriptor.keychainAccount
        KeychainStore.delete(for: account)
        apiKey = ""
        hasExistingKey = false
        saveStatus = "Removed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = nil
        }
    }

    private func whisperModelDisplayName(_ model: String) -> String {
        switch model {
        case "openai_whisper-large-v3-v20240930_turbo": return "Large V3 Turbo — 632 MB, fastest"
        case "openai_whisper-large-v3-v20240930": return "Large V3 — 626 MB, most accurate"
        case "distil-whisper_distil-large-v3_turbo": return "Distil Large V3 Turbo — 600 MB"
        case "openai_whisper-small": return "Small — 216 MB"
        case "openai_whisper-base": return "Base — 77 MB"
        case "openai_whisper-tiny": return "Tiny — 39 MB"
        default: return model
        }
    }
}
