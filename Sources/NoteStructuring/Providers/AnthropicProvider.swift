import Foundation

private struct AnthropicMessage: Codable {
    let role: String
    let content: String
}

private struct AnthropicRequest: Codable {
    let model: String
    let max_tokens: Int
    let messages: [AnthropicMessage]
    let system: String?
}

private struct AnthropicResponse: Codable {
    let content: [ContentBlock]
    let stop_reason: String?

    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    var text: String? {
        content.first(where: { $0.type == "text" })?.text
    }
}

private struct AnthropicErrorResponse: Codable {
    let error: ErrorDetail
    struct ErrorDetail: Codable {
        let message: String
    }
}

final class AnthropicProvider: LLMProvider {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String) {
        self.baseURL = baseURL
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
        let body = AnthropicRequest(
            model: model,
            max_tokens: 32000,
            messages: [AnthropicMessage(role: "user", content: userPrompt)],
            system: systemPrompt
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw LLMProviderError.apiError(httpResponse.statusCode, errorResponse.error.message)
            }
            throw LLMProviderError.apiError(httpResponse.statusCode, "Unknown error")
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = decoded.text else {
            throw LLMProviderError.emptyResponse
        }
        if decoded.stop_reason == "max_tokens" {
            throw LLMProviderError.apiError(
                200,
                "Output hit max_tokens limit and was truncated. Try a shorter transcript or upgrade the model."
            )
        }
        return text
    }
}
