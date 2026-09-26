import XCTest
@testable import Silo

/// Server release/air dates are calendar dates (`YYYY-MM-DD`). They must show
/// the same day in every display zone, while RFC 3339 instants still convert
/// to the display zone. Each test pins the formatter's zone so the result does
/// not depend on the host's time zone.
final class DetailDateFormattingTests: XCTestCase {

    // MARK: - Calendar dates

    func testDateOnlyKeepsCalendarDayWestOfUTC() {
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2024-03-15", formatter: formatter(style: .long, zone: "America/Los_Angeles")),
            "March 15, 2024"
        )
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2024-03-15", formatter: formatter(style: .medium, zone: "America/Los_Angeles")),
            "Mar 15, 2024"
        )
    }

    func testDateOnlyKeepsCalendarDayFarEastOfUTC() {
        // UTC+14: a UTC-noon anchor would roll over to March 16 here.
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2024-03-15", formatter: formatter(style: .long, zone: "Pacific/Kiritimati")),
            "March 15, 2024"
        )
    }

    func testDateOnlyKeepsDayAcrossDSTTransitions() {
        // Spring-forward day in Los Angeles.
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2024-03-10", formatter: formatter(style: .long, zone: "America/Los_Angeles")),
            "March 10, 2024"
        )
        // Sao Paulo skipped local midnight when DST started on this day.
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2018-11-04", formatter: formatter(style: .long, zone: "America/Sao_Paulo")),
            "November 4, 2018"
        )
    }

    func testNonPaddedDateOnlyStillParses() {
        XCTAssertEqual(
            DetailDateFormatting.formattedDate("2024-3-5", formatter: formatter(style: .long, zone: "America/Los_Angeles")),
            "March 5, 2024"
        )
    }

    // MARK: - Instants

    func testInstantsConvertToDisplayZone() {
        let losAngeles = formatter(style: .long, zone: "America/Los_Angeles")
        XCTAssertEqual(DetailDateFormatting.formattedDate("2024-03-15T02:00:00Z", formatter: losAngeles), "March 14, 2024")
        XCTAssertEqual(DetailDateFormatting.formattedDate("2024-03-15T02:00:00.500Z", formatter: losAngeles), "March 14, 2024")
    }

    // MARK: - Fallbacks

    func testUnparseableInputReturnsTrimmedRaw() {
        let losAngeles = formatter(style: .long, zone: "America/Los_Angeles")
        XCTAssertEqual(DetailDateFormatting.formattedDate(" TBA ", formatter: losAngeles), "TBA")
        XCTAssertEqual(DetailDateFormatting.formattedDate("2024-02-30", formatter: losAngeles), "2024-02-30")
        XCTAssertEqual(DetailDateFormatting.formattedDate("2024-13-01", formatter: losAngeles), "2024-13-01")
    }

    func testEmptyInputReturnsNil() {
        let losAngeles = formatter(style: .long, zone: "America/Los_Angeles")
        XCTAssertNil(DetailDateFormatting.formattedDate(nil, formatter: losAngeles))
        XCTAssertNil(DetailDateFormatting.formattedDate("", formatter: losAngeles))
        XCTAssertNil(DetailDateFormatting.formattedDate("  \n", formatter: losAngeles))
    }

    // MARK: - Helpers

    private func formatter(style: DateFormatter.Style, zone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = style
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: zone)!
        return formatter
    }
}
