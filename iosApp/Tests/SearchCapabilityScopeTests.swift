import Foundation
import XCTest
@testable import Silo

/// Search "All" (audiobooks hidden) asks the server whether it supports the
/// `video_with_episodes` scope before the first title search. Only an answer
/// without the flag narrows the search to `video`; a read that times out or
/// is refused fails the search with a retryable error instead of reporting
/// "No results" for an episode (silo-apple#337). The screen shows its loading
/// state while it waits.
@MainActor
final class SearchCapabilityScopeTests: XCTestCase {
    private static let capabilitiesPath = "/api/v2/catalog/search/capabilities"
    private static let catalogPath = "/api/v2/catalog"
    private static let peoplePath = "/api/v2/catalog/people"

    private let episodePage = #"{"items":[{"content_id":"ep-1","type":"episode","title":"Grilled","series_id":"s-1","series_title":"Breaking Bad","season_number":2,"episode_number":2}],"page":{"has_more":false},"total":1,"total_exact":true}"#
    private let emptyPage = #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#
    private let unauthorized = #"{"type":"https://siloserver.org/docs/api/v2/problems/session_expired","title":"Session expired","status":401,"detail":"The session is no longer valid; sign in again.","instance":"urn:test"}"#
    private let notFound = #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"Not found","instance":"urn:test"}"#

    private var stub = APIv2TestStub()

