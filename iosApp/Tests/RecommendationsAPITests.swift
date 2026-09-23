import Foundation
import XCTest
@testable import Silo

/// Similar cards and Discover rows through the `SiloAPI` facade on `/api/v2`.
final class RecommendationsAPITests: XCTestCase {
    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "RecommendationsAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "recs-test")
        await tokens.setServerUrl("https://recs.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    func testSimilarReturnsRankedCardsFromOneRequest() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(200, #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin","year":1998,"poster_thumbhash":"abc"},{"content_id":"movie:thief","type":"movie","title":"Thief"}]}"#)

        let cards = try await api.recommendationsSimilar(contentId: "movie:heat/1995", limit: 12)

        // Cards arrive complete, so no per-item detail reads follow.
        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(try XCTUnwrap(request.url).absoluteString.contains("/api/v2/recommendations/similar/movie:heat%2F1995"))
        XCTAssertEqual(request.query["limit"], "12")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(cards.map(\.contentId), ["movie:ronin", "movie:thief"])
        XCTAssertEqual(cards.first?.year, 1998)
        XCTAssertEqual(cards.first?.posterThumbhash, "abc")
    }

    func testSimilarRefusesCardsReadForAReplacedProfile() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(200, #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin"}]}"#)
        stub.hold()

        let read = Task { try await api.recommendationsSimilar(contentId: "movie:heat") }
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        stub.release()

        do {
            _ = try await read.value
            XCTFail("Cards fetched for one profile must not reach the next")
        } catch {}
    }

    func testSimilarRejectsLimitsTheServerWouldRefuseBeforeDispatch() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)

        for limit in [0, 51] {
            do {
                _ = try await api.recommendationsSimilar(contentId: "movie:heat", limit: limit)
                XCTFail("limit \(limit) is outside 1...50")
            } catch {}
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testDiscoverMapsRowTitlesIntoSections() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/recommendations/discover", 200,
            #"{"items":[{"type":"cluster","kind":"cluster","key":"0","title":"Because you enjoy Crime","items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}]},{"type":"popular","title":"Popular","items":[]}]}"#)

        let response = try await api.recommendationsDiscover()

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(response.sections.map(\.id), ["discover_0_cluster", "discover_1_popular"])
        XCTAssertEqual(response.sections.map(\.title), ["Because you enjoy Crime", "Popular"])
        XCTAssertEqual(response.sections.first?.items.map(\.contentId), ["movie:heat"])
    }

    func testDiscoverFailuresSurfaceInsteadOfAnEmptyTab() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([
            // The v1 body shape no longer decodes.
            .json(200, #"{"rows":[{"type":"popular","label":"Popular","items":[]}]}"#),
            .json(403, #"{"type":"https://siloserver.org/docs/api/v2/problems/profile_verification_required","title":"Profile verification required","status":403,"detail":"Verify the profile."}"#),
        ])

        do {
            _ = try await api.recommendationsDiscover()
            XCTFail("A malformed body must not become an empty Discover tab")
        } catch {
            XCTAssertEqual(StartupContentPrefetcher.prefetchFailureReason(error), "decode_failed")
        }
        do {
            _ = try await api.recommendationsDiscover()
            XCTFail("A problem must not become an empty Discover tab")
        } catch {
            XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error))
        }
    }
}
