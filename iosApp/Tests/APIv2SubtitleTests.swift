import Foundation
import XCTest
@testable import Silo

/// Subtitle wire models: opaque string identity on the wire, exact integer
/// projection into the player's handles, and refusal of anything that does
/// not fit.
final class APIv2SubtitleTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try APIv2FixtureTestSupport.data(named: name, bundleClass: Self.self)
    }

    private func assertInvalidSubtitleResponse<T>(_ expression: @autoclosure () throws -> T,
                                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case APIv2Error.invalidSubtitleResponse = error else {
                return XCTFail("\(message): unexpected \(error)", file: file, line: line)
            }
        }
    }

    private func assertDecodingFails<T: Decodable>(_ type: T.Type, from data: Data, _ message: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(type, from: data), message, file: file, line: line) { error in
            XCTAssertTrue(error is DecodingError, "\(message): unexpected \(error)", file: file, line: line)
        }
    }

    func testAIJobFixturePreservesOpaqueIdentityAndNullableResult() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id"))
        XCTAssertEqual(wire.job.id, "9007199254740993")
        // The synthetic server fixture intentionally has an empty kind.
        // Preserve it on the wire, but refuse unsupported player semantics.
        assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "empty kind")
        let playable = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id").replacingEmptyJobKind())
        let job = try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740993")
        XCTAssertEqual(job.id, "9007199254740993")
        XCTAssertEqual(job.mediaFileId, 42)
        XCTAssertNil(job.resultSubtitleId)
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.errorMessage, "Subtitle processing failed.")
        XCTAssertEqual(job.updatedAt, "2026-01-02T03:04:05.678Z")
        assertInvalidSubtitleResponse(try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740992"), "job id mismatch")
    }

    func testAIJobResultUsesExactIntegerProjection() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitle_ai_job_opaque_id")) as? [String: Any])
        var row = try XCTUnwrap(object["job"] as? [String: Any])
        row["kind"] = "translate"
        for raw in ["9007199254740993", "9223372036854775808", "07", "opaque"] {
            row["result_subtitle_id"] = raw
            object["job"] = row
            let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
                from: JSONSerialization.data(withJSONObject: object))
            if raw == "9007199254740993" {
                XCTAssertEqual(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id).resultSubtitleId, 9007199254740993)
            } else {
                assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "result id \(raw)")
            }
        }
        row["media_file_id"] = 42
        object["job"] = row
        assertDecodingFails(APIv2SubtitleJobEnvelope.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric media_file_id is not the wire contract")
    }

    func testAIQuotaFixtureRetainsBudgetFields() throws {
        let quota = try HTTPClient.makeJSONDecoder().decode(SubtitleAIQuota.self, from: fixture("subtitle_ai_quota"))
        XCTAssertTrue(quota.limited)
        XCTAssertEqual(quota.limit, 5)
        XCTAssertEqual(quota.used, 2)
        XCTAssertEqual(quota.remaining, 3)
        XCTAssertEqual(quota.period, "daily")
    }

    func testStoredFixtureProjectsExactPlayerHandlesAndRefusesDifferentFile() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self, from: fixture("subtitles_stored"))
        let subtitle = try XCTUnwrap(wire.subtitles.first)
        let player = try subtitle.playerValue(mediaFileID: 42)
        XCTAssertEqual(player.id, 7)
        XCTAssertEqual(player.mediaFileId, 42)
        XCTAssertEqual(player.streamURLExtension, ".vtt")
        assertInvalidSubtitleResponse(try subtitle.playerValue(mediaFileID: 43), "another file's subtitle")
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
            assertInvalidSubtitleResponse(try wire.subtitles[0].playerValue(mediaFileID: 42), "id \(id)")
        }
        row["id"] = 7
        object["subtitles"] = [row]
        assertDecodingFails(APIv2StoredSubtitles.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric id is not the wire contract")
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
        assertDecodingFails(APIv2SubtitleSearchResponse.self, from: Data(#"{"results":null,"warnings":[]}"#.utf8),
                            "results must be an array")
    }
}

private extension Data {
    func replacingEmptyJobKind() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""kind": """#, with: #""kind": "translate""#).utf8)
    }
}
