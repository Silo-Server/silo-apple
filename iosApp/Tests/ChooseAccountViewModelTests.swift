import XCTest
@testable import Silo

/// Choose an Account's cards (spec §5.2): one card per account with its
/// username, email, and server, Last used, Sign in again, focus, and the hint.
final class ChooseAccountViewModelTests: XCTestCase {
    private typealias D = SiloAccountDirectoryFixture

    private func linked(_ account: SiloAccountRef) -> ProfileLaunchState {
        var state = ProfileLaunchState()
        state.linkedAccount = account.storageKey
        return state
    }

    func testCardsDescribeEachAccount() {
        let alex = D.Account(serverID: D.home, accountID: "12", username: "alex", email: "alex@example.com",
                             isSignedIn: false, profiles: ["a", "b", "c", "d", "e"])
        let sam = D.Account(serverID: D.home, accountID: "13", username: "sam", profiles: ["sam"])
        let directory = D.directory([alex, sam], state: linked(alex.ref))

        let model = ChooseAccountViewModel(directory: directory)

        XCTAssertEqual(model.cards.map(\.name), ["alex", "sam"])
        let first = model.cards[0]
        XCTAssertEqual(first.detailLines, ["alex@example.com", "Home Silo"])
        XCTAssertEqual(first.avatars.map(\.id), ["a", "b", "c", "d"], "at most four")
        XCTAssertEqual(first.serverAddress, "https://home.example")
        XCTAssertTrue(first.isLastUsed)
        XCTAssertTrue(first.needsSignInAgain)
        XCTAssertEqual(first.accessibilityValue, "alex@example.com, Home Silo, Last used, Sign in again")
        let second = model.cards[1]
        XCTAssertEqual(second.detailLines, ["Home Silo"], "no email, so the server alone")
        XCTAssertFalse(second.isLastUsed)
        XCTAssertFalse(second.needsSignInAgain)
    }

    /// Two accounts on one server and one on another are three cards: the
    /// server never folds accounts together.
    func testEveryAccountIsItsOwnCard() {
        let directory = D.directory([
            .init(serverID: D.home, accountID: "1", username: "testadmin"),
            .init(serverID: D.home, accountID: "2", username: "test"),
            .init(serverID: D.friend, accountID: "1", username: "admin"),
        ])

        let cards = ChooseAccountViewModel(directory: directory).cards

        XCTAssertEqual(cards.map(\.name), ["testadmin", "test", "admin"])
        XCTAssertEqual(cards.map(\.detailLines), [["Home Silo"], ["Home Silo"], ["Friend's Silo"]])
        XCTAssertEqual(Set(cards.map(\.id)).count, 3)
    }

    /// A migrated session whose server account isn't known yet shows its
    /// server's name, with no second line repeating it.
    func testAPendingLegacyAccountShowsItsServerOnly() {
        let directory = D.directory([.init(serverID: D.friend)])

        let card = ChooseAccountViewModel(directory: directory).cards[0]

        XCTAssertEqual(card.id, .pendingLegacy(serverID: D.friend))
        XCTAssertEqual(card.name, "Friend's Silo")
        XCTAssertEqual(card.detailLines, [])
        XCTAssertFalse(card.needsSignInAgain, "it still signs in with the server's session")
    }

    /// Two saved servers with one name: each card's server line adds its
    /// host, so the accounts can be told apart.
    func testServersSharingANameAreToldApartByHost() {
        let servers = [
            ServerEntry(id: D.home, url: "https://home.example", fetchedName: "Silo", lastUsedAt: Date()),
            ServerEntry(id: D.friend, url: "https://friend.example", fetchedName: "Silo", lastUsedAt: Date()),
        ]
        let directory = D.directory([
            D.Account(serverID: D.home, accountID: "12", username: "alex"),
            D.Account(serverID: D.friend, accountID: "40", username: "alex"),
        ], servers: servers)

        let model = ChooseAccountViewModel(directory: directory)

        XCTAssertEqual(model.cards.map(\.detailLines),
                       [["Silo (\(ServerBranding.hostLabel("https://home.example")))"],
                        ["Silo (\(ServerBranding.hostLabel("https://friend.example")))"]])
    }

    func testFocusPrefersTheAskedForAccountThenTheLinkedOneThenTheFirst() {
        let alex = D.Account(serverID: D.home, accountID: "12", username: "alex")
        let sam = D.Account(serverID: D.friend, accountID: "13", username: "sam")
        let gone = D.Account(serverID: D.friend, accountID: "99").ref
        let directory = D.directory([alex, sam], state: linked(sam.ref))

        XCTAssertEqual(ChooseAccountViewModel(directory: directory, focus: alex.ref).focus, alex.ref)
        XCTAssertEqual(ChooseAccountViewModel(directory: directory, focus: gone).focus, sam.ref)
        XCTAssertEqual(ChooseAccountViewModel(directory: directory).focus, sam.ref)
        XCTAssertEqual(ChooseAccountViewModel(directory: D.directory([alex, sam])).focus, alex.ref)
    }

    func testTheHintShowsOnlyWithAnAccountToHold() {
        XCTAssertFalse(ChooseAccountViewModel(directory: D.directory([])).showsRemoveHint)
        XCTAssertNil(ChooseAccountViewModel(directory: D.directory([])).focus)
        let one = D.directory([.init(serverID: D.home, accountID: "12", username: "alex")])
        XCTAssertTrue(ChooseAccountViewModel(directory: one).showsRemoveHint)
    }
}
