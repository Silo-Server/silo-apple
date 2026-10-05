import XCTest
@testable import Silo

final class HomeForegroundRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testQuickAppSwitchKeepsHome() {
        XCTAssertFalse(HomeForegroundRefreshPolicy.shouldRefresh(backgroundedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(HomeForegroundRefreshPolicy.shouldRefresh(
            backgroundedAt: now.addingTimeInterval(-HomeForegroundRefreshPolicy.minimumTimeAway + 1), now: now
        ))
    }

    func testReturnAfterMinimumTimeAwayRefreshesHome() {
        XCTAssertTrue(HomeForegroundRefreshPolicy.shouldRefresh(
            backgroundedAt: now.addingTimeInterval(-HomeForegroundRefreshPolicy.minimumTimeAway), now: now
        ))
        XCTAssertTrue(HomeForegroundRefreshPolicy.shouldRefresh(backgroundedAt: now.addingTimeInterval(-3_600), now: now))
    }

    func testNoBackgroundTimestampKeepsHome() {
        XCTAssertFalse(HomeForegroundRefreshPolicy.shouldRefresh(backgroundedAt: nil, now: now))
    }
}
