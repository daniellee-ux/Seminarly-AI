import Foundation

@MainActor
final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    private let selectedProviderKey = "selectedLLMProvider"
    private func modelKey(for providerID: String) -> String {
        "selectedLLMModel.\(providerID)"
    }

    @Published var selectedProviderID: String {
        didSet {
            UserDefaults.standard.set(selectedProviderID, forKey: selectedProviderKey)
            currentModel = Self.loadModel(for: selectedProviderID)
        }
    }

    @Published var currentModel: String {
        didSet {
            UserDefaults.standard.set(currentModel, forKey: modelKey(for: selectedProviderID))
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: selectedProviderKey)
            ?? LLMProviderCatalog.defaultProviderID
        let validated = LLMProviderCatalog.all.contains(where: { $0.id == stored })
            ? stored
            : LLMProviderCatalog.defaultProviderID
        self.selectedProviderID = validated
        self.currentModel = Self.loadModel(for: validated)
    }

    private static func loadModel(for providerID: String) -> String {
        let key = "selectedLLMModel.\(providerID)"
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        if !stored.isEmpty { return stored }
        return LLMProviderCatalog.descriptor(for: providerID).defaultModel
    }

    var currentDescriptor: LLMProviderDescriptor {
        LLMProviderCatalog.descriptor(for: selectedProviderID)
    }

    func resetCurrentModelToDefault() {
        currentModel = currentDescriptor.defaultModel
    }
}
