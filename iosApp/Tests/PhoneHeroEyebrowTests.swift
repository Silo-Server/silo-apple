#if os(iOS)
import XCTest
@testable import Silo

final class PhoneHeroEyebrowTests: XCTestCase {
    func testEndedSeriesReadsShowStatusWhenStatusIsEmpty() throws {
        let detail = try series(status: "", showStatus: "ended")
        XCTAssertEqual(PhoneHeroMetadata.eyebrow(from: detail), "Complete Series")
    }

    func testContinuingSeriesReadsShowStatus() throws {
        let detail = try series(status: nil, showStatus: "Returning Series")
        XCTAssertEqual(PhoneHeroMetadata.eyebrow(from: detail), "Continuing Series")
    }

    func testLegacyStatusStillWorksWithoutShowStatus() throws {
        let detail = try series(status: "ended", showStatus: nil)
        XCTAssertEqual(PhoneHeroMetadata.eyebrow(from: detail), "Complete Series")
    }

    func testUnknownStatusShowsNoEyebrow() throws {
        XCTAssertNil(PhoneHeroMetadata.eyebrow(from: try series(status: "", showStatus: "")))
    }

    private func series(status: String?, showStatus: String?) throws -> ItemDetail {
        var fields = [#""content_id":"series-tvdb-81189""#, #""type":"series""#, #""title":"Breaking Bad""#]
        if let status { fields.append(#""status":"\#(status)""#) }
        if let showStatus { fields.append(#""show_status":"\#(showStatus)""#) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }
}
#endif
