import Foundation

@MainActor
final class SummaryLanguageSettings: ObservableObject {
    static let shared = SummaryLanguageSettings()

    private let defaultLanguageKey = "defaultSummaryLanguage"
    private let lastCustomKey = "lastCustomSummaryLanguage"

    @Published var defaultLanguage: SummaryLanguage {
        didSet {
            UserDefaults.standard.set(defaultLanguage.rawValue, forKey: defaultLanguageKey)
            if case .custom(let name) = defaultLanguage,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastCustomLanguage = name
            }
        }
    }

    @Published var lastCustomLanguage: String {
        didSet {
            UserDefaults.standard.set(lastCustomLanguage, forKey: lastCustomKey)
        }
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: defaultLanguageKey) ?? "match"
        self.defaultLanguage = SummaryLanguage(rawValue: savedRaw) ?? .matchTranscript
        self.lastCustomLanguage = UserDefaults.standard.string(forKey: lastCustomKey) ?? ""
    }
}
