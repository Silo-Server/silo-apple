import XCTest
@testable import Silo

/// The Who's Watching server chip on iPhone, iPad, and Mac (spec §5.8).
final class ServerChipMenuModelTests: XCTestCase {
    private typealias D = SiloUserDirectoryFixture

    func testSectionsListThisUsersServersAndTheOtherUsers() {
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex"),
                .init(serverID: D.friend, accountID: "40", username: "alex", isSignedIn: false),
            ]),
            .init(id: "sam", signIns: [.init(serverID: D.home, accountID: "13", username: "sam")]),
            .init(id: "kim", signIns: [
                .init(serverID: D.home, accountID: "15", username: "kim"),
                .init(serverID: D.friend, accountID: "41", username: "kim"),
            ]),
        ], currentUserID: "alex", currentServerID: D.home)

        let model = ServerChipMenuModel(directory: directory)

        XCTAssertTrue(model.showsUsers)
        XCTAssertEqual(model.userName, "alex")
        XCTAssertEqual(model.servers.map(\.name), ["Home Silo", "Friend's Silo"])
        XCTAssertEqual(model.servers.map(\.isActive), [true, false])
        XCTAssertEqual(model.servers.map(\.needsSignInAgain), [false, true])
        XCTAssertEqual(model.otherUsers.map(\.name), ["sam", "kim"])
        XCTAssertEqual(model.otherUsers.map(\.detail), ["Home Silo", "2 servers"])
    }

    /// Before Silo users exist the chip offers Change server only, as before.
    func testBeforeMigrationOnlyChangeServer() {
        let model = ServerChipMenuModel(directory: .empty)
        XCTAssertFalse(model.showsUsers)
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertTrue(model.otherUsers.isEmpty)
    }

    /// A single user has no other users to list.
    func testASingleUserListsNoOthers() {
        let directory = D.directory([
            .init(id: "alex", signIns: [.init(serverID: D.home, accountID: "12", username: "alex")]),
        ], currentUserID: "alex", currentServerID: D.home)
        let model = ServerChipMenuModel(directory: directory)
        XCTAssertEqual(model.servers.count, 1)
        XCTAssertTrue(model.otherUsers.isEmpty)
    }
}
