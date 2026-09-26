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

    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: whisperModelKey)
        }
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: defaultLanguageKey) ?? TranscriptionLanguage.auto.rawValue
        self.defaultLanguage = TranscriptionLanguage(rawValue: savedRaw) ?? .auto
        let savedModel = UserDefaults.standard.string(forKey: whisperModelKey) ?? Self.defaultModel
        self.model = savedModel == QwenModelStore.modelID && !QwenModelStore.isSupported
            ? Self.defaultModel : savedModel
        if self.model == QwenModelStore.modelID && self.defaultLanguage == .no {
            self.defaultLanguage = .auto
        }
    }
}
