import Foundation

/// Small, Sendable JSON representation for the versioned App Server wire protocol.
/// Protocol reference: https://learn.chatgpt.com/docs/app-server
indirect enum CodexJSON: Codable, Sendable, Equatable {
    case object([String: CodexJSON]), array([CodexJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([CodexJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CodexJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> CodexJSON {
        guard case .object(let value) = self else { return .null }
        return value[key] ?? .null
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [CodexJSON] { if case .array(let v) = self { return v }; return [] }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

struct CodexRPCMessage: Codable, Sendable {
    var id: CodexJSON?
    var method: String?
    var params: CodexJSON?
    var result: CodexJSON?
    var error: CodexRPCError?
}

struct CodexRPCError: Codable, Sendable {
    let code: Int
    let message: String
    var data: CodexJSON?
}

struct ChatGPTAccount: Decodable, Sendable, Equatable {
    let type: String
    let email: String?
    let planType: String?
}

struct ChatGPTAccountResponse: Decodable, Sendable {
    let account: ChatGPTAccount?
}

struct ChatGPTLogin: Decodable, Sendable {
    let type: String
    let loginId: String
    let authUrl: String?
    let verificationUrl: String?
    let userCode: String?

    var url: URL? {
        guard let raw = authUrl ?? verificationUrl, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              ["auth.openai.com", "chatgpt.com", "auth.chatgpt.com"].contains(host)
        else { return nil }
        return url
    }
}

struct ChatGPTModel: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let model: String
    let displayName: String
    let isDefault: Bool
}

struct ChatGPTModelsPage: Decodable, Sendable {
    let data: [ChatGPTModel]
    let nextCursor: String?
}

struct ChatGPTRateWindow: Decodable, Sendable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent))) }
    var isExhausted: Bool {
        usedPercent >= 100 && (resetsAt.map { $0 > Date().timeIntervalSince1970 } ?? true)
    }
}

struct ChatGPTRateLimits: Decodable, Sendable, Equatable {
    let primary: ChatGPTRateWindow?
    let secondary: ChatGPTRateWindow?
    var isExhausted: Bool { primary?.isExhausted == true || secondary?.isExhausted == true }
}

struct ChatGPTRateLimitsResponse: Decodable, Sendable {
    let rateLimits: ChatGPTRateLimits?
    let rateLimitsByLimitId: [String: ChatGPTRateLimits]?
    var codex: ChatGPTRateLimits? { rateLimitsByLimitId?["codex"] ?? rateLimits }
}

enum ChatGPTError: LocalizedError, Sendable, Equatable {
    case runtimeMissing, runtimeTooOld, signedOut, invalidProtocol, connectionClosed, timedOut
    case loginFailed, invalidLoginURL, rateLimited, contextTooLong, generationFailed, toolsDisabled, privacyUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: "Seminarly's ChatGPT connection component is missing or damaged. Reinstall the latest Seminarly and try again."
        case .runtimeTooOld: "Update Seminarly to reconnect to ChatGPT."
        case .signedOut: "Connect your ChatGPT account in Settings to generate notes."
        case .invalidProtocol: "The ChatGPT connection needs an update. Update Seminarly and try again."
        case .connectionClosed: "The ChatGPT connection closed. Reconnect in Settings and try again."
        case .timedOut: "ChatGPT did not respond in time. Check your connection and try again."
        case .loginFailed: "ChatGPT sign-in did not complete. Try again or choose another sign-in method. Your workspace may restrict access."
        case .invalidLoginURL: "ChatGPT returned an unexpected sign-in address. Update Seminarly and try again."
        case .rateLimited: "Your ChatGPT plan's usage limit has been reached. Wait for it to reset or choose an API provider in Settings."
        case .contextTooLong: "This transcript exceeds the model's context limit. Try a shorter transcript or another model."
        case .generationFailed: "ChatGPT could not generate notes. Check your account, model access, and usage in Settings, then try again."
        case .toolsDisabled: "ChatGPT requested a tool that is unavailable for note generation. Please try again."
        case .privacyUnavailable: "A private ChatGPT session could not be created. Update Seminarly and try again."
        }
    }

    /// Server errors may contain prompts/credentials; only expose safe, actionable categories.
    static func server(_ message: String, info: CodexJSON = .null) -> ChatGPTError {
        switch info.string {
        case "usageLimitExceeded", "rateLimitExceeded", "sessionBudgetExceeded": return .rateLimited
        case "unauthorized": return .signedOut
        case "contextWindowExceeded": return .contextTooLong
        default: break
        }
        if case .object(let variants) = info {
            for value in variants.values {
                if value["httpStatusCode"] == .number(429) { return .rateLimited }
                if value["httpStatusCode"] == .number(401) { return .signedOut }
            }
        }
        let value = message.lowercased()
        if value.contains("rate limit") || value.contains("usage limit") || value.contains("quota") || value.contains("429") { return .rateLimited }
        if value.contains("unauthorized") || value.contains("not authenticated") || value.contains("401") || value.contains("refresh token") { return .signedOut }
        if value.contains("invalid params") || value.contains("unknown variant") || value.contains("not supported") { return .invalidProtocol }
        return .generationFailed
    }
}

/// Incremental JSONL framing preserves UTF-8 characters split across pipe reads.
struct CodexLineBuffer {
    private var buffer = Data()
    static let maximumBytes = 16 * 1024 * 1024

    mutating func append(_ data: Data) throws -> [CodexRPCMessage] {
        buffer.append(data)
        var messages: [CodexRPCMessage] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumBytes else { throw ChatGPTError.invalidProtocol }
            let line = buffer[..<newline]
            if !line.isEmpty { messages.append(try JSONDecoder().decode(CodexRPCMessage.self, from: line)) }
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= Self.maximumBytes else { throw ChatGPTError.invalidProtocol }
        return messages
    }
}
