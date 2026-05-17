import Foundation

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case en
    case zh
    case yue
    case ja
    case ko
    case es
    case fr
    case de
    case pt
    case ru
    case ar
    case hi
    case it
    case nl
    case tr
    case pl
    case sv
    case da
    case no
    case th
    case vi

    var id: String { rawValue }

    /// The WhisperKit language code, or nil for auto-detection.
    var whisperCode: String? {
        switch self {
        case .auto: return nil
        default: return rawValue
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .zh: return "Chinese (Mandarin)"
        case .yue: return "Chinese (Cantonese)"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        case .ar: return "Arabic"
        case .hi: return "Hindi"
        case .it: return "Italian"
        case .nl: return "Dutch"
        case .tr: return "Turkish"
        case .pl: return "Polish"
        case .sv: return "Swedish"
        case .da: return "Danish"
        case .no: return "Norwegian"
        case .th: return "Thai"
        case .vi: return "Vietnamese"
        }
    }

    var nativeName: String {
        switch self {
        case .auto: return "Auto"
        case .en: return "English"
        case .zh: return "\u{4E2D}\u{6587}"
        case .yue: return "\u{5EE3}\u{6771}\u{8A71}"
        case .ja: return "\u{65E5}\u{672C}\u{8A9E}"
        case .ko: return "\u{D55C}\u{AD6D}\u{C5B4}"
        case .es: return "Espa\u{00F1}ol"
        case .fr: return "Fran\u{00E7}ais"
        case .de: return "Deutsch"
        case .pt: return "Portugu\u{00EA}s"
        case .ru: return "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"
        case .ar: return "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"
        case .hi: return "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"
        case .it: return "Italiano"
        case .nl: return "Nederlands"
        case .tr: return "T\u{00FC}rk\u{00E7}e"
        case .pl: return "Polski"
        case .sv: return "Svenska"
        case .da: return "Dansk"
        case .no: return "Norsk"
        case .th: return "\u{0E44}\u{0E17}\u{0E22}"
        case .vi: return "Ti\u{1EBF}ng Vi\u{1EC7}t"
        }
    }
}
