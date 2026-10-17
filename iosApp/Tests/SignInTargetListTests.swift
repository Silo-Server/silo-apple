import Foundation
import XCTest
@testable import Silo

/// The server step in spec §5.4 and plan §2.9.
final class SignInTargetListTests: XCTestCase {
    private let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let saved = ["home", "friend", "cabin"]

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey(serverID: server, accountID: account)!
    }

    /// alex has Home and Friend's; the migrated user has Home signed in and
    /// Cabin pending.
    private var directory: SiloUserDirectorySnapshot {
        SiloUserDirectorySnapshot(users: [
            SiloUser(id: "alex", createdAt: created, signIns: [key("home", "a1"), key("friend", "a2")]),
            SiloUser(id: "migrated", createdAt: created, signIns: [key("home", "m1")], pendingLegacyServerIDs: ["cabin"]),
        ])
    }

    private func step(_ context: SignInContext, saved: [String]? = nil) -> SignInServerStep {
        SignInTargetList.step(for: context, in: saved ?? self.saved, directory: directory)
    }

    func testFirstRunAndAddUserListEverySavedServerInOrder() {
        XCTAssertEqual(step(.firstRun), .list(serverIDs: saved))
        XCTAssertEqual(step(.addUser), .list(serverIDs: saved))
    }

    func testNoSavedServersGoStraightToServerSetup() {
        XCTAssertEqual(step(.firstRun, saved: []), .serverSetup)
        XCTAssertEqual(step(.addUser, saved: []), .serverSetup)
        XCTAssertEqual(step(.addServer(userID: "alex"), saved: []), .serverSetup)
    }

    func testAddServerLeavesOutTheUsersServers() {
        XCTAssertEqual(step(.addServer(userID: "alex")), .list(serverIDs: ["cabin"]))
    }

    func testAddServerLeavesOutPendingLegacyServers() {
        XCTAssertEqual(step(.addServer(userID: "migrated")), .list(serverIDs: ["friend"]))
    }

    func testAddServerGoesToServerSetupWhenTheUserHasEverySavedServer() {
        XCTAssertEqual(step(.addServer(userID: "alex"), saved: ["friend", "home"]), .serverSetup)
    }

    func testAddServerForARemovedUserListsEverySavedServer() {
        XCTAssertEqual(step(.addServer(userID: "gone")), .list(serverIDs: saved))
    }

    func testSignInAgainHasNoServerStep() {
        let expired = key("friend", "a2")
        XCTAssertEqual(step(.signInAgain(userID: "alex", key: expired)), .signIn(serverID: "friend"))
        XCTAssertEqual(
            SignInTargetList.servers(for: .signInAgain(userID: "alex", key: expired), in: saved, directory: directory),
            []
        )
    }

    func testUserServersAreSignInsThenPendingEachOnce() {
        let user = SiloUser(
            id: "u",
            createdAt: created,
            signIns: [key("friend", "f1"), key("home", "h1")],
            pendingLegacyServerIDs: ["cabin", "home"]
        )
        XCTAssertEqual(SignInTargetList.serverIDs(in: user), ["friend", "home", "cabin"])
    }

    func testContextUserID() {
        XCTAssertNil(SignInContext.firstRun.userID)
        XCTAssertNil(SignInContext.addUser.userID)
        XCTAssertEqual(SignInContext.addServer(userID: "alex").userID, "alex")
        XCTAssertEqual(SignInContext.signInAgain(userID: "alex", key: key("home", "a1")).userID, "alex")
    }
}
