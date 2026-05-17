import Foundation

@MainActor
final class TemplateSettings: ObservableObject {
    static let shared = TemplateSettings()

    private let defaultTemplateKey = "defaultNoteTemplate"
    private let customInstructionsKey = "customTemplateInstructions"

    @Published var defaultTemplate: NoteTemplate {
        didSet {
            UserDefaults.standard.set(defaultTemplate.rawValue, forKey: defaultTemplateKey)
        }
    }

    @Published var customInstructions: String {
        didSet {
            UserDefaults.standard.set(customInstructions, forKey: customInstructionsKey)
        }
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: defaultTemplateKey) ?? NoteTemplate.freeform.rawValue
        self.defaultTemplate = NoteTemplate(rawValue: savedRaw) ?? .freeform
        self.customInstructions = UserDefaults.standard.string(forKey: customInstructionsKey) ?? ""
    }
}
