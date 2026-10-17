import Foundation
import XCTest
@testable import Silo

/// Every cell of the placement table in plan §2.9 (spec §5.4.1, §5.5).
final class SignInPlacementPolicyTests: XCTestCase {
    private let created = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey(serverID: server, accountID: account)!
    }

    /// alex has Home (a1) and Friend's (a2); sam has Home (s1); the migrated
    /// user has Cabin pending.
    private var directory: SiloUserDirectorySnapshot {
        SiloUserDirectorySnapshot(users: [
            SiloUser(id: "alex", createdAt: created, signIns: [key("home", "a1"), key("friend", "a2")]),
            SiloUser(id: "sam", createdAt: created, signIns: [key("home", "s1")]),
            SiloUser(id: "migrated", createdAt: created, signIns: [], pendingLegacyServerIDs: ["cabin"]),
        ])
    }

    private func decide(
        _ context: SignInContext,
        _ server: String,
        _ account: String,
        username: String? = "new"
    ) -> SignInPlacementDecision? {
        SignInPlacementPolicy.decide(
            context: context,
            serverID: server,
            accountID: account,
            username: username,
            directory: directory
        )
    }

    // MARK: - First run and Add User

    func testFirstRunWithANewAccountCreatesAUser() {
        XCTAssertEqual(decide(.firstRun, "home", "n1"), .place(.newUser))
        XCTAssertEqual(
            SignInPlacementPolicy.decide(context: .firstRun, serverID: "home", accountID: "n1", username: nil, directory: .empty),
            .place(.newUser)
        )
    }

    func testFirstRunWithASavedAccountSwitchesToItsUser() {
        XCTAssertEqual(decide(.firstRun, "home", "s1"), .switchToExisting(key: key("home", "s1"), userID: "sam"))
    }

    func testAddUserWithANewAccountCreatesAUser() {
        XCTAssertEqual(decide(.addUser, "home", "n1"), .place(.newUser))
        XCTAssertEqual(decide(.addUser, "cabin", "n1"), .place(.newUser))
    }

    func testAddUserWithASavedAccountSwitchesToItsUser() {
        XCTAssertEqual(decide(.addUser, "friend", "a2"), .switchToExisting(key: key("friend", "a2"), userID: "alex"))
    }

    // MARK: - Add Server

    func testAddServerWithAnAccountAlreadyInTheUserRefreshesIt() {
        XCTAssertEqual(decide(.addServer(userID: "alex"), "home", "a1"), .place(.refresh(key("home", "a1"))))
    }

    func testAddServerWithAnAccountInAnotherUserAsksToSwitch() {
        XCTAssertEqual(
            decide(.addServer(userID: "alex"), "home", "s1"),
            .ask(.switchToUser(userID: "sam", key: key("home", "s1")))
        )
    }

    func testAddServerWithAnotherAccountOnAServerTheUserHasAsksForASeparateUser() {
        XCTAssertEqual(
            decide(.addServer(userID: "alex"), "home", "n1", username: "jo"),
            .ask(.separateUser(existingUserID: "alex", newUsername: "jo"))
        )
        XCTAssertEqual(
            decide(.addServer(userID: "alex"), "home", "n1", username: nil),
            .ask(.separateUser(existingUserID: "alex", newUsername: nil))
        )
    }

    func testAddServerOnAPendingLegacyServerAsksForASeparateUser() {
        XCTAssertEqual(
            decide(.addServer(userID: "migrated"), "cabin", "n1", username: "jo"),
            .ask(.separateUser(existingUserID: "migrated", newUsername: "jo"))
        )
    }

    func testAddServerWithANewServerJoinsTheUserWithoutAsking() {
        XCTAssertEqual(decide(.addServer(userID: "sam"), "friend", "n1"), .place(.join(userID: "sam")))
        XCTAssertEqual(decide(.addServer(userID: "alex"), "cabin", "n1", username: "different"), .place(.join(userID: "alex")))
    }

    func testAddServerToARemovedUserPlacesItAsAddUserWould() {
        XCTAssertEqual(decide(.addServer(userID: "gone"), "cabin", "n1"), .place(.newUser))
        XCTAssertEqual(decide(.addServer(userID: "gone"), "home", "s1"), .switchToExisting(key: key("home", "s1"), userID: "sam"))
    }

    // MARK: - Sign in again

    func testSignInAgainWithTheSameAccountRefreshesIt() {
        let expired = key("friend", "a2")
        XCTAssertEqual(decide(.signInAgain(userID: "alex", key: expired), "friend", "a2"), .place(.refresh(expired)))
    }

    func testSignInAgainWithAnAccountInAnotherUserAsksToSwitch() {
        XCTAssertEqual(
            decide(.signInAgain(userID: "alex", key: key("home", "a1")), "home", "s1"),
            .ask(.switchToUser(userID: "sam", key: key("home", "s1")))
        )
    }

    func testSignInAgainWithADifferentAccountAsksForASeparateUser() {
        XCTAssertEqual(
            decide(.signInAgain(userID: "alex", key: key("home", "a1")), "home", "n1", username: "jo"),
            .ask(.separateUser(existingUserID: "alex", newUsername: "jo"))
        )
    }

    func testSignInAgainAfterTheSignInWasRemovedJoinsTheUser() {
        XCTAssertEqual(decide(.signInAgain(userID: "sam", key: key("friend", "s2")), "friend", "s2"), .place(.join(userID: "sam")))
    }

    // MARK: - Answers and invalid input

    func testAcceptingAPromptInstallsItsPlacement() {
        XCTAssertEqual(SignInPromptKind.switchToUser(userID: "sam", key: key("home", "s1")).acceptedPlacement, .refresh(key("home", "s1")))
        XCTAssertEqual(SignInPromptKind.separateUser(existingUserID: "alex", newUsername: "jo").acceptedPlacement, .newUser)
    }

    func testAnAccountIDThatCantFormAKeyHasNoPlacement() {
        XCTAssertNil(decide(.addUser, "home", ""))
        XCTAssertNil(decide(.addUser, "home", "a.b"))
        XCTAssertNil(decide(.addServer(userID: "alex"), "", "n1"))
    }
}
