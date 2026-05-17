import Foundation

private struct GeminiPart: Codable {
    let text: String
}

private struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiSystemInstruction: Codable {
    let parts: [GeminiPart]
}

private struct GeminiGenerationConfig: Codable {
    let responseMimeType: String
    let maxOutputTokens: Int
}

private struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiSystemInstruction?
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiResponse: Codable {
    let candidates: [Candidate]?

    struct Candidate: Codable {
        let content: GeminiContent?
    }

    var text: String? {
        candidates?.first?.content?.parts.first?.text
    }
}

private struct GeminiErrorResponse: Codable {
    let error: ErrorDetail
    struct ErrorDetail: Codable {
        let message: String
    }
}

final class GeminiProvider: LLMProvider {
    private let baseURLTemplate: String
    private let session: URLSession

    init(baseURLTemplate: String) {
        self.baseURLTemplate = baseURLTemplate
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
        let resolved = baseURLTemplate.replacingOccurrences(of: "{model}", with: model)
        guard var components = URLComponents(string: resolved) else {
            throw LLMProviderError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw LLMProviderError.invalidResponse
        }

        let body = GeminiRequest(
            contents: [
                GeminiContent(role: "user", parts: [GeminiPart(text: userPrompt)])
            ],
            systemInstruction: GeminiSystemInstruction(parts: [GeminiPart(text: systemPrompt)]),
            generationConfig: GeminiGenerationConfig(
                responseMimeType: "application/json",
                maxOutputTokens: 16384
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                throw LLMProviderError.apiError(httpResponse.statusCode, errorResponse.error.message)
            }
            let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMProviderError.apiError(httpResponse.statusCode, raw)
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.text, !text.isEmpty else {
            throw LLMProviderError.emptyResponse
        }
        return text
    }
}
