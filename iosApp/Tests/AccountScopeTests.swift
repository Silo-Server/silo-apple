import Foundation
import XCTest
@testable import Silo

/// Local stores build their keys from this scope, so it must be complete and
/// made of parts that can't blur two accounts' keys together.
final class AccountScopeTests: XCTestCase {
    private func makeDefaults() throws -> SharedDefaults {
        let name = "AccountScopeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return SharedDefaults(suite: suite, standard: suite)
    }

    func testCurrentScopeNeedsEveryMirror() throws {
        let defaults = try makeDefaults()
        XCTAssertNil(AccountScopeReader.current(defaults: defaults))

        defaults.set("aG9tZQ", forKey: SharedStorage.activeServerIdKey)
        defaults.set("default", forKey: SharedStorage.profileIdKey)
        XCTAssertNil(AccountScopeReader.current(defaults: defaults), "a legacy selection has no account mirror")
        XCTAssertNil(AccountScopeReader.currentAccountID(defaults: defaults))

        defaults.set("12", forKey: SharedStorage.activeAccountIdKey)
        XCTAssertEqual(AccountScopeReader.current(defaults: defaults),
            AccountScope(serverID: "aG9tZQ", accountID: "12", profileID: "default"))
        XCTAssertEqual(AccountScopeReader.currentAccountID(defaults: defaults), "12")

        defaults.set("", forKey: SharedStorage.profileIdKey)
        XCTAssertNil(AccountScopeReader.current(defaults: defaults))
    }

    func testInvalidMirrorsGiveNoScope() throws {
        let defaults = try makeDefaults()
        defaults.set("default", forKey: SharedStorage.profileIdKey)

        defaults.set("aG9tZQ", forKey: SharedStorage.activeServerIdKey)
        defaults.set("1.2", forKey: SharedStorage.activeAccountIdKey)
        XCTAssertNil(AccountScopeReader.current(defaults: defaults))
        XCTAssertNil(AccountScopeReader.currentAccountID(defaults: defaults))

        defaults.set("a.b", forKey: SharedStorage.activeServerIdKey)
        defaults.set("12", forKey: SharedStorage.activeAccountIdKey)
        XCTAssertNil(AccountScopeReader.current(defaults: defaults))
    }

    func testLegacyOwnersAreReplacedOnPublish() {
        addTeardownBlock { LegacyLocalDataOwner.publish([:]) }

        LegacyLocalDataOwner.publish(["aG9tZQ": "12", "b3RoZXI": "4"])
        XCTAssertEqual(LegacyLocalDataOwner.accountID(forServerID: "aG9tZQ"), "12")
        XCTAssertEqual(LegacyLocalDataOwner.accountID(forServerID: "b3RoZXI"), "4")

        LegacyLocalDataOwner.publish(["aG9tZQ": "12"])
        XCTAssertNil(LegacyLocalDataOwner.accountID(forServerID: "b3RoZXI"))
        XCTAssertNil(LegacyLocalDataOwner.accountID(forServerID: "dW5rbm93bg"))
    }
}
