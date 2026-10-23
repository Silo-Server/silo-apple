#if os(tvOS)
import XCTest
@testable import Silo

/// The Apple TV account screens' own rules (spec §5.2–§5.7): where focus
/// goes when a card or row disappears, and which Settings › Accounts rows
/// take focus. Card avatars share Who's Watching's
/// (`UserCardAvatarSourceTests`).
final class TVUserFlowPresentationTests: XCTestCase {
    private typealias D = SiloAccountDirectoryFixture

    // MARK: - Focus after a removal

    func testFocusMovesToTheItemThatTookTheRemovedOnesPlace() {
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "b", before: ["a", "b", "c"], after: ["a", "c"]), "c")
    }

    func testFocusMovesBackWhenTheLastItemGoes() {
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "c", before: ["a", "b", "c"], after: ["a", "b"]), "b")
    }

    func testFocusSkipsItemsRemovedTogether() {
        // An account removed from Settings › Accounts: both its rows go.
        XCTAssertEqual(TVFocusNeighbor.replacement(for: "b", before: ["a", "b", "c", "d"], after: ["a", "d"]), "d")
    }

    func testNoReplacementWhileTheItemRemainsOrNothingIsLeft() {
        XCTAssertNil(TVFocusNeighbor.replacement(for: "a", before: ["a", "b"], after: ["a", "b"]))
        XCTAssertNil(TVFocusNeighbor.replacement(for: "a", before: ["a"], after: []))
        XCTAssertNil(TVFocusNeighbor.replacement(for: "z", before: ["a"], after: ["a"]))
    }

    // MARK: - Settings › Accounts

    func testAccountRowsListEachSignOutAndRemoveThenAddAccount() {
        let alex = D.Account(serverID: D.home, accountID: "12", username: "alex")
        let sam = D.Account(serverID: D.home, accountID: "13", username: "sam", isSignedIn: false)
        let pending = D.Account(serverID: D.friend)
        let model = AccountsSettingsViewModel(directory: D.directory([alex, sam, pending]), device: .appleTV)

        XCTAssertEqual(TVAccountsSettingsSection.rows(in: model), [
            .account(alex.ref),
            .remove(alex.ref),
            // Sign In Again takes the Sign Out row's place.
            .account(sam.ref),
            .remove(sam.ref),
            // An account still waiting for the server to name it has no
            // sign-in to sign out of.
            .remove(pending.ref),
            .addAccount,
        ])
    }

    func testLoadingAndUnreadableDirectoriesAreToldApart() {
        XCTAssertEqual(TVUserListPhase(directory: .empty, hasLoaded: false), .loading)
        XCTAssertEqual(TVUserListPhase(directory: .empty, hasLoaded: true), .unavailable)
        XCTAssertEqual(TVUserListPhase(directory: D.directory([]), hasLoaded: false), .ready)
    }
}
#endif
