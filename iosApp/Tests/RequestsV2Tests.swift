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

    private func client(profile: String? = "profile-one",
                        captureBarrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore) {
        let tokens = try await tokens(profile: profile)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens,
            requestCaptureBarrier: { await captureBarrier?(tokens) })
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

    func testRequestStateDecodesWhenPresentAbsentOrUnknown() async throws {
        let (api, _) = try await client()
        func record(_ id: String, state: String?) -> String {
            let member = state.map { #","state":"\#($0)""# } ?? ""
            return Self.record
                .replacingOccurrences(of: #""id":"request-one""#, with: #""id":"\#(id)""#)
                .replacingOccurrences(of: #""status":"pending""#, with: #""status":"completed""# + member)
        }
        stub.reply(200, #"{"items":[\#(record("new", state: "processing")),\#(record("old", state: nil)),\#(record("newer", state: "archived"))],"page":{"has_more":false}}"#)
        let records = try await api.myRequests()
        XCTAssertEqual(records.map(\.id), ["new", "old", "newer"])
        XCTAssertEqual(records.map(\.state), [.processing, nil, .unknown])

        // The title detail's compact state carries the same member.
        let active = #""request":{"status":"completed","state":"processing","requestable":false,"reason":"already_requested","request_id":"request-one","following":false,"requested_by_viewer":true}"#
        for (body, expected) in [
            (Self.detail.replacingOccurrences(of: #""request":{"requestable":true}"#, with: active), RequestUserState.processing),
            (Self.detail.replacingOccurrences(of: #""request":{"requestable":true}"#, with: active.replacingOccurrences(of: "processing", with: "archived")), .unknown),
        ] {
            stub.reply(200, body)
            let detail = try await api.requestMediaDetail(mediaType: .movie, tmdbId: 949)
            XCTAssertEqual(detail.request.state, expected)
        }
        stub.reply(200, Self.detail)
        let requestable = try await api.requestMediaDetail(mediaType: .movie, tmdbId: 949)
        XCTAssertNil(requestable.request.state)
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

    /// Once create or cancel has captured its owner, an owner change cannot
    /// prove the server never acted: the transport raises the same error just
    /// before sending and after the response. Both mutations report it as an
    /// uncertain outcome instead of a definite failure.
    func testOwnerChangeAfterCaptureMakesAMutationUncertain() async throws {
        let calls: [(String, (APIv2Client) async throws -> Void, Int)] = [
            ("create", { _ = try await $0.createRequest(self.heatInput()) }, 201),
            ("cancel", { _ = try await $0.cancelRequest(id: "request-one", reason: nil) }, 200),
        ]
        for (name, call, status) in calls {
            stub.reset()
            let (blocked, _) = try await client(captureBarrier: { await $0.setProfileId("profile-two") })
            do {
                try await call(blocked)
                XCTFail("\(name): must not dispatch for a replaced owner")
            } catch APIv2RequestsError.outcomeUnknownOwnerChanged { }
            XCTAssertTrue(stub.requests.isEmpty, name)

            stub.reset()
            let (api, tokens) = try await client()
            stub.reply(status, Self.record)
            stub.hold()
            let task = Task { try await call(api) }
            await stub.waitUntilHeld()
            await tokens.setProfileToken("replacement")
            stub.release()
            do {
                try await task.value
                XCTFail("\(name): a response for a replaced owner cannot publish")
            } catch {
                XCTAssertEqual(error as? APIv2RequestsError, .outcomeUnknownOwnerChanged, name)
                XCTAssertTrue(RequestMutationFailure.isUncertain(error), name)
            }
            XCTAssertEqual(stub.requests.count, 1, name)
        }

        // Reads keep the ordinary fence error: nothing to hold.
        stub.reset()
        let (api, tokens) = try await client()
        stub.reply(200, Self.detail)
        stub.hold()
        let read = Task { _ = try await api.requestMediaDetail(mediaType: .movie, tmdbId: 949) }
        await stub.waitUntilHeld()
        await tokens.setProfileToken("replacement")
        stub.release()
        do {
            try await read.value
            XCTFail("A read for a replaced owner cannot publish")
        } catch HTTPError.authorityChanged { }
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
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        stub.sequence([
            .json(200, Self.detail),
            .json(200, #"{"items":[]}"#),
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

    @MainActor
    func testDetailOpensTheLibraryOnlyWithoutAnActiveRequest() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .series, tmdbId: 1399, api: api, cache: RequestDetailCache())
        // A title in the library, with the given request state.
        func inLibrary(_ request: String) -> String {
            Self.detail
                .replacingOccurrences(of: #""availability":"missing""#,
                    with: #""availability":"available","library_content_id":"series-1""#)
                .replacingOccurrences(of: #""request":{"requestable":true}"#, with: #""request":\#(request)"#)
        }
        let cases: [(String, RequestPrimaryAction)] = [
            (#"{"requestable":false,"reason":"already_available"}"#, .openInLibrary(contentId: "series-1")),
            // A request for the missing seasons, on its way or failed.
            (#"{"requestable":false,"reason":"already_requested","status":"downloading","state":"processing"}"#,
             .status(.onTheWay)),
            (#"{"requestable":false,"reason":"already_requested","status":"completed","state":"partially_available"}"#,
             .status(.onTheWay)),
            (#"{"requestable":false,"reason":"already_requested","status":"queued","state":"failed"}"#,
             .status(.needsAttention(.failed, reason: nil))),
            // A server without `state`: availability decides, as before.
            (#"{"requestable":false,"reason":"already_requested","status":"downloading"}"#,
             .openInLibrary(contentId: "series-1")),
        ]
        for (request, expected) in cases {
            stub.reply(200, inLibrary(request))
            await model.load()
            XCTAssertEqual(model.primaryAction, expected, request)
        }
    }

    @MainActor
    func testFinishedDownloadTheTitleAnnotationMissedIsNotRequestableAgain() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        // The title reads as requestable, but the user's own request has
        // finished downloading and waits on the library.
        let downloaded = Self.record
            .replacingOccurrences(of: #""status":"pending""#, with: #""status":"completed","state":"processing""#)
        stub.sequence([
            .json(200, Self.detail),
            .json(200, #"{"items":[\#(downloaded)]}"#),
        ])
        await model.load()
        XCTAssertEqual(model.primaryAction, .status(.onTheWay))
        XCTAssertEqual(model.progress?.shortLabel, "Adding to library")
        XCTAssertFalse(model.canCancel)
    }

    @MainActor
    func testAFailedRequestIsTheStatusAndTheActionReadsRequestAgain() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        // The server calls the title requestable again: the user's request
        // failed, so it no longer blocks a new one.
        let failed = Self.record
            .replacingOccurrences(of: #""outcome":"active""#, with: #""outcome":"failed","state":"failed""#)
        stub.sequence([
            .json(200, Self.detail),
            .json(200, #"{"items":[\#(failed)]}"#),
        ])
        await model.load()
        XCTAssertEqual(model.primaryAction, .request)
        XCTAssertEqual(model.endedRequest?.id, "request-one")
        XCTAssertEqual(model.progress?.display, .needsAttention(.failed, reason: nil))
    }

    @MainActor
    func testUncertainCancelOnTheDetailPageIsNeverResent() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        let pendingDetail = Self.detail.replacingOccurrences(of: #""request":{"requestable":true}"#,
            with: #""request":{"requestable":false,"status":"pending","reason":"already_requested","request_id":"request-one"}"#)
        stub.sequence([
            .json(200, pendingDetail),
            .json(200, #"{"items":[\#(Self.record)]}"#),
            .failure(URLError(.networkConnectionLost)),
            // The refresh after the uncertain cancel fails too.
            .failure(URLError(.notConnectedToInternet)),
        ])
        await model.load()
        XCTAssertTrue(model.canCancel)

        await model.cancel()
        XCTAssertFalse(model.canCancel, "an unconfirmed cancel holds until a fresh read")
        XCTAssertEqual(model.actionErrorMessage, RequestErrorCopy.unconfirmedCancelMessage)
        await model.cancel()
        XCTAssertEqual(stub.requests.filter { $0.method == "POST" }.count, 1, "held cancel is never resent")
    }

    @MainActor
    func testAnApprovalPinOpensOneModerationPageOnly() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let cache = RequestDetailCache()
        let queued = try HTTPClient.makeJSONDecoder().decode(MediaRequest.self, from: Data(Self.record.utf8))
        cache.pinModeration(queued)
        stub.reply(200, Self.detail)

        let fromQueue = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: cache)
        XCTAssertTrue(fromQueue.openedForModeration)
        await fromQueue.load()

        // Backing out and reopening the title from anywhere else is an
        // ordinary page, not a moderation page for someone else's request.
        let later = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: cache)
        XCTAssertFalse(later.openedForModeration)
    }

    @MainActor
    func testALostApprovalUnlocksWhenItsHoldRunsOutWithoutAnotherRead() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestApprovalsViewModel(api: api, holdLifetime: .milliseconds(250))
        addTeardownBlock { @MainActor in RequestDetailCache.shared.clear() }
        stub.reply(path: "/api/v2/admin/requests", 200, #"{"items":[\#(Self.record)],"page":{"has_more":false}}"#)
        // The approve (and every other read) is lost.
        stub.fail()
        await model.load()
        let request = try XCTUnwrap(model.awaitingApproval.first)

        await model.perform(.approve, on: request)
        XCTAssertFalse(model.canAct(on: request), "a read showing the request unchanged keeps the hold")

        for _ in 0..<500 where !model.canAct(on: request) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canAct(on: request), "the hold ends on time with no read to settle it")
        XCTAssertNil(model.actionErrorMessage)
        XCTAssertEqual(stub.requests.filter { $0.method == "POST" }.count, 1, "releasing the hold never resends")
    }

    @MainActor
    func testCreateInterruptedByAnOwnerChangeHoldsWithoutReReading() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        stub.reply(200, Self.detail)
        await model.load()
        XCTAssertEqual(model.primaryAction, .request)

        stub.reply(201, Self.record)
        stub.hold()
        let submit = Task { await model.submitRequest() }
        await stub.waitUntilHeld()
        await tokens.setProfileToken("replacement")
        stub.release()
        await submit.value

        XCTAssertEqual(model.primaryAction, .status(.unavailable(reason: RequestErrorCopy.unconfirmedToken)))
        XCTAssertEqual(model.actionErrorMessage, RequestErrorCopy.unconfirmedSubmitMessage)
        // The title read, then the user's own requests; nothing after the POST.
        XCTAssertEqual(stub.requests.map(\.method), ["GET", "GET", "POST"], "no re-read under the replaced owner")
        await model.submitRequest()
        XCTAssertEqual(stub.requests.filter { $0.method == "POST" }.count, 1, "held create is never resent")
    }

    // MARK: Which request speaks for a title

    private static func record(_ id: String, outcome: String, createdAt: String, status: String = "pending") -> String {
        Self.record
            .replacingOccurrences(of: #""id":"request-one""#, with: #""id":"\#(id)""#)
            .replacingOccurrences(of: #""status":"pending""#, with: #""status":"\#(status)""#)
            .replacingOccurrences(of: #""outcome":"active""#, with: #""outcome":"\#(outcome)""#)
            .replacingOccurrences(of: #""created_at":"2026-01-02T03:04:05.000Z""#, with: #""created_at":"\#(createdAt)""#)
    }

    @MainActor
    func testCancellingANewerRequestDoesNotBringBackAnOlderDecline() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let cache = RequestDetailCache()
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: cache)
        // Declined, requested again, then that second request cancelled.
        let declined = Self.record("declined", outcome: "declined", createdAt: "2026-01-02T03:04:05.000Z")
        let cancelled = Self.record("cancelled", outcome: "cancelled", createdAt: "2026-02-02T03:04:05.000Z")
        stub.sequence([
            .json(200, Self.detail),
            .json(200, #"{"items":[\#(declined),\#(cancelled)]}"#),
        ])
        await model.load()
        XCTAssertNil(model.record)
        XCTAssertNil(model.endedRequest)
        XCTAssertEqual(model.primaryAction, .request)
        XCTAssertNil(cache.ownRecord(.init(mediaType: .movie, tmdbId: 949)), "the next first frame agrees")
    }

    @MainActor
    func testAnOldFailureDoesNotOverrideATitleNowInTheLibrary() async throws {
        let tokens = try await tokens()
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let model = RequestDetailViewModel(mediaType: .movie, tmdbId: 949, api: api, cache: RequestDetailCache())
        let inLibrary = Self.detail
            .replacingOccurrences(of: #""availability":"missing""#,
                with: #""availability":"available","library_content_id":"movie-1""#)
            .replacingOccurrences(of: #""request":{"requestable":true}"#,
                with: #""request":{"requestable":false,"reason":"already_available"}"#)
        let failed = Self.record("failed", outcome: "failed", createdAt: "2026-01-02T03:04:05.000Z")
        stub.sequence([
            .json(200, inLibrary),
            .json(200, #"{"items":[\#(failed)]}"#),
        ])
        await model.load()
        XCTAssertEqual(model.primaryAction, .openInLibrary(contentId: "movie-1"))
        XCTAssertNil(model.endedRequest)
        XCTAssertEqual(model.progress?.display, .inLibrary)
    }

    @MainActor
    func testApprovalCacheKeepsThePendingRequestOverAFailedOne() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let pending = try decoder.decode(MediaRequest.self, from: Data(Self.record("pending", outcome: "active",
            createdAt: "2026-02-02T03:04:05.000Z").utf8))
        let failed = try decoder.decode(MediaRequest.self, from: Data(Self.record("failed", outcome: "failed",
            createdAt: "2026-01-02T03:04:05.000Z").utf8))
        let cache = RequestDetailCache()
        // Approvals stores its queue as `awaitingApproval + failed`.
        cache.storeModerationRecords([pending, failed])
        XCTAssertEqual(cache.moderationRecord(.init(mediaType: .movie, tmdbId: 949))?.id, "pending")
    }

    func testAdminReadForOneTitleFiltersOnTheServer() async throws {
        let (client, _) = try await client()
        stub.reply(200, #"{"items":[],"page":{"has_more":false}}"#)
        _ = try await client.adminRequests(status: .pending, outcome: .active, mediaType: .movie, tmdbId: 949)
        XCTAssertEqual(stub.requests.first?.path, "/api/v2/admin/requests")
        XCTAssertEqual(stub.requests.first?.query,
            ["limit": "50", "status": "pending", "outcome": "active", "media_type": "movie", "q": "949"])
    }
}
