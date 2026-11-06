import XCTest
@testable import Silo

/// A movie is listed on its first home release, and the server names that
/// release with a `digital` or `physical` badge (silo-apple#945).
final class CalendarBadgeTests: XCTestCase {
    func testMovieHomeReleaseBadgesShowTheirLabels() throws {
        let json = """
        {"events": [
          {"date": "2026-10-30", "items": [
            {"content_id": "m1", "type": "movie", "title": "Northern Lights",
             "local_air_date": "2026-10-30", "watched": false, "badges": ["digital"]}
          ]},
          {"date": "2026-10-31", "items": [
            {"content_id": "m2", "type": "movie", "title": "Harbor Town",
             "local_air_date": "2026-10-31", "watched": false, "badges": ["physical"]}
          ]}
        ]}
        """
        let response = try HTTPClient.makeJSONDecoder().decode(CalendarResponse.self, from: Data(json.utf8))
        let labels = response.events.flatMap(\.items).map { $0.displayBadges.map(\.label) }
        XCTAssertEqual(labels, [["DIGITAL"], ["PHYSICAL"]])
    }
}
