import XCTest
@testable import Silo

/// The Who's Watching account menu on iPhone, iPad, and Mac (spec §5.8).
final class AccountMenuModelTests: XCTestCase {
    private typealias D = SiloAccountDirectoryFixture

    func testItemsListEveryAccountAndMarkTheCurrentOne() {
        let testadmin = D.Account(serverID: D.home, accountID: "1", username: "testadmin")
        let test = D.Account(serverID: D.home, accountID: "2", username: "test", email: "test@example.com")
        let admin = D.Account(serverID: D.friend, accountID: "1", username: "admin")
        let directory = D.directory([testadmin, test, admin], current: admin.ref)

        let model = AccountMenuModel(directory: directory)

        XCTAssertEqual(model.items.map(\.id), [testadmin.ref, test.ref, admin.ref])
        XCTAssertEqual(model.items.map(\.name), ["testadmin", "test", "admin"])
        XCTAssertEqual(model.items.map(\.detail), ["Home Silo", "test@example.com · Home Silo", "Friend's Silo"])
        XCTAssertEqual(model.items.map(\.isCurrent), [false, false, true])
    }

    /// An expired sign-in adds Sign in again to the item's second line; a
    /// pending legacy account, named by its server, has nothing else to say.
    func testItemDetailsShowSignInAgain() {
        let directory = D.directory([
            .init(serverID: D.home, accountID: "12", username: "alex", isSignedIn: false),
            .init(serverID: D.friend),
        ])

        let model = AccountMenuModel(directory: directory)

        XCTAssertEqual(model.items.map(\.name), ["alex", "Friend's Silo"])
        XCTAssertEqual(model.items.map(\.detail), ["Home Silo · Sign in again", nil])
        XCTAssertEqual(model.items.map(\.isCurrent), [false, false], "nothing is selected")
    }

    /// Before migration there are no accounts to list.
    func testBeforeMigrationListsNoAccounts() {
        XCTAssertTrue(AccountMenuModel(directory: .empty).items.isEmpty)
    }
}
