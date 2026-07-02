//
//  SubtitleSearchModelTests.swift
//  SiloTests
//
//  Focused tests for the subtitle provider-search wire contract: the
//  snake_case decode of search responses (including tolerant defaults), the
//  download body echoing the chosen result (the server re-fetches by
//  provider + subtitle_id — a silently-wrong echo would no-op the download),
//  and the score-tier thresholds shared with Android/web.
//

import XCTest
@testable import Silo

final class SubtitleSearchModelTests: XCTestCase {
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    func testSearchResponseDecodesSnakeCasePayload() throws {
        let json = Data("""
        {
          "results": [
            {
              "id": "os-123",
              "provider": "opensubtitles",
              "language": "en",
              "release_name": "Some.Movie.2024.1080p.WEB",
              "format": "srt",
              "score": 87.5,
              "downloads": 4321,
              "hearing_impaired": true,
              "upload_date": "2024-11-02T10:00:00Z"
            }
          ],
          "warnings": ["subdl: rate limited"]
        }
        """.utf8)

        let response = try decoder.decode(SubtitleSearchResponse.self, from: json)
        XCTAssertEqual(response.results.count, 1)
        let result = try XCTUnwrap(response.results.first)
        XCTAssertEqual(result.id, "os-123")
        XCTAssertEqual(result.provider, "opensubtitles")
        XCTAssertEqual(result.releaseName, "Some.Movie.2024.1080p.WEB")
        XCTAssertEqual(result.score, 87.5)
        XCTAssertEqual(result.downloads, 4321)
        XCTAssertTrue(result.hearingImpaired)
        XCTAssertEqual(response.warnings, ["subdl: rate limited"])
    }

    func testSearchResponseToleratesMissingFields() throws {
        // Only `id` is required on a result; `warnings` may be omitted
        // entirely (`omitempty` server-side).
        let json = Data(#"{"results": [{"id": "ss-9"}]}"#.utf8)
        let response = try decoder.decode(SubtitleSearchResponse.self, from: json)
        let result = try XCTUnwrap(response.results.first)
        XCTAssertEqual(result.id, "ss-9")
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.downloads, 0)
        XCTAssertFalse(result.hearingImpaired)
        XCTAssertEqual(response.warnings, [])
    }

    func testDownloadBodyEchoesChosenResult() throws {
        let result = SubtitleSearchResult(
            id: "os-123",
            provider: "opensubtitles",
            language: "en",
            releaseName: "Some.Movie.2024.1080p.WEB",
            format: "srt",
            score: 87.5,
            downloads: 4321,
            hearingImpaired: true
        )
        let body = SubtitleDownloadBody(from: result, mediaFileId: 42)
        let encoded = try encoder.encode(body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["media_file_id"] as? Int, 42)
        XCTAssertEqual(object["provider"] as? String, "opensubtitles")
        // The result's provider-scoped `id` must land on the `subtitle_id`
        // key — the pair the server uses to re-fetch the bytes.
        XCTAssertEqual(object["subtitle_id"] as? String, "os-123")
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["release_name"] as? String, "Some.Movie.2024.1080p.WEB")
        XCTAssertEqual(object["format"] as? String, "srt")
        XCTAssertEqual(object["score"] as? Double, 87.5)
        XCTAssertEqual(object["hearing_impaired"] as? Bool, true)
    }

    func testDownloadResponseDecodesDownloadedSubtitle() throws {
        let json = Data("""
        {"subtitle": {"id": 7, "media_file_id": 42, "provider": "subdl",
                      "language": "en", "format": "srt",
                      "release_name": "Some.Movie", "score": 61.2,
                      "hearing_impaired": false}}
        """.utf8)
        let response = try decoder.decode(SubtitleDownloadResponse.self, from: json)
        XCTAssertEqual(response.subtitle.id, 7)
        XCTAssertEqual(response.subtitle.provider, "subdl")
    }

    func testScoreTierThresholds() {
        XCTAssertEqual(SubtitleSearchScoreTier(score: 100), .good)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 70), .good)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 69.9), .fair)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 40), .fair)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 39.9), .poor)
        XCTAssertEqual(SubtitleSearchScoreTier(score: 0), .poor)
    }
}
