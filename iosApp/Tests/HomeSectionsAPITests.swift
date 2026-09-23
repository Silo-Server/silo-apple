import Foundation
import XCTest
@testable import Silo

/// Home rows and dismissals through the `SiloAPI` facade on `/api/v2`.
final class HomeSectionsAPITests: XCTestCase {
    private let sectionsJSON = #"{"sections":[{"id":"cw","section_type":"continue_watching","title":"Continue Watching","items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}]}]}"#

    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "HomeSectionsAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "home-test")
        await tokens.setServerUrl("https://home.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    private func jsonObject(_ data: Data?) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(data))
        return try XCTUnwrap(object as? [String: String])
    }

    func testSectionsReadAsTheActingProfileAndStayOwnedByIt() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(path: "/api/v2/home/sections", 200, sectionsJSON)

        let read = try await api.homeSections()

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/home/sections")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(read.sections.map(\.id), ["cw"])
        XCTAssertEqual(read.sections.first?.items.map(\.contentId), ["movie:heat"])
        XCTAssertEqual(read.auth.profileId, "profile-one")
        let ownsRead = await api.isCurrentOwner(read.auth)
        XCTAssertTrue(ownsRead)

        // Rows fetched for one profile never apply to the next.
        await tokens.setProfileId("profile-two")
        let stillOwnsRead = await api.isCurrentOwner(read.auth)
        XCTAssertFalse(stillOwnsRead)
    }

    func testSectionsSurfaceProblemsInsteadOfAnEmptyHome() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/home/sections", 403,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/profile_verification_required","title":"Profile verification required","status":403,"detail":"Verify the profile."}"#)

        do {
            _ = try await api.homeSections()
            XCTFail("A problem response must not become an empty Home")
        } catch {
            XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error))
            XCTAssertEqual(StartupContentPrefetcher.prefetchFailureReason(error), "invalid_profile")
        }
    }

    func testMalformedSectionsBodyIsReportedAsADecodeFailure() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/home/sections", 200, #"{"sections":{}}"#)

        do {
            _ = try await api.homeSections()
            XCTFail("A malformed body must not become an empty Home")
        } catch {
            XCTAssertEqual(StartupContentPrefetcher.prefetchFailureReason(error), "decode_failed")
        }
    }

    func testContinueWatchingDismissalSendsOnlyTheProgressAnchor() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(204, "")

        try await api.dismissContinueWatchingItem(contentId: "movie:heat", progressUpdatedAt: "2026-09-20T18:04:05.123Z")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/home/dismissals/continue_watching/movie:heat")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(try jsonObject(request.body), ["progress_updated_at": "2026-09-20T18:04:05.123Z"])
    }

    func testNextUpDismissalSendsOnlyTheSeries() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(204, "")

        try await api.dismissNextUpItem(contentId: "episode:s1e2", seriesId: "series:severance")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/home/dismissals/next_up/episode:s1e2")
        XCTAssertEqual(try jsonObject(request.body), ["series_id": "series:severance"])
    }

    func testDismissalThrowsUnlessTheServerAnswersNoContent() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([
            .json(200, "{}"),
            .json(422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"Bad anchor."}"#),
        ])

        for _ in 0..<2 {
            do {
                try await api.dismissNextUpItem(contentId: "episode:s1e2", seriesId: "series:severance")
                XCTFail("Only 204 confirms a dismissal")
            } catch {}
        }
        XCTAssertEqual(stub.requests.count, 2)
    }
}
