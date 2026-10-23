import Foundation
import XCTest
@testable import Silo

/// A sign-in key is joined into keychain account names and launch-state map
/// keys, so an invalid part could make two sign-ins share one slot.
final class SignInKeyTests: XCTestCase {
    func testValidationRejectsPartsThatWouldBreakTheJoins() {
        XCTAssertNotNil(SignInKey(serverID: "aHR0cHM6Ly9ob21lLmV4YW1wbGU", accountID: "12"))
        XCTAssertNotNil(SignInKey(serverID: "s", accountID: String(repeating: "9", count: 128)))

        for serverID in ["", "a.b", "a/b"] {
            XCTAssertNil(SignInKey(serverID: serverID, accountID: "12"), "server ID \(serverID.debugDescription)")
        }
        let invalidAccounts = [
            "", "1.2", "1/2", " 12", "12 ", "1\n2", "1\t2", "1\u{0}2", "1\u{200B}2",
            String(repeating: "9", count: 129),
        ]
        for accountID in invalidAccounts {
            XCTAssertNil(SignInKey(serverID: "s", accountID: accountID), "account ID \(accountID.debugDescription)")
        }
    }

    func testStorageKeyRoundTripsAndRejectsMalformedKeys() throws {
        let key = try XCTUnwrap(SignInKey(serverID: "aHR0cHM6Ly9ob21l", accountID: "42"))
        XCTAssertEqual(key.storageKey, "aHR0cHM6Ly9ob21l/42")
        XCTAssertEqual(SignInKey(storageKey: key.storageKey), key)

        for malformed in ["", "s", "s/", "/42", "s/4/2", "s.x/42", "s/4.2"] {
            XCTAssertNil(SignInKey(storageKey: malformed), malformed)
        }
    }

    func testCompositeKeysDoNotCollide() throws {
        let first = try XCTUnwrap(SignInKey(serverID: "ab", accountID: "c"))
        let second = try XCTUnwrap(SignInKey(serverID: "a", accountID: "bc"))

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.storageKey, second.storageKey)
        XCTAssertNotEqual(SharedStorage.signInAccount(first), SharedStorage.signInAccount(second))
        XCTAssertNotEqual(SharedStorage.signInProofAccount(first), SharedStorage.signInProofAccount(second))
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    /// On iOS and macOS both keychain audiences address the same item, so a
    /// sign-in, its proof, and the old per-server items need distinct names.
    func testSignInAndProofAccountsDifferFromEachOtherAndFromPerServerItems() throws {
        let key = try XCTUnwrap(SignInKey(serverID: "server", accountID: "7"))
        let perServer = [
            SharedStorage.accessTokenAccount(for: key.serverID),
            SharedStorage.refreshTokenAccount(for: key.serverID),
            SharedStorage.profileTokenAccount(for: key.serverID),
            SharedStorage.accountEpochAccount(for: key.serverID),
            AccountSessionPersistence.recordKey(key.serverID),
            AccountSessionPersistence.markerKey(key.serverID),
            SharedStorage.usersIndexAccount,
            SharedStorage.usersIndexBackupAccount,
        ]
        let names = [SharedStorage.signInAccount(key), SharedStorage.signInProofAccount(key)] + perServer
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(SharedStorage.signInProofAccount(key).hasPrefix(SharedStorage.signInAccountPrefix))
    }

    func testDecodingRejectsInvalidPairs() throws {
        let key = try XCTUnwrap(SignInKey(serverID: "server", accountID: "7"))
        let encoded = try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(SignInKey.self, from: encoded), key)

        let invalid = [
            #"{"serverID":"a.b","accountID":"7"}"#,
            #"{"serverID":"server","accountID":""}"#,
            #"{"serverID":"server","accountID":"7/8"}"#,
            #"{"serverID":"","accountID":"7"}"#,
            #"{"serverID":"server"}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(SignInKey.self, from: Data(json.utf8)), json)
        }
    }
}
