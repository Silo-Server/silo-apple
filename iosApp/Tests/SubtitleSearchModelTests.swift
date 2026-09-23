//
//  SubtitleSearchModelTests.swift
//  SiloTests
//
//  Focused tests for the subtitle provider-search models: the download body
//  echoing the chosen result (the server re-fetches by provider +
//  subtitle_id — a silently-wrong echo would no-op the download), result
//  identity, and the score-tier thresholds shared with Android/web.
//

import XCTest
@testable import Silo

final class SubtitleSearchModelTests: XCTestCase {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
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
        let body = APIv2SubtitleDownloadBody(SubtitleDownloadBody(from: result, mediaFileId: 42))
        let encoded = try encoder.encode(body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["provider"] as? String, "opensubtitles")
        // The result's provider-scoped `id` must land on the `subtitle_id`
        // key — the pair the server uses to re-fetch the bytes.
        XCTAssertEqual(object["subtitle_id"] as? String, "os-123")
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["release_name"] as? String, "Some.Movie.2024.1080p.WEB")
        // The contract forbids extra keys; `format` would be a 422.
        XCTAssertNil(object["format"])
        XCTAssertEqual(object["score"] as? Double, 87.5)
        XCTAssertEqual(object["hearing_impaired"] as? Bool, true)
        XCTAssertEqual(object.count, 7)
    }

    func testUniqueKeyCombinesProviderAndId() {
        // Provider-local ids can collide across providers; row identity must
        // key on the (provider, id) pair.
        let a = SubtitleSearchResult(id: "123", provider: "opensubtitles")
        let b = SubtitleSearchResult(id: "123", provider: "subdl")
        XCTAssertEqual(a.uniqueKey, "opensubtitles:123")
        XCTAssertNotEqual(a.uniqueKey, b.uniqueKey)
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
