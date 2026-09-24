import Foundation

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct TemplatedNoteResponse: Codable {
    let title: String
    let summary: String
    private var additionalSections: [String: [NoteItem]] = [:]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.title = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "title"))
        self.summary = try container.decode(String.self, forKey: DynamicCodingKey(stringValue: "summary"))

        for key in container.allKeys {
            if key.stringValue == "title" || key.stringValue == "summary" { continue }
            // NoteItem's custom decoder handles both plain strings and {text, source, transcriptRef} objects
            if let array = try? container.decode([NoteItem].self, forKey: key) {
                additionalSections[key.stringValue] = array
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(title, forKey: DynamicCodingKey(stringValue: "title"))
        try container.encode(summary, forKey: DynamicCodingKey(stringValue: "summary"))
        for (key, value) in additionalSections {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }

    func sections(for template: NoteTemplate) -> [NoteSection] {
        template.sectionDefinitions.compactMap { def in
            guard let items = additionalSections[def.key], !items.isEmpty else { return nil }
            return NoteSection(key: def.key, title: def.title, icon: def.icon, items: items)
        }
    }
}

/// Response schema for the Freeform template — topics have dynamic titles
/// set by the model rather than a predefined section key set.
struct FreeformNoteResponse: Codable {
    let title: String
    let summary: String
    let topics: [TopicGroup]

    struct TopicGroup: Codable {
        let title: String
        let items: [NoteItem]
    }

    func sections() -> [NoteSection] {
        topics.compactMap { group in
            guard !group.items.isEmpty else { return nil }
            return NoteSection(
                key: group.title,
                title: group.title,
                icon: "circle.fill",
                items: group.items
            )
        }
    }
}

@MainActor
final class NoteStructuringService: ObservableObject {
    @Published var isProcessing = false
    @Published var errorMessage: String?

    func structureTranscript(
        _ transcript: String,
        template: NoteTemplate = .freeform,
        customInstructions: String? = nil,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) async -> (title: String, note: StructuredNote)? {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        let descriptor = LLMSettings.shared.currentDescriptor
        let model = LLMSettings.shared.currentModel

        let resolvedSummaryLanguage = SummaryLanguage.resolvedForTranscript(summaryLanguage, transcript: transcript)
        let systemPrompt = PromptTemplates.systemPrompt(for: template, summaryLanguage: resolvedSummaryLanguage)
        let userPrompt = PromptTemplates.structureNotes(
            transcript: transcript,
            template: template,
            customInstructions: customInstructions,
            summaryLanguage: resolvedSummaryLanguage
        )

        do {
            let responseText = try await send(
                descriptor: descriptor, template: template,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model
            )
            return decodeNote(
                from: responseText,
                template: template,
                summaryLanguage: resolvedSummaryLanguage
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func enhanceNotes(
        userNotes: String,
        transcript: String,
        template: NoteTemplate = .freeform,
        customInstructions: String? = nil,
        summaryLanguage: SummaryLanguage = .matchTranscript
    ) async -> (title: String, note: StructuredNote)? {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        let descriptor = LLMSettings.shared.currentDescriptor
        let model = LLMSettings.shared.currentModel

        let resolvedSummaryLanguage = SummaryLanguage.resolvedForTranscript(summaryLanguage, transcript: transcript)
        let systemPrompt = PromptTemplates.enhanceSystemPrompt(for: template, summaryLanguage: resolvedSummaryLanguage)
        let userPrompt = PromptTemplates.enhanceWithUserNotes(
            userNotes: userNotes,
            transcript: transcript,
            template: template,
            customInstructions: customInstructions,
            summaryLanguage: resolvedSummaryLanguage
        )

        do {
            let responseText = try await send(
                descriptor: descriptor, template: template,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model
            )
            return decodeNote(
                from: responseText,
                template: template,
                summaryLanguage: resolvedSummaryLanguage
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var currentProviderDisplayName: String {
        LLMSettings.shared.currentDescriptor.displayName
    }

    // MARK: - Helpers

    private func send(descriptor: LLMProviderDescriptor, template: NoteTemplate,
                      systemPrompt: String, userPrompt: String, model: String) async throws -> String {
        if descriptor.kind == .chatGPTPlan {
            return try await ChatGPTAccountStore.shared.generate(systemPrompt: systemPrompt, userPrompt: userPrompt,
                                                                 model: model, template: template)
        }
        guard let apiKey = KeychainStore.load(for: descriptor.keychainAccount), !apiKey.isEmpty else {
            throw LLMProviderError.noAPIKey(providerDisplayName: descriptor.displayName)
        }
        let provider = try makeProvider(for: descriptor)
        return try await provider.send(systemPrompt: systemPrompt, userPrompt: userPrompt, model: model, apiKey: apiKey)
    }

    private func makeProvider(for descriptor: LLMProviderDescriptor) throws -> LLMProvider {
        switch descriptor.kind {
        case .anthropic:
            return AnthropicProvider(baseURL: descriptor.baseURL)
        case .openAICompatible:
            return OpenAICompatibleProvider(
                baseURL: descriptor.baseURL,
                supportsJSONResponseFormat: descriptor.supportsJSONResponseFormat,
                requiresEndpointID: descriptor.requiresEndpointID,
                providerDisplayName: descriptor.displayName
            )
        case .gemini:
            return GeminiProvider(baseURLTemplate: descriptor.baseURL)
        case .chatGPTPlan:
            throw ChatGPTError.invalidProtocol // Managed sign-in never falls back to paid API calls.
        }
    }

    private func decodeNote(
        from responseText: String,
        template: NoteTemplate,
        summaryLanguage: SummaryLanguage
    ) -> (title: String, note: StructuredNote)? {
        let cleaned = LLMResponseSanitizer.extractJSON(from: responseText)
        guard let data = cleaned.data(using: .utf8) else {
            errorMessage = "Failed to parse response"
            return nil
        }

        do {
            if template == .freeform {
                let decoded = try JSONDecoder().decode(FreeformNoteResponse.self, from: data)
                let note = StructuredNote(
                    summary: decoded.summary,
                    templateType: template.rawValue,
                    sections: decoded.sections(),
                    language: summaryLanguage.storageCode
                )
                return (decoded.title, note)
            }

            let decoded = try JSONDecoder().decode(TemplatedNoteResponse.self, from: data)
            let sections = decoded.sections(for: template)
            let note = StructuredNote(
                summary: decoded.summary,
                templateType: template.rawValue,
                sections: sections,
                language: summaryLanguage.storageCode
            )
            return (decoded.title, note)
        } catch {
            // This message reaches UI and logs. Never include transcript-derived output.
            errorMessage = "AI response could not be parsed. Please try again or choose another model."
            return nil
        }
    }
}
