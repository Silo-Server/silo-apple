import XCTest
@testable import Silo

final class DownloadScopePolicyTests: XCTestCase {
    func testRequiresReloadWhenProfileChanges() {
        XCTAssertTrue(
            DownloadScopePolicy.requiresReload(
                currentServerId: "server-a",
                currentProfileId: "profile-a",
                nextServerId: "server-a",
                nextProfileId: "profile-b"
            )
        )
    }

    func testRequiresReloadWhenServerChanges() {
        XCTAssertTrue(
            DownloadScopePolicy.requiresReload(
                currentServerId: "server-a",
                currentProfileId: "profile-a",
                nextServerId: "server-b",
                nextProfileId: "profile-a"
            )
        )
    }

    func testRequiresReloadWhenDestinationHasNoProfile() {
        XCTAssertTrue(
            DownloadScopePolicy.requiresReload(
                currentServerId: "server-a",
                currentProfileId: "profile-a",
                nextServerId: "server-a",
                nextProfileId: ""
            )
        )
    }

    func testDoesNotReloadForTheSameScope() {
        XCTAssertFalse(
            DownloadScopePolicy.requiresReload(
                currentServerId: "server-a",
                currentProfileId: "profile-a",
                nextServerId: "server-a",
                nextProfileId: "profile-a"
            )
        )
    }

    func testUnmatchedStagedMediaIsPreservedAcrossScopeChanges() {
        XCTAssertFalse(DownloadScopePolicy.shouldDeleteUnmatchedStagedMedia())
    }
}
