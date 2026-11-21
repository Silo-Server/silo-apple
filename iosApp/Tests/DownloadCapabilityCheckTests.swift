import Foundation
import XCTest
@testable import Silo

/// Which store the download check loads, and when it reads the capability
/// again. A store loaded for one account while requests ran as another
/// could never read its capability, which hid Download until a relaunch.
final class DownloadCapabilityCheckTests: XCTestCase {
    private typealias Identity = DownloadManager.SignedInIdentity

    private func scope(
        active: String = "s1",
        signedIn: Identity?,
        selection: AccountScope?
    ) -> DownloadManager.ScopeChoice {
        DownloadManager.downloadScope(activeServerId: active, signedIn: signedIn, selection: selection)
    }

    // MARK: Scope

    func testSignedInAccountWinsOverAStaleSelection() {
        let choice = scope(
            signedIn: Identity(serverId: "s1", localAccountId: "new", profileId: "p1"),
            selection: AccountScope(serverId: "s1", localAccountId: "old", profileId: "p1")
        )
        XCTAssertEqual(choice.localAccountId, "new")
        XCTAssertEqual(choice.profileId, "p1")
        XCTAssertTrue(choice.selectionDisagreed)
    }

    func testSignedInAccountLoadsWhenTheSelectionIsMissing() {
        let choice = scope(signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: "p1"), selection: nil)
        XCTAssertEqual(choice, .init(serverId: "s1", localAccountId: "a", profileId: "p1", selectionDisagreed: true))
    }

    func testMatchingSelectionIsNotReported() {
        let choice = scope(
            signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: "p1"),
            selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: "p1")
        )
        XCTAssertFalse(choice.selectionDisagreed)
    }

    /// Offline, or waiting to sign in again: the selected account's
    /// downloads stay playable.
    func testWithoutASessionTheSelectionLoads() {
        let selection = AccountScope(serverId: "s1", localAccountId: "a", profileId: "p1")
        XCTAssertEqual(scope(signedIn: nil, selection: selection),
                       .init(serverId: "s1", localAccountId: "a", profileId: "p1", selectionDisagreed: false))
        // A temporary remote scope names no account.
        XCTAssertEqual(scope(signedIn: Identity(serverId: "s1", localAccountId: nil, profileId: "t"), selection: selection).localAccountId, "a")
    }

    func testASessionOnAnotherServerIsIgnored() {
        let choice = scope(
            signedIn: Identity(serverId: "s2", localAccountId: "b", profileId: "p2"),
            selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: "p1")
        )
        XCTAssertEqual(choice.localAccountId, "a")
    }

    /// Who's Watching: signed in, no profile yet. Nothing loads.
    func testNoProfileMeansNoScope() {
        let choice = scope(signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: nil),
                           selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: nil))
        XCTAssertEqual(choice.profileId, "")
    }

    // MARK: When to read

    func testUnusableOrMissingCapabilityIsAlwaysRead() {
        let now = Date()
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(usable: false, fetchedAt: now, now: now))
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(usable: true, fetchedAt: nil, now: now))
    }

    func testFreshUsableCapabilityIsNotReadAgain() {
        let now = Date()
        XCTAssertFalse(DownloadManager.capabilityReadIsDue(usable: true, fetchedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(
            usable: true, fetchedAt: now.addingTimeInterval(-DownloadManager.capabilityMaxAge), now: now))
        // A clock that moved backwards doesn't freeze an old answer.
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(usable: true, fetchedAt: now.addingTimeInterval(600), now: now))
    }

    func testRetriesBackOffAndStop() {
        XCTAssertNil(DownloadManager.capabilityRetryDelay(afterFailures: 0))
        XCTAssertEqual(DownloadManager.capabilityRetryDelay(afterFailures: 1), .seconds(2))
        XCTAssertEqual(DownloadManager.capabilityRetryDelay(afterFailures: 5), .seconds(60))
        XCTAssertNil(DownloadManager.capabilityRetryDelay(afterFailures: 6))
    }
}
