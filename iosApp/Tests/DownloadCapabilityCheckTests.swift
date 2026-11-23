import Foundation
import XCTest
@testable import Silo

/// Which store the download check loads, and when it reads the capability
/// again. A store loaded for one account while requests ran as another
/// could never read its capability, so Download stayed hidden. Whether that
/// state caused the reported relaunch-only Download is not established.
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

    /// A profile picked while the session was being captured: the selection,
    /// read after it, names the profile requests now use.
    func testSelectionProfileWinsForTheSameAccount() {
        let picked = scope(signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: "p1"),
                           selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: "p2"))
        XCTAssertEqual(picked, .init(serverId: "s1", localAccountId: "a", profileId: "p2", selectionDisagreed: false))
        // Back to Who's Watching during the capture: nothing loads.
        let cleared = scope(signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: "p1"),
                            selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: nil))
        XCTAssertEqual(cleared.profileId, "")
    }

    /// Who's Watching: signed in, no profile yet. Nothing loads.
    func testNoProfileMeansNoScope() {
        let choice = scope(signedIn: Identity(serverId: "s1", localAccountId: "a", profileId: nil),
                           selection: AccountScope(serverId: "s1", localAccountId: "a", profileId: nil))
        XCTAssertEqual(choice.profileId, "")
    }

    // MARK: When to read

    func testMissingCapabilityIsAlwaysRead() {
        let now = Date()
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(hasAnswer: false, fetchedAt: now, now: now))
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(hasAnswer: true, fetchedAt: nil, now: now))
    }

    /// Any answer, a "no" included, is trusted for a few minutes, so browsing
    /// titles on a server without downloads doesn't ask on every page.
    func testFreshAnswerIsNotReadAgain() {
        let now = Date()
        XCTAssertFalse(DownloadManager.capabilityReadIsDue(hasAnswer: true, fetchedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(
            hasAnswer: true, fetchedAt: now.addingTimeInterval(-DownloadManager.capabilityMaxAge), now: now))
        // A clock that moved backwards doesn't freeze an old answer.
        XCTAssertTrue(DownloadManager.capabilityReadIsDue(hasAnswer: true, fetchedAt: now.addingTimeInterval(600), now: now))
    }
}
