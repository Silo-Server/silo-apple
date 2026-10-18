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

    /// Two users with one name are told apart by the server (plan G7). A
    /// card whose server label already names that server doesn't repeat it
    /// in the title; VoiceOver still reads the full name.
    func testSharedNamesAreToldApart() {
        let directory = D.directory([
            .init(id: "a", signIns: [.init(serverID: D.home, accountID: "12", username: "alex")]),
            .init(id: "b", signIns: [.init(serverID: D.friend, accountID: "40", username: "alex")]),
        ])
        let cards = ChooseUserViewModel(directory: directory).cards
        XCTAssertEqual(cards.map(\.name), ["alex", "alex"])
        XCTAssertEqual(cards.map(\.serverLabel), ["Home Silo", "Friend's Silo"])
        XCTAssertEqual(cards.map(\.accessibilityName), ["alex · Home Silo", "alex · Friend's Silo"])
    }

    /// The title leaves out only the server its label shows: a user with
    /// two servers keeps the server it was told apart by, and "(2)"
    /// numbering stays.
    func testACardTitleLeavesOutOnlyTheServerItsLabelShows() {
        let directory = D.directory([
            .init(id: "two", signIns: [
                .init(serverID: D.home, accountID: "12", username: "alex"),
                .init(serverID: D.friend, accountID: "40", username: "alex"),
            ]),
            .init(id: "one", signIns: [.init(serverID: D.home, accountID: "13", username: "alex")]),
            .init(id: "den", displayName: "Den", signIns: [.init(serverID: D.home, accountID: "14", username: "kim")]),
            .init(id: "den2", displayName: "Den", signIns: [.init(serverID: D.home, accountID: "15", username: "lee")]),
        ])
        XCTAssertEqual(directory.users.map(\.name),
                       ["alex · Home Silo · Friend's Silo", "alex · Home Silo", "Den · Home Silo", "Den · Home Silo (2)"])

        let cards = ChooseUserViewModel(directory: directory).cards

        XCTAssertEqual(cards.map(\.name), ["alex · Home Silo · Friend's Silo", "alex", "Den", "Den (2)"])
        XCTAssertEqual(cards.map(\.fullName), [nil, "alex · Home Silo", "Den · Home Silo", "Den · Home Silo (2)"])
        XCTAssertEqual(directory.users[0].name(besides: ["Home Silo"]), "alex · Friend's Silo")
        XCTAssertEqual(directory.users[0].name(besides: ["Home Silo", "Friend's Silo"]), "alex")
        XCTAssertEqual(directory.users[3].name(besides: ["Friend's Silo"]), "Den · Home Silo (2)")
    }
}
