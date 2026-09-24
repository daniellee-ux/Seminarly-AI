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
    let stream: Bool
}

private struct AnthropicErrorResponse: Codable {
    let error: ErrorDetail
    struct ErrorDetail: Codable {
        let message: String
    }
}

/// Accumulates Claude's server-sent events into the same complete text that the
/// non-streaming endpoint returned. Keeping the response active avoids idle
/// connection closures while Claude generates a longer set of notes.
struct AnthropicStreamAccumulator {
    private struct Event: Decodable {
        let type: String
        let content_block: ContentBlock?
        let delta: Delta?
        let error: ErrorDetail?

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }

        struct ErrorDetail: Decodable {
            let message: String
        }
    }

    private var dataLines: [String] = []
    private(set) var text = ""
    private var stopReason: String?
    private var completed = false

    mutating func consume(line: String) throws {
        if line.isEmpty {
            try dispatchEvent()
        } else if line.hasPrefix("event:") {
            // AsyncLineSequence omits blank SSE separator lines. A new event
            // header is therefore the reliable boundary for the prior event.
            try dispatchEvent()
        } else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            dataLines.append(value)
        }
    }

    mutating func finish() throws -> String {
        try dispatchEvent()
        guard completed else { throw LLMProviderError.incompleteResponse }
        if stopReason == "max_tokens" {
            throw LLMProviderError.apiError(
                200,
                "Output hit max_tokens limit and was truncated. Try a shorter transcript or upgrade the model."
            )
        }
        guard !text.isEmpty else { throw LLMProviderError.emptyResponse }
        return text
    }

    private mutating func dispatchEvent() throws {
        guard !dataLines.isEmpty else { return }
        defer { dataLines.removeAll(keepingCapacity: true) }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        let event = try JSONDecoder().decode(Event.self, from: data)

        switch event.type {
        case "content_block_start":
            if event.content_block?.type == "text" {
                text += event.content_block?.text ?? ""
            }
        case "content_block_delta":
            if event.delta?.type == "text_delta" {
                text += event.delta?.text ?? ""
            }
        case "message_delta":
            stopReason = event.delta?.stop_reason
        case "message_stop":
            completed = true
        case "error":
            throw LLMProviderError.providerError(event.error?.message ?? "Claude stream failed")
        default:
            break
        }
    }
}

final class AnthropicProvider: LLMProvider {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
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
            system: systemPrompt,
            stream: true
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65_536 else { break }
                data.append(byte)
            }
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw LLMProviderError.apiError(httpResponse.statusCode, errorResponse.error.message)
            }
            throw LLMProviderError.apiError(httpResponse.statusCode, "Unknown error")
        }

        var accumulator = AnthropicStreamAccumulator()
        for try await line in bytes.lines {
            try accumulator.consume(line: line)
        }
        return try accumulator.finish()
    }
}
