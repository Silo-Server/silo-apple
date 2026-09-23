import Foundation
import XCTest
@testable import Silo

/// Media requests on `/api/v2/requests`: wire shapes, exact statuses,
/// profile scoping, bounded cursor paging, problem copy, and the
/// uncertain-outcome hold for the two `non_retryable` mutations.
final class RequestsV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    private static let record = #"{"id":"request-one","provider":"tmdb","media_type":"movie","tmdb_id":949,"title":"Heat","status":"pending","outcome":"active","is_anime":false,"targets":[],"created_at":"2026-01-02T03:04:05.000Z","updated_at":"2026-01-02T03:04:05.000Z"}"#
    private static let result = #"{"media_type":"movie","tmdb_id":949,"title":"Heat","availability":"missing","request":{"requestable":true}}"#
    private static let detail = #"{"media_type":"movie","tmdb_id":949,"title":"Heat","genres":[],"production_companies":[],"networks":[],"cast":[],"creators":[],"recommendations":[],"availability":"missing","request":{"requestable":true}}"#

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func tokens(profile: String? = "profile-one") async throws -> TokenStore {
        let name = "RequestsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://requests.example")
        if let profile { await tokens.setProfileId(profile) }
        return tokens
    }

    private func client(profile: String? = "profile-one") async throws -> (APIv2Client, TokenStore) {
        let tokens = try await tokens(profile: profile)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private static func problem(_ type: String, _ status: Int, _ detail: String) -> String {
        #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"T","status":\#(status),"detail":"\#(detail)","instance":"urn:silo:request:1"}"#
    }

    private func heatInput(_ type: RequestMediaType = .movie) -> CreateRequestInput {
        CreateRequestInput(mediaType: type, tmdbId: 949, tvdbId: nil, imdbId: "tt0113277", title: "Heat",
                           year: 1995, overview: nil, posterPath: "/heat.jpg", backdropPath: nil)
    }

    // MARK: Reads

    func testDiscoverDecodesTheItemsEnvelopeWithoutAPage() async throws {
        let (api, _) = try await client()
        stub.reply(200, #"{"items":[{"key":"trending_movies","title":"Trending","page":1,"total_pages":9,"total_results":180,"next_page":3,"results":[\#(Self.result)]}]}"#)
        let sections = try await api.requestDiscoverSections()
        XCTAssertEqual(sections.map(\.key), ["trending_movies"])
        XCTAssertEqual(sections.first?.nextPage, 3)
        XCTAssertEqual(sections.first?.results.first?.tmdbId, 949)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/requests/discover")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
    }

    func testStatusCountsOnlyWhenAllowedAndAvailable() async throws {
        let (api, _) = try await client()
        let cases: [(String, Bool)] = [
            (#"{"requests_enabled":true,"rating_restrictions_enforced":false,"revision":"r","state":"available","allowed":true}"#, true),
            // A blocked account: the domain is on, this viewer may not use it.
            (#"{"requests_enabled":true,"rating_restrictions_enforced":false,"revision":"r","state":"available","allowed":false}"#, false),
            (#"{"requests_enabled":false,"rating_restrictions_enforced":false,"revision":"r","state":"not_configured","allowed":false}"#, false),
            // Allowed, but the domain is not available.
            (#"{"requests_enabled":true,"rating_restrictions_enforced":false,"revision":"r","state":"disabled","allowed":true}"#, false),
            // The contract requires `allowed`; a response without it fails
            // closed even when everything else says available.
            (#"{"requests_enabled":true,"rating_restrictions_enforced":false,"revision":"r","state":"available"}"#, false),
        ]
        for (body, expected) in cases {
            stub.reply(200, body)
            let status = try await api.requestsStatus()
            XCTAssertEqual(status.isAvailable, expected, body)
        }
        XCTAssertEqual(Set(stub.requestedPaths), ["/api/v2/requests/status"])
    }

    func testSearchSendsTheContractQueryAndRefusesBlankText() async throws {
        let (api, _) = try await client()
        stub.reply(200, #"{"page":2,"total_pages":3,"total_results":41,"results":[\#(Self.result)]}"#)
        let page = try await api.searchRequestMedia(query: "heat", mediaType: .movie, page: 2)
        XCTAssertEqual(page.results.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.path, "/api/v2/requests/search")
        XCTAssertEqual(request.query, ["q": "heat", "media_type": "movie", "page": "2"])

        do {
            _ = try await api.searchRequestMedia(query: "  ", mediaType: .all, page: 1)
            XCTFail("A blank search must not be sent")
        } catch APIv2RequestsError.emptySearchQuery { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testDetailAndCreateRefuseSearchOnlyMediaTypesBeforeDispatch() async throws {
        let (api, _) = try await client()
        for type in [RequestMediaType.all, .unknown] {
            do {
                _ = try await api.requestMediaDetail(mediaType: type, tmdbId: 949)
                XCTFail("detail: \(type) is not a path value")
            } catch APIv2RequestsError.unsupportedMediaType { }
            do {
                _ = try await api.createRequest(heatInput(type))
                XCTFail("create: \(type) is not a body value")
            } catch APIv2RequestsError.unsupportedMediaType { }
        }
        XCTAssertTrue(stub.requests.isEmpty)

        stub.reply(200, Self.detail)
        let detail = try await api.requestMediaDetail(mediaType: .series, tmdbId: 1399)
        XCTAssertEqual(detail.tmdbId, 949)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/requests/detail/series/1399"])
    }

    func testEveryOperationNeedsASelectedProfile() async throws {
        let (api, _) = try await client(profile: nil)
        do {
            _ = try await api.requestsStatus()
            XCTFail("A profile-scoped read must not run without a profile")
        } catch HTTPError.requestIdentityChanged { }
        do {
            _ = try await api.myRequests()
            XCTFail("A profile-scoped list must not run without a profile")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: My requests paging

    func testMyRequestsFollowsCursorsAndFailsInsteadOfTruncating() async throws {
        let (api, _) = try await client()
        stub.sequence([
            .json(200, #"{"items":[\#(Self.record)],"page":{"has_more":true,"next_cursor":"c1"}}"#),
            .json(200, #"{"items":[\#(Self.record)],"page":{"has_more":false}}"#),
        ])
        let records = try await api.myRequests()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(stub.requests.map(\.query), [["limit": "50"], ["limit": "50", "cursor": "c1"]])

        for body in [#"{"items":[],"page":{"has_more":true}}"#,
                     #"{"items":[],"page":{"has_more":true,"next_cursor":"same"}}"#] {
            stub.reset()
            stub.reply(200, body)
            do {
                _ = try await api.myRequests()
                XCTFail("A broken continuation must fail the load: \(body)")
            } catch APIv2Error.incompleteRequestList { }
        }
    }

    // MARK: Mutations

    func testCreateSendsTheContractBodyAndRequires201() async throws {
        let (api, _) = try await client()
        stub.reply(201, Self.record)
        let created = try await api.createRequest(heatInput())
        XCTAssertEqual(created.id, "request-one")
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/requests")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["media_type"] as? String, "movie")
        XCTAssertEqual(body["tmdb_id"] as? Int, 949)
        XCTAssertEqual(body["imdb_id"] as? String, "tt0113277")
        XCTAssertEqual(body["poster_path"] as? String, "/heat.jpg")
        XCTAssertNil(body["tvdb_id"], "absent members are omitted, not null")

        // Any other 2xx means the server acted but did not answer as the
        // contract says: an uncertain outcome, never a silent success.
        stub.reply(200, Self.record)
        do {
            _ = try await api.createRequest(heatInput())
            XCTFail("Create requires exactly 201")
        } catch {
            XCTAssertTrue(RequestMutationFailure.isUncertain(error), "\(error)")
        }
    }

    func testCancelEncodesTheOpaqueIdAndSendsAnEmptyBody() async throws {
        let (api, _) = try await client()
        stub.reply(200, Self.record)
        _ = try await api.cancelRequest(id: "a/b?c", reason: nil)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/requests/a%2Fb%3Fc/cancel")
        XCTAssertNil(components.query)
        XCTAssertEqual(request.bodyString, "{}")
    }

    func testFailuresSplitIntoDefiniteAndUncertainWithoutResending() async throws {
        let (api, _) = try await client()
        let definite: [APIv2TestStub.Reply] = [
            .failure(URLError(.cannotConnectToHost)),
            .json(409, Self.problem("conflict", 409, "The media already has an active request.")),
        ]
        let uncertain: [APIv2TestStub.Reply] = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
            .json(201, #"{"id":"#),
        ]
        for (reply, expected) in definite.map({ ($0, false) }) + uncertain.map({ ($0, true) }) {
            stub.reset()
            stub.reply(reply)
            do {
                _ = try await api.createRequest(heatInput())
                XCTFail("Expected a failure for \(reply)")
            } catch {
                XCTAssertEqual(RequestMutationFailure.isUncertain(error), expected, "\(error)")
            }
            XCTAssertEqual(stub.requests.count, 1, "create is never resent: \(reply)")
        }
    }

    // MARK: Error copy

    func testProblemCopyUsesTheServerDetailForCollapsedConflicts() {
        func copy(_ type: String, _ status: Int, _ detail: String) throws -> String {
            let data = Data(Self.problem(type, status, detail).utf8)
            let problem = try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: data)
            return RequestErrorCopy.message(for: APIv2Error.problem(problem))
        }
        XCTAssertEqual(try copy("conflict", 409, "The media is already available in the library."),
                       "The media is already available in the library.")
        XCTAssertEqual(try copy("rate_limited", 429, "Request quota exceeded: 5 of 5 requests used in the last 7 days."),
                       "Request quota exceeded: 5 of 5 requests used in the last 7 days.")
        XCTAssertEqual(try copy("validation_failed", 422, "The request did not pass validation; see errors."),
                       "That request couldn't be submitted")
        XCTAssertEqual(try copy("capability_disabled", 409, "requests is disabled"), "Requests are turned off")
        XCTAssertEqual(try copy("client_upgrade_required", 410, "Upgrade"), UpdateRequirement.appMessage)
    }

    // MARK: Uncertain hold on the detail page

    @MainActor
    func testUncertainCreateHoldsTheActionUntilAFreshRead() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api)
        stub.sequence([
            .json(200, Self.detail),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.notConnectedToInternet)),
        ])
        await model.load()
        XCTAssertEqual(model.primaryAction, .request)

        await model.submitRequest()
        XCTAssertEqual(model.primaryAction, .status(.unavailable(reason: RequestErrorCopy.unconfirmedToken)))
        XCTAssertEqual(model.actionErrorMessage, RequestErrorCopy.unconfirmedSubmitMessage)
        await model.submitRequest()
        XCTAssertEqual(stub.requests.filter { $0.method == "POST" }.count, 1, "held create is never resent")

        // The server's detail now shows the request that did go through.
        stub.reply(200, Self.detail.replacingOccurrences(of: #""request":{"requestable":true}"#,
            with: #""request":{"requestable":false,"status":"pending","reason":"already_requested","request_id":"request-one"}"#))
        await model.load()
        XCTAssertEqual(model.primaryAction, .status(.pending))
        XCTAssertNil(model.actionErrorMessage)
    }
}
