import XCTest
@testable import Silo

/// Choose a Server's rows (spec §5.3): the username only when it says
/// something the user's name doesn't (always once renamed), Active or Sign
/// in again, and focus.
final class ChooseServerViewModelTests: XCTestCase {
    private typealias D = SiloUserDirectoryFixture

    func testRowsShowUsernameOnlyWhenItDiffers() throws {
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex"),
                .init(serverID: D.friend, accountID: "40", username: "alexander"),
            ]),
        ], currentUserID: "alex", currentServerID: D.home)

        let model = try XCTUnwrap(ChooseServerViewModel(directory: directory, userID: "alex"))

        XCTAssertEqual(model.rows.map(\.name), ["Home Silo", "Friend's Silo"])
        XCTAssertEqual(model.rows.map(\.username), [nil, "alexander"])
        XCTAssertEqual(model.rows.map(\.status), [.active, .none])
        XCTAssertEqual(model.focusServerID, D.home)
        XCTAssertEqual(model.rows.first?.key, .make(D.home, "12"))
    }

    func testRenamedUsersAlwaysShowUsernames() throws {
        let directory = D.directory([
            .init(id: "sam", displayName: "Living Room", signIns: [
                .init(serverID: D.home, accountID: "13", username: "sam"),
            ]),
        ])
        let model = try XCTUnwrap(ChooseServerViewModel(directory: directory, userID: "sam"))
        XCTAssertEqual(model.rows.map(\.username), ["sam"])
        XCTAssertEqual(model.userName, "Living Room")
    }

    /// Another user's servers: Active marks its last one; an expired
    /// sign-in reads Sign in again; a pending legacy server has no key to
    /// sign out of.
    func testStatusAndKeys() throws {
        var state = ProfileLaunchState()
        state.lastServerByUserID = ["alex": D.friend]
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.friend, accountID: "40", username: "alex", isSignedIn: false),
            ], pendingLegacyServerIDs: [D.home]),
            .init(id: "sam", signIns: [.init(serverID: D.home, accountID: "13", username: "sam")]),
        ], state: state, currentUserID: "sam", currentServerID: D.home)

        let model = try XCTUnwrap(ChooseServerViewModel(directory: directory, userID: "alex", focusServerID: D.home))

        XCTAssertEqual(model.rows.map(\.id), [D.friend, D.home])
        XCTAssertEqual(model.rows.map(\.status), [.signInAgain, .none])
        XCTAssertNil(model.rows[1].key)
        XCTAssertEqual(model.focusServerID, D.home)
        XCTAssertEqual(ChooseServerViewModel.Status.signInAgain.label, "Sign in again")
    }

    func testAUserThatIsGoneHasNoModel() {
        XCTAssertNil(ChooseServerViewModel(directory: D.directory([]), userID: "gone"))
    }
}
