import XCTest
@testable import Silo

/// Choose a User's cards (spec §5.2): stacked avatars from the last-used
/// server, the server label, Last used, Sign in again, focus, and the hint.
final class ChooseUserViewModelTests: XCTestCase {
    private typealias D = SiloUserDirectoryFixture

    func testCardsDescribeEachUser() {
        var state = ProfileLaunchState()
        state.linkedUserID = "alex"
        state.lastServerByUserID = ["alex": D.friend]
        let directory = D.directory([
            .init(id: "alex", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex", profiles: ["jamie"]),
                .init(serverID: D.friend, accountID: "40", username: "alex", isSignedIn: false,
                      profiles: ["a", "b", "c", "d", "e"]),
            ]),
            .init(id: "sam", signIns: [.init(serverID: D.home, accountID: "13", username: "sam", profiles: ["sam"])]),
        ], state: state)

        let model = ChooseUserViewModel(directory: directory)

        XCTAssertEqual(model.cards.map(\.name), ["alex", "sam"])
        let alex = model.cards[0]
        XCTAssertEqual(alex.serverLabel, "2 servers")
        XCTAssertEqual(alex.avatars.map(\.id), ["a", "b", "c", "d"], "four, from the last-used server")
        XCTAssertTrue(alex.isLastUsed)
        XCTAssertTrue(alex.needsSignInAgain, "the last-used sign-in expired")
        let sam = model.cards[1]
        XCTAssertEqual(sam.serverLabel, "Home Silo")
        XCTAssertFalse(sam.isLastUsed)
        XCTAssertFalse(sam.needsSignInAgain)
        XCTAssertEqual(alex.accessibilityValue, "2 servers, Last used, Sign in again")
    }

    func testFocusPrefersTheAskedForUserThenTheLinkedOne() {
        var state = ProfileLaunchState()
        state.linkedUserID = "sam"
        let directory = D.directory([
            .init(id: "alex", signIns: [.init(serverID: D.home, accountID: "12", username: "alex")]),
            .init(id: "sam", signIns: [.init(serverID: D.home, accountID: "13", username: "sam")]),
        ], state: state)

        XCTAssertEqual(ChooseUserViewModel(directory: directory, focusUserID: "alex").focusUserID, "alex")
        XCTAssertEqual(ChooseUserViewModel(directory: directory, focusUserID: "gone").focusUserID, "sam")
        XCTAssertEqual(ChooseUserViewModel(directory: directory).focusUserID, "sam")
    }

    func testTheHintShowsOnlyWithAUserToHold() {
        XCTAssertFalse(ChooseUserViewModel(directory: D.directory([])).showsRemoveHint)
        XCTAssertNil(ChooseUserViewModel(directory: D.directory([])).focusUserID)
        let one = D.directory([.init(id: "alex", signIns: [.init(serverID: D.home, accountID: "12", username: "alex")])])
        XCTAssertTrue(ChooseUserViewModel(directory: one).showsRemoveHint)
    }

    /// Two users with one name are told apart by the server (plan G7).
    func testSharedNamesAreToldApart() {
        let directory = D.directory([
            .init(id: "a", signIns: [.init(serverID: D.home, accountID: "12", username: "alex")]),
            .init(id: "b", signIns: [.init(serverID: D.friend, accountID: "40", username: "alex")]),
        ])
        XCTAssertEqual(ChooseUserViewModel(directory: directory).cards.map(\.name),
                       ["alex · Home Silo", "alex · Friend's Silo"])
    }
}
