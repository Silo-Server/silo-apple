import Foundation
import XCTest
@testable import Silo

/// Calendar weeks, catalog facets and trailer refreshes through the `SiloAPI`
/// facade on `/api/v2`.
final class CatalogActionsAPITests: XCTestCase {
    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "CatalogActionsAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "catalog-actions-test")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    // MARK: - Calendar

    func testCalendarReadsTheWeekFromV2() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(200, #"{"events":[{"date":"2026-09-21","items":[{"content_id":"episode:severance-2-1","type":"episode","title":"Severance","series_id":"series:severance","season_number":2,"episode_number":1,"air_date":"2026-09-21","local_air_date":"2026-09-21","watched":false,"badges":["season_premiere"]}]}]}"#)

        let response = try await api.calendarEvents(
            start: "2026-09-21", end: "2026-09-27", filter: "following", timezone: "America/New_York"
        )

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/calendar")
        XCTAssertEqual(request.query, [
            "start": "2026-09-21", "end": "2026-09-27", "filter": "following", "timezone": "America/New_York",
        ])
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        let event = try XCTUnwrap(response.events.first?.items.first)
        XCTAssertEqual(response.events.map(\.date), ["2026-09-21"])
        XCTAssertEqual(event.contentId, "episode:severance-2-1")
        XCTAssertEqual(event.episodeSubtitle, "S2 · E1")
        XCTAssertEqual(event.displayBadges, [.seasonPremiere])
    }

    func testCalendarRefusesAWeekReadForAReplacedProfile() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(200, #"{"events":[]}"#)
        stub.hold()

        let read = Task {
            try await api.calendarEvents(start: "2026-09-21", end: "2026-09-27", filter: "following", timezone: "UTC")
        }
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        stub.release()

        do {
            _ = try await read.value
            XCTFail("One profile's calendar must not reach the next")
        } catch HTTPError.authorityChanged {
            // The owner fence around the request rejects the response.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Catalog filters

    func testFiltersAskForTechnicalFacetsByDefault() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        let body = String(decoding: try APIv2FixtureTestSupport.data(named: "get_catalog_filters_ok", bundleClass: Self.self),
                          as: UTF8.self)
        stub.reply(200, body)

        let facets = CatalogFacets(try await api.catalogFilters(libraryId: 3))

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.path, "/api/v2/catalog/filters")
        // v2 inverts the v1 flag: technical facets come back unless skipped.
        XCTAssertEqual(request.query, ["library_id": "3"])
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(facets.genres, ["Crime"])
        XCTAssertEqual(facets.authors, ["Frank Herbert"])
        XCTAssertEqual(facets.resolutions, ["2160p"])
        XCTAssertEqual(facets.subtitleLanguages, ["en"])
    }

    func testFiltersWithoutTechnicalFacetsSkipThemOnTheWire() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(200, #"{"genres":["Drama"],"studios":[],"networks":[],"countries":[],"content_ratings":[],"original_languages":[],"authors":[],"narrators":[],"series":[]}"#)

        let facets = CatalogFacets(try await api.catalogFilters(libraryId: nil, includeTechnical: false))

        XCTAssertEqual(try XCTUnwrap(stub.requests.first).query, ["skip_technical": "true"])
        XCTAssertEqual(facets.genres, ["Drama"])
        XCTAssertEqual(facets.resolutions, [])
    }

    // MARK: - Trailer refresh

    func testTrailerRefreshPostsOnceAndReadsEachOutcome() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([
            .json(202, #"{"status":"queued"}"#),
            .json(200, #"{"status":"cooldown","next_allowed_at":"2026-09-30T12:00:00Z"}"#),
            .json(200, #"{"status":"disabled"}"#),
        ])

        let queued = try await api.requestTrailersRefresh(contentId: "movie:heat/1995")
        let cooldown = try await api.requestTrailersRefresh(contentId: "movie:heat/1995")
        let disabled = try await api.requestTrailersRefresh(contentId: "movie:heat/1995")

        XCTAssertEqual(queued.status, "queued")
        XCTAssertEqual(cooldown.status, "cooldown")
        XCTAssertNotNil(cooldown.nextAllowedAt)
        XCTAssertEqual(disabled.status, "disabled")
        XCTAssertEqual(stub.methods, ["POST", "POST", "POST"])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertTrue(try XCTUnwrap(request.url).absoluteString
            .hasSuffix("/api/v2/catalog/items/movie:heat%2F1995/trailers/refresh"))
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
    }

    func testTrailerRefreshIsNotReplayedAfterALostAnswer() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.fail(.networkConnectionLost)

        do {
            _ = try await api.requestTrailersRefresh(contentId: "movie:heat")
            XCTFail("A lost answer must surface, not become an outcome")
        } catch {}
        // non_retryable: the server may already have spent the cooldown slot.
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testTrailerRefreshSurfacesARateLimitProblem() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(429, #"{"type":"https://siloserver.org/docs/api/v2/problems/rate_limited","title":"Too Many Requests","status":429,"detail":"Slow down."}"#)

        do {
            _ = try await api.requestTrailersRefresh(contentId: "movie:heat")
            XCTFail("A 429 is not a refresh outcome")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 429)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
