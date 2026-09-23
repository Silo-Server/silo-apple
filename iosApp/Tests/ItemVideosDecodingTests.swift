//
//  ItemVideosDecodingTests.swift
//  SiloTests
//
//  Decoding contract for the trailers payload: `videos[]` / `extras[]` on
//  item detail and the `POST /api/v2/catalog/items/{id}/trailers/refresh`
//  response. Item detail starts from the vendored server fixture for
//  `GET /api/v2/catalog/items/{id}` and runs through the same decode and
//  `ItemDetail(catalog:)` projection as `SiloAPI.itemDetail`, so a drift in
//  the wire model or the projection fails here rather than silently
//  emptying the rail on a device.
//

import XCTest
import Foundation
@testable import Silo

final class ItemVideosDecodingTests: XCTestCase {

    /// The server fixture with `members` replacing its top-level members.
    private func detail(setting members: [String: Any] = [:]) throws -> ItemDetail {
        let body = try APIv2FixtureTestSupport.mutatedBody(named: "get_catalog_item_ok", bundleClass: Self.self) {
            $0.merge(members) { $1 }
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: body)
        return try ItemDetail(catalog: wire)
    }

    // MARK: - videos[] / extras[]

    func testServerFixtureWithoutTrailerFieldsProjects() throws {
        // Both fields are optional on the server, and every episode payload
        // (plus every item with nothing scanned) omits them entirely.
        let detail = try detail()
        XCTAssertEqual(detail.contentId, "movie:heat-1995")
        XCTAssertEqual(detail.title, "Heat")
        XCTAssertEqual(detail.year, 1995)
        XCTAssertNil(detail.videos)
        XCTAssertNil(detail.extras)
    }

    func testFullVideosAndExtrasArraysProject() throws {
        let detail = try detail(setting: [
            "videos": [
                [
                    "kind": "trailer",
                    "site": "youtube",
                    "site_key": "tFMo3UJ4B4g",
                    "name": "Official Trailer",
                    "language": "en",
                    "is_official": true,
                ],
                ["kind": "featurette", "site": "youtube", "site_key": "abc123", "is_official": false],
            ],
            "extras": [
                [
                    "content_id": "extra:9",
                    "kind": "behind_the_scenes",
                    "title": "Making Of",
                    "duration_seconds": 412,
                    "file_id": 77,
                ],
                ["content_id": "extra:10", "kind": "deleted_scene"],
            ],
        ])

        XCTAssertEqual(detail.videos?.count, 2)
        let first = try XCTUnwrap(detail.videos?.first)
        XCTAssertEqual(first.kind, "trailer")
        XCTAssertEqual(first.site, "youtube")
        XCTAssertEqual(first.siteKey, "tFMo3UJ4B4g")
        XCTAssertEqual(first.name, "Official Trailer")
        XCTAssertEqual(first.language, "en")
        XCTAssertTrue(first.isOfficial)

        let second = try XCTUnwrap(detail.videos?.last)
        // Optional on the server: absent name/language must be nil, not "".
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

    func testUnknownKindProjectsVerbatimRatherThanFailing() throws {
        // The kind vocabulary is server-owned and can grow. A value this
        // client has never heard of must ride along as a string (the rail
        // labels it generically) instead of failing the whole detail read.
        let detail = try detail(setting: [
            "videos": [["kind": "opening_credits", "site": "youtube", "site_key": "k1", "is_official": true]],
            "extras": [["content_id": "extra:1", "kind": "interview"]],
        ])

        XCTAssertEqual(detail.videos?.first?.kind, "opening_credits")
        XCTAssertEqual(detail.extras?.first?.kind, "interview")
    }

    /// `is_official` is required in the v2 schema, so a video without it is
    /// a malformed read, not a silently unofficial trailer.
    func testVideoWithoutIsOfficialFailsTheRead() {
        XCTAssertThrowsError(try detail(setting: [
            "videos": [["kind": "trailer", "site": "youtube", "site_key": "k1"]],
        ]))
    }

    func testEmptyArraysProjectAsEmptyNotNil() throws {
        let detail = try detail(setting: ["videos": [Any](), "extras": [Any]()])

        XCTAssertEqual(detail.videos?.count, 0)
        XCTAssertEqual(detail.extras?.count, 0)
    }

    // MARK: - Refresh response

    private func decodeRefresh(_ json: String) throws -> TrailerRefreshResponse {
        try HTTPClient.makeJSONDecoder().decode(
            TrailerRefreshResponse.self,
            from: Data(json.utf8)
        )
    }

    func testQueuedRefreshFixtureDecodes() throws {
        let response = try APIv2FixtureTestSupport.decode(
            TrailerRefreshResponse.self,
            named: "refresh_catalog_item_trailers_ok",
            bundleClass: Self.self
        )
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
