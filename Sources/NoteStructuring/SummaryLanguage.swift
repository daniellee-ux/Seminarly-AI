import Foundation
import NaturalLanguage

/// Target language for AI-generated summary notes. Distinct from
/// `TranscriptionLanguage`: that controls what WhisperKit listens for, this
/// controls what Claude writes notes in. Default `.matchTranscript` resolves
/// the transcript text to a concrete language before prompt construction.
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

    static func resolvedForTranscript(_ language: SummaryLanguage, transcript: String) -> SummaryLanguage {
        guard language == .matchTranscript else { return language }
        return detectTranscriptLanguage(transcript)
    }

    static func detectTranscriptLanguage(_ text: String) -> SummaryLanguage {
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !sample.isEmpty else { return .en }

        if let chinese = chineseScriptLanguage(in: sample) {
            return chinese
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)

        for (language, confidence) in recognizer.languageHypotheses(withMaximum: 5)
            .sorted(by: { $0.value > $1.value }) where confidence >= 0.15 {
            if let mapped = fromLanguageCode(language.rawValue, sample: sample) {
                return mapped
            }
        }

        if let dominant = recognizer.dominantLanguage,
           let mapped = fromLanguageCode(dominant.rawValue, sample: sample) {
            return mapped
        }

        return .en
    }

    static func fromLanguageCode(_ code: String?, sample: String = "") -> SummaryLanguage? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "en": return .en
        case "zh-hant", "zh-tw", "zh-hk": return .zhHant
        case "zh-hans", "zh-cn", "zh-sg", "zh":
            return chineseScriptLanguage(in: sample, allowLowSignal: true) ?? .zh
        case "yue": return .yue
        case "ja": return .ja
        case "ko": return .ko
        case "es": return .es
        case "fr": return .fr
        case "de": return .de
        case "pt-pt": return .ptPT
        case "pt": return .pt
        case "ru": return .ru
        case "ar": return .ar
        case "hi": return .hi
        case "it": return .it
        case "nl": return .nl
        case "tr": return .tr
        case "pl": return .pl
        case "sv": return .sv
        case "da": return .da
        case "nb", "no": return .no
        case "nn": return .nn
        case "th": return .th
        case "vi": return .vi
        default: return nil
        }
    }

    private static func chineseScriptLanguage(in text: String, allowLowSignal: Bool = false) -> SummaryLanguage? {
        var hanCount = 0
        var bopomofoCount = 0
        var traditionalOnlyCount = 0
        var simplifiedOnlyCount = 0
        var letterCount = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
            }

            let value = scalar.value
            if isHanScalar(value) {
                hanCount += 1
                if traditionalOnlyScalars.contains(value) {
                    traditionalOnlyCount += 1
                }
                if simplifiedOnlyScalars.contains(value) {
                    simplifiedOnlyCount += 1
                }
            } else if isBopomofoScalar(value) {
                bopomofoCount += 1
            }
        }

        let chineseSignalCount = hanCount + bopomofoCount
        guard chineseSignalCount > 0 else { return nil }

        let ratio = Double(chineseSignalCount) / Double(max(letterCount, chineseSignalCount))
        let hasMaterialChinese = chineseSignalCount >= 8 && (ratio >= 0.08 || chineseSignalCount >= 20)
        guard allowLowSignal || hasMaterialChinese else { return nil }

        if bopomofoCount > 0 || traditionalOnlyCount > simplifiedOnlyCount {
            return .zhHant
        }
        if simplifiedOnlyCount > traditionalOnlyCount {
            return .zh
        }
        return .zh
    }

    private static func isHanScalar(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    private static func isBopomofoScalar(_ value: UInt32) -> Bool {
        (0x3100...0x312F).contains(value) || (0x31A0...0x31BF).contains(value)
    }

    private static let traditionalOnlyScalars: Set<UInt32> = [
        0x5167, 0x5718, 0x5834, 0x5C0D, 0x5F8C, 0x64C7, 0x6703, 0x6E96,
        0x7522, 0x78BA, 0x7E41, 0x7E8C, 0x807D, 0x8A0A, 0x8A0E, 0x8A9E,
        0x8AD6, 0x8AAA, 0x8B70, 0x8CC7, 0x9078, 0x9304, 0x9375, 0x95DC,
        0x968A, 0x9806, 0x986F, 0x994B, 0x9AD4, 0x9EDE,
    ]

    private static let simplifiedOnlyScalars: Set<UInt32> = [
        0x4EA7, 0x4F18, 0x4F1A, 0x4F53, 0x5173, 0x5185, 0x51C6, 0x540E,
        0x542C, 0x56E2, 0x573A, 0x5BF9, 0x5F55, 0x62E9, 0x663E, 0x70B9,
        0x786E, 0x7B80, 0x7EED, 0x8BAE, 0x8BA8, 0x8BAF, 0x8BED, 0x8BBA,
        0x8BF4, 0x9009, 0x961F, 0x987A, 0x9988, 0x952E,
    ]
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
