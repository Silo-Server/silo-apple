import Foundation
import XCTest
@testable import Silo

/// Shuffle on the v2 wire: each operation's path, body, and success status,
/// the problem statuses callers act on, and the capability gate.
final class ShuffleV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, CapturedOrdinaryRequestAuth) {
        let name = "ShuffleV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://shuffle.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let captured = await tokens.captureOrdinaryRequestAuth()
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), try XCTUnwrap(captured))
    }

    private func jsonBody(_ request: StubURLProtocol.Request?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func problem(_ status: Int, _ identifier: String) -> String {
        #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(identifier)","title":"t","status":\#(status),"detail":"d","instance":"urn:test"}"#
    }

    private let movie = #"{"content_id":"movie-1","type":"movie","title":"Alpha Run","year":2001,"backdrop_url":"/art/alpha.jpg"}"#
    private let episode = #"{"content_id":"ep-2","type":"episode","title":"Pilot","series_id":"series-1","series_title":"Echo Station","season_number":1,"episode_number":2,"poster_url":"/art/ep2.jpg"}"#

    private func shuffle(id: String = "s1", current: String, next: String, parent: String? = nil) -> String {
        let parentField = parent.map { #","parent_title":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","scope":{"kind":"season","id":"series-1-S01","title":"Season 1"\#(parentField)},"current":\#(current),"next":\#(next),"created_at":"2026-10-05T00:00:00Z","updated_at":"2026-10-05T00:00:00Z"}"#
    }

    // MARK: Create

    func testCreateSendsTheScopeOnceAndDecodesBothPicks() async throws {
        stub.reply(201, shuffle(current: movie, next: episode, parent: "Echo Station"))
        let (api, auth) = try await client()

        let created = try await api.createShuffle(
            scope: ShuffleScopeRequest(kind: .libraryCollection, id: "col-9"), imageSize: "large", auth: auth
        )

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/api/v2/shuffles")
        XCTAssertEqual(sent.query["image_size"], "large")
        XCTAssertEqual(sent.header("x-profile-id"), "profile-one")
        let scope = try XCTUnwrap(try jsonBody(sent)["scope"] as? [String: String])
        XCTAssertEqual(scope, ["kind": "library_collection", "id": "col-9"])

        XCTAssertEqual(created.id, "s1")
        XCTAssertEqual(created.current.contentId, "movie-1")
        XCTAssertFalse(created.current.isEpisode)
        XCTAssertEqual(created.next.seriesTitle, "Echo Station")
        XCTAssertEqual(created.next.episodeNumber, 2)
        XCTAssertEqual(created.scopeLabel, "Echo Station · Season 1")
        XCTAssertEqual(created.upcoming?.contentId, "ep-2")
    }

    func testCreateProblemsSurfaceAsNotFoundAndNothingToPlay() async throws {
        let (api, auth) = try await client()
        for (status, identifier, expected) in [(404, "not_found", ShuffleError.notFound),
                                               (409, "conflict", ShuffleError.nothingToPlay)] {
            stub.reply(status, problem(status, identifier))
            do {
                _ = try await api.createShuffle(scope: ShuffleScopeRequest(kind: .library, id: "1"), imageSize: nil, auth: auth)
                XCTFail("\(status) must fail")
            } catch {
                XCTAssertEqual(ShuffleError.classify(error), expected)
            }
        }
        // Each create went out once: a resend would start a second shuffle.
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testAShuffleStartedForAReplacedProfileIsRefusedWithoutAnAlert() async throws {
        stub.reply(201, shuffle(current: movie, next: episode))
        let name = "ShuffleV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://shuffle.example")
        await tokens.setProfileId("profile-one")
        // The profile changes after the answer arrives, before it is used.
        let api = SiloAPI(
            http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            ownerRecheckBarrier: { await tokens.setProfileId("profile-two") }
        )

        do {
            _ = try await api.createShuffle(scope: ShuffleScopeRequest(kind: .library, id: "1"))
            XCTFail("One profile's shuffle must not open for the next")
        } catch {
            XCTAssertTrue(ShuffleLauncher.isOwnerChange(error), "unexpected \(error)")
        }
    }

    func testOnlyCreateIsSentOnceAfterAnExpiredSession() {
        // A resent create would start a second shuffle; advance, skip and
        // stop name what they act on, so a replay changes nothing.
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/shuffles", method: "POST"))
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/shuffles/s1/advance", method: "POST"))
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/shuffles/s1/skip", method: "POST"))
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/shuffles/s1", method: "DELETE"))
    }

    func testOtherFailuresAreNotClassified() {
        XCTAssertNil(ShuffleError.classify(APIv2Error.httpStatus(500)))
        XCTAssertNil(ShuffleError.classify(URLError(.timedOut)))
    }

    // MARK: Read, advance, skip, stop

    func testAdvanceNamesTheItemThatPlayed() async throws {
        stub.reply(200, shuffle(current: episode, next: movie))
        let (api, auth) = try await client()

        let advanced = try await api.advanceShuffle(id: "s1", fromContentId: "movie-1", imageSize: nil, auth: auth)

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/api/v2/shuffles/s1/advance")
        XCTAssertEqual(try jsonBody(sent)["from_content_id"] as? String, "movie-1")
        XCTAssertEqual(advanced.current.contentId, "ep-2")
    }

    func testSkipNamesTheAnnouncedNextItem() async throws {
        stub.reply(200, shuffle(current: movie, next: episode))
        let (api, auth) = try await client()

        _ = try await api.skipShuffleItem(id: "s1", nextContentId: "ep-9", imageSize: nil, auth: auth)

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.path, "/api/v2/shuffles/s1/skip")
        XCTAssertEqual(try jsonBody(sent)["next_content_id"] as? String, "ep-9")
    }

    func testReadConflictMeansNothingCanPlay() async throws {
        stub.reply(409, problem(409, "conflict"))
        let (api, auth) = try await client()
        do {
            _ = try await api.shuffle(id: "s1", imageSize: nil, auth: auth)
            XCTFail("409 must fail")
        } catch {
            XCTAssertEqual(ShuffleError.classify(error), .nothingToPlay)
        }
        XCTAssertEqual(stub.requests.last?.method, "GET")
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/shuffles/s1")
    }

    func testStopDeletesAndRequiresNoContent() async throws {
        stub.reply(204, "")
        let (api, auth) = try await client()
        try await api.deleteShuffle(id: "s1", auth: auth)
        XCTAssertEqual(stub.requests.last?.method, "DELETE")
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/shuffles/s1")
    }

    // MARK: Capability

    func testCapabilityOffersOnlyAvailableListedKinds() async throws {
        stub.reply(200, #"{"revision":"r","state":"available","allowed":true,"scope_kinds":["library","season"]}"#)
        let (api, auth) = try await client()
        let available = try await api.shuffleCapability(auth: auth)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/shuffles/capabilities")
        XCTAssertTrue(available.supports(.library))
        XCTAssertTrue(available.supports(.season))
        XCTAssertFalse(available.supports(.userCollection))

        stub.reply(200, #"{"revision":"r","state":"not_configured","allowed":true,"scope_kinds":[]}"#)
        let unconfigured = try await api.shuffleCapability(auth: auth)
        XCTAssertFalse(unconfigured.supports(.library))
    }
}
