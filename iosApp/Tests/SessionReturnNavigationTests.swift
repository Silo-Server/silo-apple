import SwiftUI
import XCTest
@testable import Silo

/// A revoked session sends the person to sign-in. Signing back in as the same
/// profile of the same account returns them to the screens they were on;
/// anyone else starts at Home.
@MainActor
final class SessionReturnNavigationTests: XCTestCase {
    private let owner = SessionOwner(serverID: "server-a", accountID: "account-1", profileID: "profile-1")

    /// Signs in as `owner`, opens Settings and a series detail, then expires
    /// the session and walks the sign-in flow back to Home as `next`.
    private func expireAndSignBackIn(as next: SessionOwner?) -> AppRouter {
        let router = AppRouter()
        var current: SessionOwner? = owner
        router.sessionOwner = { current }
        router.resetToHome()
        router.navigate(to: .settings)
        router.presentItemDetail(contentId: "series:the-wire")

        router.expiredSession()
        XCTAssertNotEqual(router.authState, .authenticated)
        XCTAssertTrue(router.path.isEmpty)
        #if os(iOS)
        XCTAssertNil(router.presentedItemDetail)
        #endif

        current = next
        router.showProfileSelection()
        router.resetToHome()
        return router
    }

    func testSameProfileReturnsToTheScreensItWasOn() {
        let router = expireAndSignBackIn(as: owner)

        XCTAssertEqual(router.authState, .authenticated)
        #if os(iOS)
        XCTAssertEqual(router.path.count, 1)
        XCTAssertEqual(router.presentedItemDetail?.contentId, "series:the-wire")
        #else
        // tvOS pushes detail onto the same stack.
        XCTAssertEqual(router.path.count, 2)
        #endif
    }

    func testAnotherProfileStartsAtHome() {
        let router = expireAndSignBackIn(as: SessionOwner(
            serverID: "server-a", accountID: "account-1", profileID: "profile-2"
        ))
        assertStartsAtHome(router)
    }

    /// Profile ids are unique only within an account.
    func testSameProfileIdOnAnotherAccountStartsAtHome() {
        let router = expireAndSignBackIn(as: SessionOwner(
            serverID: "server-a", accountID: "account-2", profileID: "profile-1"
        ))
        assertStartsAtHome(router)
    }

    func testUnknownOwnerStartsAtHome() {
        assertStartsAtHome(expireAndSignBackIn(as: nil))
    }

    func testReturnPointIsUsedOnce() {
        let router = expireAndSignBackIn(as: owner)
        router.showProfileSelection()
        router.resetToHome()
        assertStartsAtHome(router)
    }

    func testChangingServerDropsTheReturnPoint() {
        let router = AppRouter()
        router.sessionOwner = { self.owner }
        router.resetToHome()
        router.navigate(to: .settings)
        router.expiredSession()
        router.resetToServerSetup()
        router.showProfileSelection()
        router.resetToHome()
        assertStartsAtHome(router)
    }

    private func assertStartsAtHome(_ router: AppRouter, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(router.authState, .authenticated, file: file, line: line)
        XCTAssertTrue(router.path.isEmpty, file: file, line: line)
        #if os(iOS)
        XCTAssertNil(router.presentedItemDetail, file: file, line: line)
        #endif
    }
}
