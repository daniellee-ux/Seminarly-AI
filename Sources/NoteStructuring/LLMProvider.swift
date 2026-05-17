import Foundation

protocol LLMProvider: Sendable {
    func send(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        apiKey: String
    ) async throws -> String
}

enum LLMProviderError: LocalizedError {
    case noAPIKey(providerDisplayName: String)
    case invalidResponse
    case emptyResponse
    case apiError(Int, String)
    case missingEndpointID(providerDisplayName: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let name):
            return "No API key configured for \(name). Add it in Settings."
        case .invalidResponse:
            return "Invalid response from provider"
        case .emptyResponse:
            return "Provider returned an empty response"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .missingEndpointID(let name):
            return "\(name) requires an Endpoint ID. Configure one in Settings."
        }
    }
}

enum LLMResponseSanitizer {
    static func extractJSON(from raw: String) -> String {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasSuffix("\u{FEFF}") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            let afterTicks = text.index(text.startIndex, offsetBy: 3)
            if let firstNewline = text[afterTicks...].firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            } else {
                text = String(text[afterTicks...])
            }
        }

        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
