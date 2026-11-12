import XCTest
@testable import Silo

final class PlayerEndTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_248_460)

    func testAddsTheTimeLeftToTheClock() {
        XCTAssertEqual(PlayerEndTime.date(now: now, remaining: 2_400, speed: 1), now.addingTimeInterval(2_400))
    }

    func testCountsRealTimeAtThePlaybackSpeed() {
        XCTAssertEqual(PlayerEndTime.date(now: now, remaining: 2_400, speed: 2), now.addingTimeInterval(1_200))
    }

    func testFallsBackToNormalSpeedWhenTheSpeedIsUnusable() {
        XCTAssertEqual(PlayerEndTime.date(now: now, remaining: 2_400, speed: 0), now.addingTimeInterval(2_400))
        XCTAssertEqual(PlayerEndTime.date(now: now, remaining: 2_400, speed: .nan), now.addingTimeInterval(2_400))
    }

    func testHasNoEndTimeWithoutATimeLeft() {
        XCTAssertNil(PlayerEndTime.date(now: now, remaining: 0, speed: 1))
        XCTAssertNil(PlayerEndTime.date(now: now, remaining: .nan, speed: 1))
        XCTAssertNil(PlayerEndTime.date(now: now, remaining: .infinity, speed: 1))
    }

    func testLeavesTheTimeAloneWithoutAnEndTime() {
        XCTAssertEqual(
            PlayerEndTime.appending(to: "−0:00", now: now, remaining: 0, speed: 1, locale: Locale(identifier: "en_US")),
            "−0:00"
        )
    }
}
