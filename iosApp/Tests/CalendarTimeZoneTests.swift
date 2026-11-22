import XCTest
@testable import Silo

/// After a device timezone change, Calendar asks for the same week in the
/// new zone: a Monday-to-Sunday range and a matching `timezone` (issue #516).
@MainActor
final class CalendarTimeZoneTests: XCTestCase {
    func testLoadAfterATimeZoneChangeRequestsTheSameWeekInTheNewZone() async throws {
        let auckland = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // Today is outside the shown week, so the selection falls back to its first day.
        let today = try date(2026, 6, 1, in: auckland)
        var device = auckland
        var requests: [(start: String, end: String, timezone: String)] = []
        let viewModel = CalendarViewModel(now: { today }, deviceTimeZone: { device }) { start, end, _, timezone in
            requests.append((start, end, timezone))
            throw CancellationError()
        }
        // Monday 2 November 2026 in Auckland is still Sunday in Los Angeles.
        let wednesday = try date(2026, 11, 4, in: auckland)
        viewModel.week = CalendarWeek(containing: wednesday, timeZone: auckland)

        await viewModel.load()
        device = losAngeles
        await viewModel.load()

        XCTAssertEqual(requests.map(\.timezone), ["Pacific/Auckland", "America/Los_Angeles"])
        XCTAssertEqual(requests.map(\.start), ["2026-11-02", "2026-11-02"])
        XCTAssertEqual(requests.map(\.end), ["2026-11-08", "2026-11-08"])
        XCTAssertEqual(viewModel.week.days.count, 7)
        XCTAssertEqual(viewModel.selectedDay, viewModel.week.startDate)
    }

    func testTimeZoneChangeDuringTheCurrentWeekKeepsTodaySelected() async throws {
        let auckland = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = try date(2026, 11, 4, in: auckland)
        var device = auckland
        let viewModel = CalendarViewModel(now: { today }, deviceTimeZone: { device }) { _, _, _, _ in
            throw CancellationError()
        }

        device = losAngeles
        await viewModel.load()

        XCTAssertEqual(viewModel.week.timeZone.identifier, "America/Los_Angeles")
        XCTAssertEqual(viewModel.selectedDay, today)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
