import Foundation
import XCTest
@testable import Silo

final class APIv2SubtitleTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func testStoredFixtureProjectsExactPlayerHandlesAndRefusesDifferentFile() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self, from: fixture("subtitles_stored"))
        let subtitle = try XCTUnwrap(wire.subtitles.first)
        let player = try subtitle.playerValue(mediaFileID: 42)
        XCTAssertEqual(player.id, 7)
        XCTAssertEqual(player.mediaFileId, 42)
        XCTAssertEqual(player.streamURLExtension, ".vtt")
        XCTAssertThrowsError(try subtitle.playerValue(mediaFileID: 43))
    }

    func testStoredIDsMustBeStringsAndFitExactPlayerHandles() throws {
        let data = try fixture("subtitles_stored")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var row = try XCTUnwrap((object["subtitles"] as? [[String: Any]])?.first)
        for id in ["opaque-id", "07", "9223372036854775808"] {
            row["id"] = id
            object["subtitles"] = [row]
            let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try wire.subtitles[0].playerValue(mediaFileID: 42))
        }
        row["id"] = 7
        object["subtitles"] = [row]
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testSearchUsesStringFileIDAndPreservesPartialResultWarning() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(APIv2SubtitleSearchBody(SubtitleSearchBody(mediaFileId: 42, languages: ["en"])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["languages"] as? [String], ["en"])
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSearchResponse.self,
            from: fixture("subtitles_search_partial")).playerValue
        XCTAssertEqual(response.results.first?.id, "opaque-result")
        XCTAssertNil(response.results.first?.uploadDate)
        XCTAssertEqual(response.warnings, ["One or more subtitle providers could not complete the search."])
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSearchResponse.self,
            from: Data(#"{"results":null,"warnings":[]}"#.utf8)))
    }
}
