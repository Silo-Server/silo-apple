import Foundation
import XCTest
@testable import Silo

/// User names from spec §4 and plan G3 and G7.
final class SiloUserNamingTests: XCTestCase {
    private let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let serverNames = ["home": "Home Silo", "friend": "Friend's Silo", "cabin": "Cabin"]

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey(serverID: server, accountID: account)!
    }

    private func summary(_ key: SignInKey, _ username: String?) -> SignInSummary {
        SignInSummary(key: key, userID: "", username: username, isSignedIn: true, profiles: [], addedAt: created)
    }

    /// One user per entry: its sign-ins oldest first, as (server, username).
    private func directory(
        _ users: [(id: String, displayName: String?, signIns: [(server: String, username: String?)])],
        pending: [String: [String]] = [:]
    ) -> SiloUserDirectorySnapshot {
        var summaries: [SignInKey: SignInSummary] = [:]
        let siloUsers = users.map { user -> SiloUser in
            let keys = user.signIns.map { key($0.server, "\(user.id)-\($0.server)") }
            for (k, signIn) in zip(keys, user.signIns) { summaries[k] = summary(k, signIn.username) }
            return SiloUser(id: user.id, createdAt: created, displayName: user.displayName, signIns: keys, pendingLegacyServerIDs: pending[user.id])
        }
        return SiloUserDirectorySnapshot(users: siloUsers, signIns: summaries)
    }

    private func names(_ directory: SiloUserDirectorySnapshot) -> [String: String] {
        SiloUserNaming.disambiguatedNames(in: directory, serverNames: serverNames)
    }

    private func name(_ directory: SiloUserDirectorySnapshot, _ index: Int = 0) -> String {
        SiloUserNaming.displayName(for: directory.users[index], in: directory, serverNames: serverNames)
    }

    // MARK: - Default name

    func testDefaultNameIsTheOldestSignInsUsername() {
        let d = directory([("u", nil, [("home", "alex"), ("friend", "al")])])
        XCTAssertEqual(name(d), "alex")
    }

    func testDefaultNameMovesToTheOldestRemainingSignIn() {
        let d = directory([("u", nil, [("friend", "al")])])
        XCTAssertEqual(name(d), "al")
    }

    func testDefaultNameUsesTheServerNameUntilTheUsernameIsKnown() {
        XCTAssertEqual(name(directory([("u", nil, [("home", nil), ("friend", "al")])])), "Home Silo")
        XCTAssertEqual(name(directory([("u", nil, [("home", "  "), ("friend", "al")])])), "Home Silo")
    }

    func testUnreadableOldestSignInUsesItsServerName() {
        let k = key("home", "a1")
        let d = SiloUserDirectorySnapshot(users: [SiloUser(id: "u", createdAt: created, signIns: [k])])
        XCTAssertEqual(name(d), "Home Silo")
    }

    func testUserWithOnlyPendingServersIsNamedAfterTheFirst() {
        let d = directory([("u", nil, [])], pending: ["u": ["friend", "home"]])
        XCTAssertEqual(name(d), "Friend's Silo")
    }

    func testUnknownServerFallsBackToAGenericName() {
        let d = directory([("u", nil, [("elsewhere", nil)])])
        XCTAssertEqual(name(d), SiloUserNaming.fallbackName)
    }

    // MARK: - Rename

    func testRenameWinsOverTheDefaultName() {
        XCTAssertEqual(name(directory([("u", "Living Room", [("home", "alex")])])), "Living Room")
    }

    func testStoredEmptyOrUntrimmedRenameIsNormalized() {
        XCTAssertEqual(name(directory([("u", "   ", [("home", "alex")])])), "alex")
        XCTAssertEqual(name(directory([("u", "  Sam  ", [("home", "alex")])])), "Sam")
    }

    func testNormalizationTrimsCapsAndClears() {
        XCTAssertEqual(SiloUserNaming.normalizedDisplayName("  Sam \n"), "Sam")
        XCTAssertNil(SiloUserNaming.normalizedDisplayName(""))
        XCTAssertNil(SiloUserNaming.normalizedDisplayName(" \n\t "))
        XCTAssertNil(SiloUserNaming.normalizedDisplayName(nil))

        let long = String(repeating: "a", count: 45)
        XCTAssertEqual(SiloUserNaming.normalizedDisplayName(long), String(repeating: "a", count: 40))

        let emoji = String(repeating: "👨‍👩‍👧", count: 41)
        XCTAssertEqual(SiloUserNaming.normalizedDisplayName(emoji)?.count, 40)
    }

    func testCuttingAtTheLimitDropsATrailingSpace() {
        let input = String(repeating: "a", count: 39) + " b"
        XCTAssertEqual(SiloUserNaming.normalizedDisplayName(input), String(repeating: "a", count: 39))
    }

    // MARK: - Shared names (G7)

    func testUniqueNamesStayAsTheyAre() {
        let d = directory([("u1", nil, [("home", "alex")]), ("u2", nil, [("home", "sam")])])
        XCTAssertEqual(names(d), ["u1": "alex", "u2": "sam"])
    }

    func testSharedNamesAddTheFoundingServer() {
        let d = directory([
            ("u1", nil, [("home", "alex"), ("cabin", "al")]),
            ("u2", nil, [("friend", "alex")]),
            ("u3", nil, [("home", "sam")]),
        ])
        XCTAssertEqual(names(d), ["u1": "alex · Home Silo", "u2": "alex · Friend's Silo", "u3": "sam"])
    }

    func testNamesCompareWithoutCase() {
        let d = directory([("u1", nil, [("home", "alex")]), ("u2", "Alex", [("friend", "sam")])])
        XCTAssertEqual(names(d), ["u1": "alex · Home Silo", "u2": "Alex · Friend's Silo"])
    }

    func testStillSharedNamesAddTheNewestServer() {
        let d = directory([
            ("u1", nil, [("home", "alex")]),
            ("u2", "alex", [("home", "sam"), ("friend", "sam")]),
        ])
        XCTAssertEqual(names(d), ["u1": "alex · Home Silo", "u2": "alex · Home Silo · Friend's Silo"])
    }

    func testANameThatIsTheServerNameIsNotRepeated() {
        let d = directory([("u1", nil, [("home", nil)]), ("u2", nil, [("home", nil)])])
        XCTAssertEqual(names(d), ["u1": "Home Silo", "u2": "Home Silo (2)"])
    }

    func testIdenticalUsersAreNumberedInIndexOrder() {
        let d = directory([
            ("u1", "alex", [("home", "a")]),
            ("u2", "alex", [("home", "b")]),
            ("u3", "alex", [("home", "c")]),
        ])
        XCTAssertEqual(names(d), ["u1": "alex · Home Silo", "u2": "alex · Home Silo (2)", "u3": "alex · Home Silo (3)"])
    }
}
