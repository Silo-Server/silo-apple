import XCTest
@testable import Silo

final class ResolvedSectionTitleTests: XCTestCase {
    func testRawSectionTypeTitleBecomesWords() throws {
        let json = #"{"id":"s1","section_type":"trending_on_server","title":"trending_on_server","featured":true}"#
        let section = try HTTPClient.makeJSONDecoder().decode(ResolvedSection.self, from: Data(json.utf8))
        XCTAssertEqual(section.title, "Trending on server")
    }

    func testDirectInitializerNormalizesRawSectionTypeTitle() {
        let section = ResolvedSection(
            id: "s1", sectionType: "trending_on_server", title: "trending_on_server",
            featured: true, itemLimit: nil, totalCount: nil, isCustom: nil, customized: nil, items: []
        )
        XCTAssertEqual(section.title, "Trending on server")
    }

    func testBlankTitleFallsBackToSectionType() {
        XCTAssertEqual(ResolvedSection.displayTitle(" \n", sectionType: "new_to_library"), "New to library")
    }

    func testRawKeyWithTrailingNewlineBecomesWords() {
        XCTAssertEqual(ResolvedSection.displayTitle("trending_on_server\n", sectionType: "trending_on_server"), "Trending on server")
    }

    func testRealTitleIsKept() {
        XCTAssertEqual(ResolvedSection.displayTitle("Trending This Week", sectionType: "trending_on_server"), "Trending This Week")
    }
}
