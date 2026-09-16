import Foundation
import Security
import XCTest
@testable import Silo

/// `getChecked` is the strict read behind canonical session authority. An
/// item that exists but cannot be decoded is a corrupt record, not an absent
/// one, and must fail closed instead of reading as "signed out".
final class SharedKeychainCheckedReadTests: XCTestCase {
    private var service = ""
    private var keychain: SharedKeychain!

    override func setUp() {
        super.setUp()
        service = "SharedKeychainCheckedReadTests.\(UUID().uuidString)"
        keychain = SharedKeychain(service: service, accessGroup: nil)
    }

    override func tearDown() {
        keychain.delete("utf8")
        keychain.delete("binary")
        super.tearDown()
    }

    func testCheckedReadDistinguishesAbsentDecodableAndUndecodableItems() throws {
        XCTAssertNil(try keychain.getChecked("utf8"), "no item is a plain nil")

        XCTAssertTrue(keychain.set("value", for: "utf8"))
        XCTAssertEqual(try keychain.getChecked("utf8"), "value")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "binary",
            kSecValueData as String: Data([0xFF, 0xFE, 0xFD]),
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        XCTAssertThrowsError(try keychain.getChecked("binary")) { error in
            XCTAssertEqual((error as? SharedKeychain.ReadError)?.status, errSecDecode)
        }
        XCTAssertNil(keychain.get("binary"), "the lenient read still treats it as no value")
    }
}
