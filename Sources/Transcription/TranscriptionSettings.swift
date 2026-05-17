import Foundation

@MainActor
final class TranscriptionSettings: ObservableObject {
    static let shared = TranscriptionSettings()
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo"

    private let defaultLanguageKey = "defaultTranscriptionLanguage"
    private let whisperModelKey = "whisperModel"

    @Published var defaultLanguage: TranscriptionLanguage {
        didSet {
            UserDefaults.standard.set(defaultLanguage.rawValue, forKey: defaultLanguageKey)
        }
    }

    @Published var whisperModel: String {
        didSet {
            UserDefaults.standard.set(whisperModel, forKey: whisperModelKey)
        }
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: defaultLanguageKey) ?? TranscriptionLanguage.auto.rawValue
        self.defaultLanguage = TranscriptionLanguage(rawValue: savedRaw) ?? .auto
        self.whisperModel = UserDefaults.standard.string(forKey: whisperModelKey) ?? Self.defaultModel
    }
}