    override func setUp() async throws {
        try await super.setUp()
        stub = APIv2TestStub()
        stub.reply(path: Self.peoplePath, 200, #"{"items":[]}"#)
    }

    private func capabilities(episodes: Bool?) -> String {
        let flag = episodes.map { #","video_with_episodes_scope":\#($0)"# } ?? ""
        return #"{"revision":"r","state":"available","allowed":true,"people_media_scope":true\#(flag)}"#
    }

    private func viewModel(tokens saved: Bool = false) async throws -> SearchViewModel {
        let name = "SearchCapabilityScopeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "search-scope-test")
        await tokens.setServerUrl("https://search.example")
        await tokens.setProfileId("profile-one")
        if saved { await tokens.saveTokens(accessToken: "access", refreshToken: "refresh") }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let model = SearchViewModel(api: SiloAPI(http: http, tokenStore: tokens),
                                    includesPeople: true, includesEpisodes: true)
        model.audiobooksEnabled = false
        model.query = "Grilled"
        return model
    }

    private var catalogTypes: [String?] {
        stub.requests.filter { $0.path == Self.catalogPath }.map { $0.query["type"] }
    }

    private var capabilityReads: Int {
        stub.requests.filter { $0.path == Self.capabilitiesPath }.count
    }

    // MARK: Server answered

    func testAnswerWithTheFlagSearchesEpisodes() async throws {
        stub.reply(path: Self.capabilitiesPath, 200, capabilities(episodes: true))
        stub.reply(path: Self.catalogPath, 200, episodePage)
        let model = try await viewModel()

        await model.performSearch()

        XCTAssertEqual(catalogTypes, ["video_with_episodes"])
        XCTAssertEqual(model.contentState, .results)
        XCTAssertEqual(model.results.map(\.contentId), ["ep-1"])
    }

    func testAnswerWithoutTheFlagSearchesVideo() async throws {
        for answer in [capabilities(episodes: nil), capabilities(episodes: false)] {
            stub.reset()
            stub.reply(path: Self.capabilitiesPath, 200, answer)
            stub.reply(path: Self.catalogPath, 200, emptyPage)
            let model = try await viewModel()

            await model.performSearch()

            XCTAssertEqual(catalogTypes, ["video"], answer)
            XCTAssertNil(model.error, answer)
        }
    }

    func testServerWithoutTheCapabilitiesReadSearchesVideo() async throws {
        let answers: [APIv2TestStub.Reply] = [
            .json(404, notFound),
            .text(404, APIv2Probe.legacyNotFoundBody, contentType: "text/plain; charset=utf-8"),
        ]
        for (index, answer) in answers.enumerated() {
            stub.reset()
            stub.sequence(path: Self.capabilitiesPath, [answer])
            stub.reply(path: Self.catalogPath, 200, emptyPage)
            let model = try await viewModel()

            await model.performSearch()

            XCTAssertEqual(catalogTypes, ["video"], "answer \(index)")
            XCTAssertNil(model.error, "answer \(index)")
        }
    }

    // MARK: No answer

    func testUnreachableServerFailsTheSearchAndTheNextSearchAsksAgain() async throws {
        stub.sequence(path: Self.capabilitiesPath, [.failure(URLError(.timedOut))])
        stub.reply(path: Self.catalogPath, 200, episodePage)
        let model = try await viewModel()

        await model.performSearch()

        XCTAssertEqual(catalogTypes, [], "no title search is sent with a guessed scope")
        guard case .failed(let error) = model.contentState else {
            return XCTFail("expected the error state, got \(model.contentState)")
        }
        XCTAssertTrue(error.isTransient, "the error offers Try Again")
        XCTAssertTrue(model.results.isEmpty)

        // Try Again: the failure was not kept, so the server is asked again.
        stub.reply(path: Self.capabilitiesPath, 200, capabilities(episodes: true))
        await model.performSearch()

        XCTAssertEqual(capabilityReads, 2)
        XCTAssertEqual(catalogTypes, ["video_with_episodes"])
        XCTAssertEqual(model.contentState, .results)
    }

    func testRefusedCredentialsFailTheSearch() async throws {
        stub.sequence(path: Self.capabilitiesPath, [.json(401, unauthorized)])
        stub.reply(path: Self.catalogPath, 200, episodePage)
        let model = try await viewModel()

        await model.performSearch()

        XCTAssertEqual(catalogTypes, [])
        guard case .failed(let error) = model.contentState else {
            return XCTFail("expected the error state, got \(model.contentState)")
        }
        XCTAssertEqual(error.statusCode, 401)

        stub.reply(path: Self.capabilitiesPath, 200, capabilities(episodes: true))
        await model.performSearch()
        XCTAssertEqual(capabilityReads, 2, "a refused read is not kept")
        XCTAssertEqual(catalogTypes, ["video_with_episodes"])
    }

    func testExpiredAccessTokenIsRefreshedForTheCapabilitiesRead() async throws {
        stub.sequence(path: Self.capabilitiesPath, [.json(401, unauthorized), .json(200, capabilities(episodes: true))])
        stub.reply(path: HTTPClient.refreshPath, 200,
                   #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        stub.reply(path: Self.catalogPath, 200, episodePage)
        let model = try await viewModel(tokens: true)

        await model.performSearch()

        let firstPaths = Array(stub.requestedPaths.prefix(3))
        XCTAssertEqual(firstPaths, [Self.capabilitiesPath, HTTPClient.refreshPath, Self.capabilitiesPath])
        XCTAssertEqual(catalogTypes, ["video_with_episodes"])
        XCTAssertEqual(model.contentState, .results)
    }

    // MARK: Loading

    func testSearchShowsLoadingWhileTheCapabilitiesReadIsPending() async throws {
        stub.reply(path: Self.capabilitiesPath, 200, capabilities(episodes: true))
        stub.reply(path: Self.catalogPath, 200, episodePage)
        stub.hold(path: Self.capabilitiesPath)
        let model = try await viewModel()
        XCTAssertEqual(model.contentState, .prompt)

        let search = Task { await model.performSearch() }
        await stub.waitUntilHeld()

        XCTAssertEqual(model.contentState, .loading)
        XCTAssertEqual(catalogTypes, [])

        stub.release()
        await search.value
        XCTAssertEqual(model.contentState, .results)
    }

    func testSearchShowsLoadingWhileTheTitlePageIsPending() async throws {
        stub.reply(path: Self.capabilitiesPath, 200, capabilities(episodes: true))
        stub.reply(path: Self.catalogPath, 200, emptyPage)
        stub.hold(path: Self.catalogPath)
        let model = try await viewModel()

        let search = Task { await model.performSearch() }
        await stub.waitUntilHeld()
        XCTAssertEqual(model.contentState, .loading)

        stub.release()
        await search.value
        // People are looked up beside the titles; wait for them before
        // "No results" can show.
        try await waitUntil("the people lookup") { model.contentState != .loading }
        XCTAssertEqual(model.contentState, .noResults)
    }
}
