import XCTest
@testable import Silo

final class PlayerEndTimeTests: XCTestCase {
    // 2026-11-09 18:21:00 UTC
    private let now = Date(timeIntervalSince1970: 1_794_248_460)
    private var style: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US_POSIX"))
        style.timeZone = TimeZone(identifier: "UTC")!
        return style
    }

    func testAddsTheTimeLeftToTheClock() {
        XCTAssertEqual(normalized(PlayerEndTime.label(now: now, remaining: 2_400, speed: 1, style: style)), "Ends 7:01 PM")
    }

    func testCountsRealTimeAtThePlaybackSpeed() {
        XCTAssertEqual(normalized(PlayerEndTime.label(now: now, remaining: 2_400, speed: 2, style: style)), "Ends 6:41 PM")
    }

    func testFallsBackToNormalSpeedWhenTheSpeedIsUnusable() {
        XCTAssertEqual(normalized(PlayerEndTime.label(now: now, remaining: 2_400, speed: 0, style: style)), "Ends 7:01 PM")
    }

    func testHasNoLabelWithoutATimeLeft() {
        XCTAssertNil(PlayerEndTime.label(now: now, remaining: 0, speed: 1, style: style))
        XCTAssertNil(PlayerEndTime.label(now: now, remaining: .nan, speed: 1, style: style))
        XCTAssertNil(PlayerEndTime.label(now: now, remaining: .infinity, speed: 1, style: style))
    }

    /// Foundation may separate the day period with a narrow no-break space.
    private func normalized(_ label: String?) -> String? {
        label?.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
