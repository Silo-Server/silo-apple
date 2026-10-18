#if os(tvOS)
import XCTest
@testable import Silo

/// The Apple TV user screens' own rules (spec §5.2–§5.7): where focus goes
/// when a card or row disappears, what a server row says, and which
/// Settings › Users rows take focus. Card avatars share Who's Watching's
/// (`UserCardAvatarSourceTests`).
final class TVUserFlowPresentationTests: XCTestCase {
    private typealias D = SiloUserDirectoryFixture

    // MARK: - Focus after a removal

    func testFocusMovesToTheItemThatTookTheRemovedOnesPlace() {
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "b", before: ["a", "b", "c"], after: ["a", "c"]), "c")
    }

    func testFocusMovesBackWhenTheLastItemGoes() {
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "c", before: ["a", "b", "c"], after: ["a", "b"]), "b")
    }

    func testFocusSkipsItemsRemovedTogether() {
        // A user's last server signed out with it: both rows go.
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "b", before: ["a", "b", "c", "d"], after: ["a", "d"]), "d")
    }

    func testNoReplacementWhileTheItemRemainsOrNothingIsLeft() {
        XCTAssertNil(TVFocusNeighbor.replacement(for: "a", before: ["a", "b"], after: ["a", "b"]))
        XCTAssertNil(TVFocusNeighbor.replacement(for: "a", before: ["a"], after: []))
        XCTAssertNil(TVFocusNeighbor.replacement(for: "z", before: ["a"], after: ["a"]))
    }

    // MARK: - Server rows

    func testServerRowNamesTheAccountOnlyWhenItDiffersFromTheUser() throws {
        var state = ProfileLaunchState()
        state.lastServerByUserID = ["alex": D.home]
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex"),
                .init(serverID: D.friend, accountID: "40", username: "alexander", isSignedIn: false),
            ]),
        ], state: state, currentUserID: "alex", currentServerID: D.home)
        let model = try XCTUnwrap(ChooseServerViewModel(directory: directory, userID: "alex"))

        let home = model.rows[0]
        XCTAssertEqual(TVChooseServerContent.detail(for: home), "home.example")
        XCTAssertEqual(TVChooseServerContent.badge(for: home.status), .active)
        XCTAssertEqual(TVChooseServerContent.accessibilityValue(for: home), "Active")

        let friend = model.rows[1]
        XCTAssertEqual(TVChooseServerContent.detail(for: friend), "alexander · friend.example")
        XCTAssertEqual(TVChooseServerContent.badge(for: friend.status), .signInAgain)
        XCTAssertEqual(TVChooseServerContent.accessibilityValue(for: friend), "Signed in as alexander, Sign in again")
    }

    // MARK: - Settings › Users

    func testUsersRowsListEachSignOutThenRenameAndRemoveThenAddUser() {
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex"),
            ], pendingLegacyServerIDs: [D.friend]),
            .init(id: "sam", signIns: [.init(serverID: D.home, accountID: "13", username: "sam")]),
        ])
        let model = UsersSettingsViewModel(directory: directory, device: .appleTV)

        XCTAssertEqual(TVUsersSettingsSection.rows(in: model), [
            .server(userID: "alex", serverID: D.home),
            // A server still waiting for its account has no Sign Out.
            .rename(userID: "alex"),
            .remove(userID: "alex"),
            .server(userID: "sam", serverID: D.home),
            .rename(userID: "sam"),
            .remove(userID: "sam"),
            .addUser,
        ])
    }

    func testLoadingAndUnreadableDirectoriesAreToldApart() {
        XCTAssertEqual(TVUserListPhase(directory: .empty, hasLoaded: false), .loading)
        XCTAssertEqual(TVUserListPhase(directory: .empty, hasLoaded: true), .unavailable)
        XCTAssertEqual(TVUserListPhase(directory: D.directory([]), hasLoaded: false), .ready)
    }
}
#endif
