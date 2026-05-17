import Foundation

/// Target language for AI-generated summary notes. Distinct from
/// `TranscriptionLanguage`: that controls what WhisperKit listens for, this
/// controls what Claude writes notes in. Default `.matchTranscript` injects
/// no directive and lets the model mirror the transcript's language.
enum SummaryLanguage: Equatable, Hashable, Sendable {
    case matchTranscript
    case en, zh, zhHant, yue, ja, ko, es, fr, de, pt, ptPT, ru, ar, hi, it, nl, tr, pl, sv, da, no, nn, th, vi
    case custom(String)

    /// Stable preset cases (excludes `.matchTranscript` and `.custom`) — used to
    /// drive Pickers without exposing two-mode logic.
    static let presets: [SummaryLanguage] = [
        .en, .zh, .zhHant, .yue, .ja, .ko, .es, .fr, .de, .pt, .ptPT, .ru, .ar, .hi, .it, .nl, .tr, .pl, .sv, .da, .no, .nn, .th, .vi,
    ]

    var displayName: String {
        switch self {
        case .matchTranscript: return "Match Transcript"
        case .en: return "English"
        case .zh: return "Simplified Chinese (Mandarin)"
        case .zhHant: return "Traditional Chinese (Mandarin)"
        case .yue: return "Cantonese"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .pt: return "Portuguese (Brazil)"
        case .ptPT: return "Portuguese (Portugal)"
        case .ru: return "Russian"
        case .ar: return "Arabic"
        case .hi: return "Hindi"
        case .it: return "Italian"
        case .nl: return "Dutch"
        case .tr: return "Turkish"
        case .pl: return "Polish"
        case .sv: return "Swedish"
        case .da: return "Danish"
        case .no: return "Norwegian (Bokmål)"
        case .nn: return "Norwegian (Nynorsk)"
        case .th: return "Thai"
        case .vi: return "Vietnamese"
        case .custom(let name): return name.isEmpty ? "Custom" : name
        }
    }

    var nativeName: String {
        switch self {
        case .matchTranscript: return "Auto"
        case .en: return "English"
        case .zh: return "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"
        case .zhHant: return "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}"
        case .yue: return "\u{7CB5}\u{8A9E}"
        case .ja: return "\u{65E5}\u{672C}\u{8A9E}"
        case .ko: return "\u{D55C}\u{AD6D}\u{C5B4}"
        case .es: return "Espa\u{00F1}ol"
        case .fr: return "Fran\u{00E7}ais"
        case .de: return "Deutsch"
        case .pt: return "Portugu\u{00EA}s (Brasil)"
        case .ptPT: return "Portugu\u{00EA}s (Portugal)"
        case .ru: return "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"
        case .ar: return "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"
        case .hi: return "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"
        case .it: return "Italiano"
        case .nl: return "Nederlands"
        case .tr: return "T\u{00FC}rk\u{00E7}e"
        case .pl: return "Polski"
        case .sv: return "Svenska"
        case .da: return "Dansk"
        case .no: return "Norsk (Bokmål)"
        case .nn: return "Norsk (Nynorsk)"
        case .th: return "\u{0E44}\u{0E17}\u{0E22}"
        case .vi: return "Ti\u{1EBF}ng Vi\u{1EC7}t"
        case .custom: return ""
        }
    }

    /// Name to drop into the Claude prompt (e.g. "Korean", "Klingon"). Returns
    /// nil for `.matchTranscript`, signalling the caller to inject no directive.
    var promptLanguageName: String? {
        switch self {
        case .matchTranscript: return nil
        case .custom(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return displayName
        }
    }

    /// Code persisted on `StructuredNote.language` so a re-opened note remembers
    /// what language it was generated in. nil = matched transcript at gen time.
    var storageCode: String? {
        switch self {
        case .matchTranscript: return nil
        case .custom(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "custom:\(trimmed)"
        case .en: return "en"
        case .zh: return "zh"
        case .zhHant: return "zh-Hant"
        case .yue: return "yue"
        case .ja: return "ja"
        case .ko: return "ko"
        case .es: return "es"
        case .fr: return "fr"
        case .de: return "de"
        case .pt: return "pt"
        case .ptPT: return "pt-PT"
        case .ru: return "ru"
        case .ar: return "ar"
        case .hi: return "hi"
        case .it: return "it"
        case .nl: return "nl"
        case .tr: return "tr"
        case .pl: return "pl"
        case .sv: return "sv"
        case .da: return "da"
        case .no: return "no"
        case .nn: return "nn"
        case .th: return "th"
        case .vi: return "vi"
        }
    }

    /// Inverse of `storageCode`. nil input → `.matchTranscript`.
    static func fromStorageCode(_ code: String?) -> SummaryLanguage {
        guard let code, !code.isEmpty else { return .matchTranscript }
        if code.hasPrefix("custom:") {
            return .custom(String(code.dropFirst("custom:".count)))
        }
        return SummaryLanguage(rawValue: code) ?? .custom(code)
    }
}

// MARK: - RawRepresentable for UserDefaults

extension SummaryLanguage: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "match": self = .matchTranscript
        case "en": self = .en
        case "zh": self = .zh
        case "zh-Hant": self = .zhHant
        case "yue": self = .yue
        case "ja": self = .ja
        case "ko": self = .ko
        case "es": self = .es
        case "fr": self = .fr
        case "de": self = .de
        case "pt": self = .pt
        case "pt-PT": self = .ptPT
        case "ru": self = .ru
        case "ar": self = .ar
        case "hi": self = .hi
        case "it": self = .it
        case "nl": self = .nl
        case "tr": self = .tr
        case "pl": self = .pl
        case "sv": self = .sv
        case "da": self = .da
        case "no": self = .no
        case "nn": self = .nn
        case "th": self = .th
        case "vi": self = .vi
        default:
            if rawValue.hasPrefix("custom:") {
                self = .custom(String(rawValue.dropFirst("custom:".count)))
            } else {
                return nil
            }
        }
    }

    var rawValue: String {
        switch self {
        case .matchTranscript: return "match"
        case .en: return "en"
        case .zh: return "zh"
        case .zhHant: return "zh-Hant"
        case .yue: return "yue"
        case .ja: return "ja"
        case .ko: return "ko"
        case .es: return "es"
        case .fr: return "fr"
        case .de: return "de"
        case .pt: return "pt"
        case .ptPT: return "pt-PT"
        case .ru: return "ru"
        case .ar: return "ar"
        case .hi: return "hi"
        case .it: return "it"
        case .nl: return "nl"
        case .tr: return "tr"
        case .pl: return "pl"
        case .sv: return "sv"
        case .da: return "da"
        case .no: return "no"
        case .nn: return "nn"
        case .th: return "th"
        case .vi: return "vi"
        case .custom(let name): return "custom:\(name)"
        }
    }
}

extension SummaryLanguage: Codable {}
