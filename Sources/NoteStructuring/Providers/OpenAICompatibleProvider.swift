import Foundation

private struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIResponseFormat: Codable {
    let type: String
}

private struct OpenAIRequest: Codable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let response_format: OpenAIResponseFormat?
}

private struct OpenAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String?
    }

    var text: String? {
        choices.first?.message.content
    }
}

private struct OpenAIErrorResponse: Codable {
    let error: ErrorDetail
    struct ErrorDetail: Codable {
        let message: String
    }
}

final class OpenAICompatibleProvider: LLMProvider {
    private let baseURL: String
    private let supportsJSONResponseFormat: Bool
    private let requiresEndpointID: Bool
    private let providerDisplayName: String
    private let session: URLSession

    init(
        baseURL: String,
        supportsJSONResponseFormat: Bool,
        requiresEndpointID: Bool,
        providerDisplayName: String
    ) {
        self.baseURL = baseURL
        self.supportsJSONResponseFormat = supportsJSONResponseFormat
        self.requiresEndpointID = requiresEndpointID
        self.providerDisplayName = providerDisplayName
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    func send(
        systemPrompt: String,
        userPrompt: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresEndpointID && trimmedModel.isEmpty {
            throw LLMProviderError.missingEndpointID(providerDisplayName: providerDisplayName)
        }

        let body = OpenAIRequest(
            model: trimmedModel,
            max_tokens: 16384,
            messages: [
                OpenAIMessage(role: "system", content: systemPrompt),
                OpenAIMessage(role: "user", content: userPrompt),
            ],
            response_format: supportsJSONResponseFormat
                ? OpenAIResponseFormat(type: "json_object")
                : nil
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                throw LLMProviderError.apiError(httpResponse.statusCode, errorResponse.error.message)
            }
            let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMProviderError.apiError(httpResponse.statusCode, raw)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = decoded.text, !text.isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return text
    }
}
