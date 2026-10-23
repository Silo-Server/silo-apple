import Foundation
import XCTest
@testable import Silo

/// The server step in spec §5.4 and plan §2.9.
final class SignInTargetListTests: XCTestCase {
    private let saved = ["home", "friend", "cabin"]

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey(serverID: server, accountID: account)!
    }

    /// Add Account lists servers that already have accounts too: another
    /// person on the same server is another account.
    func testFirstRunAndAddAccountListEverySavedServerInOrder() {
        XCTAssertEqual(SignInTargetList.step(for: .firstRun, in: saved), .list(serverIDs: saved))
        XCTAssertEqual(SignInTargetList.step(for: .addAccount, in: saved), .list(serverIDs: saved))
        XCTAssertEqual(SignInTargetList.servers(for: .addAccount, in: saved), saved)
    }

    func testNoSavedServersGoStraightToServerSetup() {
        XCTAssertEqual(SignInTargetList.step(for: .firstRun, in: []), .serverSetup)
        XCTAssertEqual(SignInTargetList.step(for: .addAccount, in: []), .serverSetup)
    }

    func testSignInAgainHasNoServerStep() {
        let expired = key("friend", "a2")
        XCTAssertEqual(SignInTargetList.step(for: .signInAgain(expired), in: saved), .signIn(serverID: "friend"))
        XCTAssertEqual(SignInTargetList.step(for: .signInAgain(expired), in: []), .signIn(serverID: "friend"))
        XCTAssertEqual(SignInTargetList.servers(for: .signInAgain(expired), in: saved), [])
    }

    /// "Sign in to…" shows the saved servers it lists, by name and address,
    /// in display order.
    func testTargetRowsFollowTheList() {
        let home = ServerEntry(id: "home", url: "https://home.example", fetchedName: "Home Silo", lastUsedAt: Date())
        let friend = ServerEntry(id: "friend", url: "https://friend.example", fetchedName: "Friend's Silo",
                                 lastUsedAt: Date())

        let model = SignInTargetViewModel(context: .addAccount, servers: [friend, home])

        XCTAssertEqual(model.rows.map(\.id), ["friend", "home"])
        XCTAssertEqual(model.rows.map(\.name), ["Friend's Silo", "Home Silo"])
        XCTAssertEqual(model.rows.map(\.address), ["https://friend.example", "https://home.example"])
        XCTAssertTrue(SignInTargetViewModel(context: .signInAgain(key("home", "a1")), servers: [friend, home])
            .rows.isEmpty)
    }
}
