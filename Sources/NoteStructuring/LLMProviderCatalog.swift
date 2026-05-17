import Foundation

struct LLMProviderDescriptor: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        case anthropic
        case openAICompatible
        case gemini
    }

    let id: String
    let displayName: String
    let kind: Kind
    let baseURL: String
    let defaultModel: String
    let modelFieldLabel: String
    let modelPlaceholder: String
    let supportsJSONResponseFormat: Bool
    let requiresEndpointID: Bool
    let keychainAccount: String
}

enum LLMProviderCatalog {
    static let all: [LLMProviderDescriptor] = [
        LLMProviderDescriptor(
            id: "anthropic",
            displayName: "Anthropic Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com/v1/messages",
            defaultModel: "claude-sonnet-4-6",
            modelFieldLabel: "Model",
            modelPlaceholder: "claude-sonnet-4-6",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "anthropic-api-key"
        ),
        LLMProviderDescriptor(
            id: "openai",
            displayName: "OpenAI ChatGPT",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1/chat/completions",
            defaultModel: "gpt-5.5",
            modelFieldLabel: "Model",
            modelPlaceholder: "gpt-5.5",
            supportsJSONResponseFormat: true,
            requiresEndpointID: false,
            keychainAccount: "openai-api-key"
        ),
        LLMProviderDescriptor(
            id: "gemini",
            displayName: "Google Gemini",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            defaultModel: "gemini-3.1-flash-lite-preview",
            modelFieldLabel: "Model",
            modelPlaceholder: "gemini-3.1-flash-lite-preview",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "gemini-api-key"
        ),
        LLMProviderDescriptor(
            id: "grok",
            displayName: "xAI Grok",
            kind: .openAICompatible,
            baseURL: "https://api.x.ai/v1/chat/completions",
            defaultModel: "grok-4.20",
            modelFieldLabel: "Model",
            modelPlaceholder: "grok-4.20",
            supportsJSONResponseFormat: true,
            requiresEndpointID: false,
            keychainAccount: "grok-api-key"
        ),
        LLMProviderDescriptor(
            id: "kimi-intl",
            displayName: "Moonshot Kimi (International)",
            kind: .openAICompatible,
            baseURL: "https://api.moonshot.ai/v1/chat/completions",
            defaultModel: "kimi-k2.6",
            modelFieldLabel: "Model",
            modelPlaceholder: "kimi-k2.6",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "kimi-intl-api-key"
        ),
        LLMProviderDescriptor(
            id: "kimi-cn",
            displayName: "Moonshot Kimi (China)",
            kind: .openAICompatible,
            baseURL: "https://api.moonshot.cn/v1/chat/completions",
            defaultModel: "kimi-k2.6",
            modelFieldLabel: "Model",
            modelPlaceholder: "kimi-k2.6",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "kimi-cn-api-key"
        ),
        LLMProviderDescriptor(
            id: "zhipu",
            displayName: "Zhipu GLM",
            kind: .openAICompatible,
            baseURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            defaultModel: "glm-5.1",
            modelFieldLabel: "Model",
            modelPlaceholder: "glm-5.1",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "zhipu-api-key"
        ),
        LLMProviderDescriptor(
            id: "minimax",
            displayName: "MiniMax",
            kind: .openAICompatible,
            baseURL: "https://api.minimaxi.com/v1/text/chatcompletion_v2",
            defaultModel: "MiniMax-M2.7",
            modelFieldLabel: "Model",
            modelPlaceholder: "MiniMax-M2.7",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "minimax-api-key"
        ),
        LLMProviderDescriptor(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1/chat/completions",
            defaultModel: "deepseek-v4-flash",
            modelFieldLabel: "Model",
            modelPlaceholder: "deepseek-v4-flash",
            supportsJSONResponseFormat: true,
            requiresEndpointID: false,
            keychainAccount: "deepseek-api-key"
        ),
        LLMProviderDescriptor(
            id: "doubao-cn",
            displayName: "ByteDance Doubao (China)",
            kind: .openAICompatible,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
            defaultModel: "",
            modelFieldLabel: "Endpoint ID",
            modelPlaceholder: "ep-YYYYMMDDHHMMSS-xxxxx",
            supportsJSONResponseFormat: false,
            requiresEndpointID: true,
            keychainAccount: "doubao-cn-api-key"
        ),
        LLMProviderDescriptor(
            id: "doubao-intl",
            displayName: "ByteDance Doubao (International)",
            kind: .openAICompatible,
            baseURL: "https://ark.ap-southeast.bytepluses.com/api/v3/chat/completions",
            defaultModel: "seed-1-8-251228",
            modelFieldLabel: "Model",
            modelPlaceholder: "seed-1-8-251228",
            supportsJSONResponseFormat: false,
            requiresEndpointID: false,
            keychainAccount: "doubao-intl-api-key"
        ),
    ]

    static let defaultProviderID = "anthropic"

    static func descriptor(for id: String) -> LLMProviderDescriptor {
        all.first { $0.id == id } ?? all.first!
    }
}
