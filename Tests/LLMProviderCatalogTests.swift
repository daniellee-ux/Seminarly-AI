import XCTest
@testable import Seminarly

final class LLMProviderCatalogTests: XCTestCase {
    func testAllProviderIDsAreUnique() {
        let ids = LLMProviderCatalog.all.map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "Duplicate provider IDs in catalog")
    }

    func testAllKeychainAccountsAreUnique() {
        let accounts = LLMProviderCatalog.all.map(\.keychainAccount)
        let unique = Set(accounts)
        XCTAssertEqual(accounts.count, unique.count, "Duplicate keychain accounts in catalog")
    }

    func testCatalogContainsExpectedProviders() {
        let ids = Set(LLMProviderCatalog.all.map(\.id))
        let expected: Set<String> = [
            "anthropic", "openai", "gemini", "grok",
            "kimi-intl", "kimi-cn", "zhipu", "minimax", "deepseek",
            "doubao-cn", "doubao-intl",
        ]
        XCTAssertEqual(ids, expected)
    }

    func testEveryDescriptorHasNonEmptyDisplayName() {
        for descriptor in LLMProviderCatalog.all {
            XCTAssertFalse(descriptor.displayName.isEmpty, "\(descriptor.id) has empty display name")
        }
    }

    func testEveryDescriptorHasValidBaseURL() {
        for descriptor in LLMProviderCatalog.all {
            if descriptor.kind == .gemini {
                XCTAssertTrue(descriptor.baseURL.contains("{model}"), "Gemini baseURL must contain {model} placeholder")
            } else {
                XCTAssertNotNil(URL(string: descriptor.baseURL), "\(descriptor.id) has invalid baseURL")
            }
        }
    }

    func testAnthropicBackwardCompatibility() {
        let anthropic = LLMProviderCatalog.descriptor(for: "anthropic")
        XCTAssertEqual(anthropic.keychainAccount, "anthropic-api-key",
                       "Anthropic must use the legacy keychain account name for backward compatibility")
    }

    func testDoubaoChinaRequiresEndpointID() {
        let doubaoCN = LLMProviderCatalog.descriptor(for: "doubao-cn")
        XCTAssertTrue(doubaoCN.requiresEndpointID)
        XCTAssertTrue(doubaoCN.defaultModel.isEmpty, "Doubao China must not pre-fill an endpoint ID")
        XCTAssertEqual(doubaoCN.modelFieldLabel, "Endpoint ID")
    }

    func testDoubaoInternationalDoesNotRequireEndpointID() {
        let doubaoIntl = LLMProviderCatalog.descriptor(for: "doubao-intl")
        XCTAssertFalse(doubaoIntl.requiresEndpointID)
        XCTAssertFalse(doubaoIntl.defaultModel.isEmpty)
        XCTAssertEqual(doubaoIntl.modelFieldLabel, "Model")
    }

    func testDefaultProviderIsAnthropic() {
        XCTAssertEqual(LLMProviderCatalog.defaultProviderID, "anthropic")
    }

    func testNonDoubaoProvidersHaveDefaultModels() {
        for descriptor in LLMProviderCatalog.all where descriptor.id != "doubao-cn" {
            XCTAssertFalse(descriptor.defaultModel.isEmpty,
                           "\(descriptor.id) should have a non-empty default model")
        }
    }

    func testProviderKinds() {
        XCTAssertEqual(LLMProviderCatalog.descriptor(for: "anthropic").kind, .anthropic)
        XCTAssertEqual(LLMProviderCatalog.descriptor(for: "gemini").kind, .gemini)
        XCTAssertEqual(LLMProviderCatalog.descriptor(for: "openai").kind, .openAICompatible)
        XCTAssertEqual(LLMProviderCatalog.descriptor(for: "doubao-cn").kind, .openAICompatible)
        XCTAssertEqual(LLMProviderCatalog.descriptor(for: "doubao-intl").kind, .openAICompatible)
    }
}
