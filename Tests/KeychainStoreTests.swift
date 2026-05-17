import XCTest
@testable import Seminarly

final class KeychainStoreTests: XCTestCase {
    private let testAccount = "seminarly-test-keychain-account"

    override func setUp() {
        super.setUp()
        KeychainStore.delete(for: testAccount)
    }

    override func tearDown() {
        KeychainStore.delete(for: testAccount)
        super.tearDown()
    }

    func testSaveAndLoadKey() throws {
        try KeychainStore.save("sk-test-key-12345", for: testAccount)
        XCTAssertEqual(KeychainStore.load(for: testAccount), "sk-test-key-12345")
        XCTAssertTrue(KeychainStore.exists(for: testAccount))
    }

    func testOverwriteKey() throws {
        try KeychainStore.save("first-key", for: testAccount)
        try KeychainStore.save("second-key", for: testAccount)
        XCTAssertEqual(KeychainStore.load(for: testAccount), "second-key")
    }

    func testDeleteKey() throws {
        try KeychainStore.save("key-to-delete", for: testAccount)
        KeychainStore.delete(for: testAccount)
        XCTAssertNil(KeychainStore.load(for: testAccount))
        XCTAssertFalse(KeychainStore.exists(for: testAccount))
    }

    func testLoadNonExistentReturnsNil() {
        KeychainStore.delete(for: testAccount)
        XCTAssertNil(KeychainStore.load(for: testAccount))
        XCTAssertFalse(KeychainStore.exists(for: testAccount))
    }

    func testIsolationBetweenAccounts() throws {
        let secondAccount = "seminarly-test-keychain-account-2"
        defer { KeychainStore.delete(for: secondAccount) }

        try KeychainStore.save("alpha", for: testAccount)
        try KeychainStore.save("beta", for: secondAccount)

        XCTAssertEqual(KeychainStore.load(for: testAccount), "alpha")
        XCTAssertEqual(KeychainStore.load(for: secondAccount), "beta")

        KeychainStore.delete(for: testAccount)
        XCTAssertNil(KeychainStore.load(for: testAccount))
        XCTAssertEqual(KeychainStore.load(for: secondAccount), "beta")
    }
}
