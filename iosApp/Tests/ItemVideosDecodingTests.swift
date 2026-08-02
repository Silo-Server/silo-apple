//
//  ItemVideosDecodingTests.swift
//  SiloTests
//
//  Decoding contract for the trailers payload: `videos[]` / `extras[]` on
//  item detail and the `POST /items/{id}/trailers/refresh` response. Every
//  case runs canned server-shaped JSON through the REAL shared decoder
//  (`HTTPClient.makeJSONDecoder`), so a drift in either the key strategy or
//  the date strategy fails here rather than silently emptying the rail on a
//  device.
//

import XCTest
import Foundation
@testable import Silo

final class ItemVideosDecodingTests: XCTestCase {

    private func decodeDetail(_ json: String) throws -> ItemDetail {
        try HTTPClient.makeJSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
    }

    // MARK: - videos[] / extras[]

    func testFullVideosAndExtrasArraysDecode() throws {
        let detail = try decodeDetail("""
        {
          "content_id": "movie:1",
          "type": "movie",
          "title": "Arrival",
          "videos": [
            {
              "kind": "trailer",
              "site": "youtube",
              "site_key": "tFMo3UJ4B4g",
              "name": "Official Trailer",
              "language": "en",
              "is_official": true
            },
            {
              "kind": "featurette",
              "site": "youtube",
              "site_key": "abc123",
              "is_official": false
            }
          ],
          "extras": [
            {
              "content_id": "extra:9",
              "kind": "behind_the_scenes",
              "title": "Making Of",
              "duration_seconds": 412,
              "file_id": 77
            },
            {
              "content_id": "extra:10",
              "kind": "deleted_scene"
            }
          ]
        }
        """)

        XCTAssertEqual(detail.videos?.count, 2)
        let first = try XCTUnwrap(detail.videos?.first)
        XCTAssertEqual(first.kind, "trailer")
        XCTAssertEqual(first.site, "youtube")
        // The whole point of the snake_case strategy: `site_key` lands on
        // `siteKey` with no CodingKeys boilerplate.
        XCTAssertEqual(first.siteKey, "tFMo3UJ4B4g")
        XCTAssertEqual(first.name, "Official Trailer")
        XCTAssertEqual(first.language, "en")
        XCTAssertTrue(first.isOfficial)

        let second = try XCTUnwrap(detail.videos?.last)
        // `omitempty` on the server: absent name/language must be nil, not "".
        XCTAssertNil(second.name)
        XCTAssertNil(second.language)
        XCTAssertFalse(second.isOfficial)

        XCTAssertEqual(detail.extras?.count, 2)
        let extra = try XCTUnwrap(detail.extras?.first)
        XCTAssertEqual(extra.contentId, "extra:9")
        XCTAssertEqual(extra.kind, "behind_the_scenes")
        XCTAssertEqual(extra.title, "Making Of")
        XCTAssertEqual(extra.durationSeconds, 412)
        XCTAssertEqual(extra.fileId, 77)
        XCTAssertEqual(extra.id, "extra:9")

        let bare = try XCTUnwrap(detail.extras?.last)
        XCTAssertNil(bare.title)
        XCTAssertNil(bare.durationSeconds)
        XCTAssertNil(bare.fileId)
    }

    func testUnknownKindDecodesVerbatimRatherThanFailing() throws {
        // The kind vocabulary is server-owned and can grow. A value this
        // client has never heard of must ride along as a string (the rail
        // labels it generically) instead of failing the whole detail decode.
        let detail = try decodeDetail("""
        {
          "content_id": "movie:1",
          "type": "movie",
          "title": "Arrival",
          "videos": [
            {"kind": "opening_credits", "site": "youtube", "site_key": "k1", "is_official": true}
          ],
          "extras": [
            {"content_id": "extra:1", "kind": "interview"}
          ]
        }
        """)

        XCTAssertEqual(detail.videos?.first?.kind, "opening_credits")
        XCTAssertEqual(detail.extras?.first?.kind, "interview")
    }

    func testMissingIsOfficialDefaultsToFalse() throws {
        let detail = try decodeDetail("""
        {
          "content_id": "movie:1",
          "type": "movie",
          "title": "Arrival",
          "videos": [{"kind": "trailer", "site": "youtube", "site_key": "k1"}]
        }
        """)

        XCTAssertEqual(detail.videos?.first?.isOfficial, false)
    }

    func testAbsentArraysDecodeAsNil() throws {
        // Both fields are `omitempty` server-side, and every episode payload
        // (plus every item with nothing scanned) omits them entirely.
        let detail = try decodeDetail("""
        {
          "content_id": "episode:1",
          "type": "episode",
          "title": "Pilot"
        }
        """)

        XCTAssertNil(detail.videos)
        XCTAssertNil(detail.extras)
    }

    func testEmptyArraysDecodeAsEmptyNotNil() throws {
        let detail = try decodeDetail("""
        {
          "content_id": "movie:1",
          "type": "movie",
          "title": "Arrival",
          "videos": [],
          "extras": []
        }
        """)

        XCTAssertEqual(detail.videos?.count, 0)
        XCTAssertEqual(detail.extras?.count, 0)
    }

    func testDetailWithoutTrailerFieldsStillDecodesEverythingElse() throws {
        // Guards the memberwise-initializer / decoding change from breaking
        // the fields the rest of the detail page depends on.
        let detail = try decodeDetail("""
        {
          "content_id": "movie:1",
          "type": "movie",
          "title": "Arrival",
          "year": 2016,
          "overview": "Linguist meets heptapods.",
          "poster_url": "/img/p.jpg"
        }
        """)

        XCTAssertEqual(detail.title, "Arrival")
        XCTAssertEqual(detail.year, 2016)
        XCTAssertEqual(detail.posterUrl, "/img/p.jpg")
    }

    // MARK: - Refresh response

    private func decodeRefresh(_ json: String) throws -> TrailerRefreshResponse {
        try HTTPClient.makeJSONDecoder().decode(
            TrailerRefreshResponse.self,
            from: Data(json.utf8)
        )
    }

    func testQueuedRefreshResponseDecodes() throws {
        let response = try decodeRefresh(#"{"status": "queued"}"#)
        XCTAssertEqual(response.status, "queued")
        XCTAssertNil(response.nextAllowedAt)
    }

    func testCooldownResponseDecodesWholeSecondTimestamp() throws {
        let response = try decodeRefresh(#"""
        {"status": "cooldown", "next_allowed_at": "2026-08-09T12:30:00Z"}
        """#)

        XCTAssertEqual(response.status, "cooldown")
        let next = try XCTUnwrap(response.nextAllowedAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(next, formatter.date(from: "2026-08-09T12:30:00Z"))
    }

    func testCooldownResponseDecodesFractionalSecondTimestamp() throws {
        // Go's RFC3339Nano drops trailing zeros, so both spellings reach the
        // client; the shared decoder's custom strategy handles each.
        let response = try decodeRefresh(#"""
        {"status": "cooldown", "next_allowed_at": "2026-08-09T12:30:00.481523Z"}
        """#)

        XCTAssertEqual(response.status, "cooldown")
        XCTAssertNotNil(response.nextAllowedAt)
    }

    func testDisabledResponseDecodes() throws {
        let response = try decodeRefresh(#"{"status": "disabled"}"#)
        XCTAssertEqual(response.status, "disabled")
        XCTAssertNil(response.nextAllowedAt)
    }
}
