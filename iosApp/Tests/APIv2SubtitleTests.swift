import Foundation
import XCTest
@testable import Silo

/// Subtitle wire models and the v2 provider-search, stored-subtitle and
/// download calls: opaque string identity on the wire, exact statuses, the
/// profile header, and the send-once download outcomes.
final class APIv2SubtitleTests: XCTestCase {
    private var stub = APIv2TestStub()

    private static let downloadBody = SubtitleDownloadBody(
        from: SubtitleSearchResult(id: "os-123", provider: "opensubtitles", language: "en",
                                   releaseName: "Some.Movie", format: "srt", score: 87.5, hearingImpaired: false),
        mediaFileId: 42)

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client(profile: String = "profile-one") async throws -> (APIv2Client, TokenStore) {
        let name = "APIv2SubtitleTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://subtitles.example")
        await tokens.setProfileId(profile)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private static func problem(_ type: String, _ status: Int, _ detail: String) -> String {
        #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"T","status":\#(status),"detail":"\#(detail)","instance":"urn:silo:request:1"}"#
    }

    private static func downloadResponse(id: String) -> String {
        #"{"subtitle":{"id":"\#(id)","media_file_id":"42","provider":"opensubtitles","language":"en","format":"srt","release_name":"Some.Movie","score":87.5,"hearing_impaired":false,"created_at":"2026-01-02T03:04:05.678Z"}}"#
    }

    private func owner(_ tokens: TokenStore) async throws -> CapturedOrdinaryRequestAuth {
        let captured = await tokens.captureOrdinaryRequestAuth()
        return try XCTUnwrap(captured)
    }
    private func fixture(_ name: String) throws -> Data {
        try APIv2FixtureTestSupport.data(named: name, bundleClass: Self.self)
    }

    private func assertInvalidSubtitleResponse<T>(_ expression: @autoclosure () throws -> T,
                                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case APIv2Error.invalidSubtitleResponse = error else {
                return XCTFail("\(message): unexpected \(error)", file: file, line: line)
            }
        }
    }

    private func assertDecodingFails<T: Decodable>(_ type: T.Type, from data: Data, _ message: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(type, from: data), message, file: file, line: line) { error in
            XCTAssertTrue(error is DecodingError, "\(message): unexpected \(error)", file: file, line: line)
        }
    }

    func testCreateAndCancelPreserveOpaqueJobIdentifiers() async throws {
        let name = "SubtitleJobIdentityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://subtitles.example")
        let stub = APIv2TestStub()
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let body = try APIv2SubtitleCreateBody(TranslateSubtitleBody(mediaFileId: 42, kind: .translate,
            sourceIndex: 0, sourceLanguage: "en", targetLanguage: "fr", sessionId: nil, startPosition: 0))
        for id in ["opaque-job", "007", "9223372036854775808", "job/part?x#y%z", ""] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitle_ai_job_opaque_id")) as? [String: Any])
            var job = try XCTUnwrap(object["job"] as? [String: Any])
            job["id"] = id; job["kind"] = "translate"; job["source_index"] = 0
            object["job"] = job; object["live_delivery_attached"] = false
            stub.reply(202, String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            let auth = try await api.captureAIAuthority()
            if id.isEmpty {
                do { _ = try await api.createSubtitle(body, auth: auth); XCTFail("Accepted empty job ID") }
                catch APIv2Error.invalidSubtitleResponse { }
                let count = stub.requests.count
                do { try await api.cancelSubtitleJob(id: id); XCTFail("Dispatched empty job ID") }
                catch APIv2Error.invalidSubtitleResponse { }
                XCTAssertEqual(stub.requests.count, count)
            } else {
                let created = try await api.createSubtitle(body, auth: auth)
                XCTAssertEqual(created.job.id, id)
                stub.reply(204, "")
                try await api.cancelSubtitleJob(id: id)
                let request = try XCTUnwrap(stub.requests.last)
                let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                XCTAssertNil(components.query)
                XCTAssertNil(components.fragment)
                let segment = try XCTUnwrap(components.percentEncodedPath.split(separator: "/").dropLast().last)
                XCTAssertEqual(String(segment).removingPercentEncoding, id)
            }
        }
    }

    func testAIJobFixturePreservesOpaqueIdentityAndNullableResult() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id"))
        XCTAssertEqual(wire.job.id, "9007199254740993")
        // The synthetic server fixture intentionally has an empty kind.
        // Preserve it on the wire, but refuse unsupported player semantics.
        assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "empty kind")
        let playable = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id").replacingEmptyJobKind())
        let job = try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740993")
        XCTAssertEqual(job.id, "9007199254740993")
        XCTAssertEqual(job.mediaFileId, 42)
        XCTAssertNil(job.resultSubtitleId)
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.errorMessage, "Subtitle processing failed.")
        XCTAssertEqual(job.updatedAt, "2026-01-02T03:04:05.678Z")
        assertInvalidSubtitleResponse(try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740992"), "job id mismatch")
    }

    func testAIJobResultUsesExactIntegerProjection() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitle_ai_job_opaque_id")) as? [String: Any])
        var row = try XCTUnwrap(object["job"] as? [String: Any])
        row["kind"] = "translate"
        for raw in ["9007199254740993", "9223372036854775808", "07", "opaque"] {
            row["result_subtitle_id"] = raw
            object["job"] = row
            let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
                from: JSONSerialization.data(withJSONObject: object))
            if raw == "9007199254740993" {
                XCTAssertEqual(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id).resultSubtitleId, 9007199254740993)
            } else {
                assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "result id \(raw)")
            }
        }
        row["media_file_id"] = 42
        object["job"] = row
        assertDecodingFails(APIv2SubtitleJobEnvelope.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric media_file_id is not the wire contract")
    }

    func testAIQuotaFixtureRetainsBudgetFields() throws {
        let quota = try HTTPClient.makeJSONDecoder().decode(SubtitleAIQuota.self, from: fixture("subtitle_ai_quota"))
        XCTAssertTrue(quota.limited)
        XCTAssertEqual(quota.limit, 5)
        XCTAssertEqual(quota.used, 2)
        XCTAssertEqual(quota.remaining, 3)
        XCTAssertEqual(quota.period, "daily")
    }

    // MARK: Stored subtitles

    func testStoredFixtureKeepsOpaqueIDAndRefusesDifferentFile() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self, from: fixture("subtitles_stored"))
        let subtitle = try XCTUnwrap(wire.subtitles.first)
        let player = try subtitle.playerValue(mediaFileID: 42)
        XCTAssertEqual(player.id, "7")
        XCTAssertEqual(player.mediaFileId, 42)
        XCTAssertEqual(player.streamURLExtension, ".vtt")
        assertInvalidSubtitleResponse(try subtitle.playerValue(mediaFileID: 43), "another file's subtitle")
    }

    /// IDs fail soft: opaque, leading-zero and oversized IDs all stay in the
    /// listing, in server order, because a row's position fixes its combined
    /// player index. Only a number where the contract says string fails.
    func testStoredListKeepsEveryOpaqueIDInServerOrder() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitles_stored")) as? [String: Any])
        let row = try XCTUnwrap((object["subtitles"] as? [[String: Any]])?.first)
        let ids = ["opaque-id", "7", "9223372036854775808", "07"]
        object["subtitles"] = ids.map { id -> [String: Any] in
            var other = row
            other["id"] = id
            return other
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try wire.playerValues(mediaFileID: 42).map(\.id), ids)

        var numeric = row
        numeric["id"] = 7
        object["subtitles"] = [numeric]
        assertDecodingFails(APIv2StoredSubtitles.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric id is not the wire contract")
    }

    /// Dropping a row would shift every later track's combined index, so a
    /// row for another file fails the whole listing.
    func testStoredListWithAnotherFilesRowIsRefused() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitles_stored")) as? [String: Any])
        let row = try XCTUnwrap((object["subtitles"] as? [[String: Any]])?.first)
        var other = row
        other["id"] = "8"
        other["media_file_id"] = "43"
        object["subtitles"] = [row, other]
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
            from: JSONSerialization.data(withJSONObject: object))
        assertInvalidSubtitleResponse(try wire.playerValues(mediaFileID: 42), "a row for file 43")
    }

    func testStoredListReadsTheV2PathWithTheProfile() async throws {
        let (api, _) = try await client()
        stub.reply(200, String(decoding: try fixture("subtitles_stored"), as: UTF8.self))
        let rows = try await api.storedSubtitles(mediaFileID: 42)
        XCTAssertEqual(rows.map(\.id), ["7"])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/subtitles/42")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")

        stub.reset()
        do { _ = try await api.storedSubtitles(mediaFileID: 0); XCTFail("Listed file 0") }
        catch APIv2SubtitleRequestError.invalidMediaFile { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Provider status

    func testProviderStatusIsAvailableOnlyWhenAllowedAvailableAndEnabled() async throws {
        let (api, _) = try await client()
        let cases: [(String, Bool)] = [
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"available","allowed":true}"#, true),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"available","allowed":false}"#, false),
            (#"{"schema_version":1,"enabled":false,"providers":[],"revision":"r","state":"not_configured","allowed":true}"#, false),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"disabled","allowed":true}"#, false),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"future_state","allowed":true}"#, false),
        ]
        for (body, expected) in cases {
            stub.reply(200, body)
            let status = try await api.subtitleProviderStatus()
            XCTAssertEqual(status.isAvailable, expected, body)
        }
        XCTAssertEqual(Set(stub.requestedPaths), ["/api/v2/subtitles/providers/status"])

        // The contract requires `allowed`; the v1 shape is not an answer.
        stub.reply(200, #"{"schema_version":1,"enabled":true,"providers":[]}"#)
        do { _ = try await api.subtitleProviderStatus(); XCTFail("Decoded a status without allowed/state") }
        catch is DecodingError { }
    }

    /// A failed probe is not an answer: the store keeps its previous value
    /// and the next refresh asks again.
    @MainActor
    func testProviderStoreKeepsItsValueWhenTheProbeFails() async throws {
        let (api, _) = try await client()
        let store = SubtitleProvidersStore(api: SiloAI(v2: api))
        stub.reply(200, #"{"schema_version":1,"enabled":false,"providers":[],"revision":"r","state":"not_configured","allowed":true}"#)
        await store.refresh()
        XCTAssertFalse(store.isAvailable)
        stub.reply(503, Self.problem("service_unavailable", 503, "Down"))
        await store.refresh()
        XCTAssertFalse(store.isAvailable)
        stub.reply(200, #"{"schema_version":1,"enabled":true,"providers":["subdl"],"revision":"s","state":"available","allowed":true}"#)
        await store.refresh()
        XCTAssertTrue(store.isAvailable)
    }

    // MARK: Search and download

    func testSearchPostsTheV2BodyOnce() async throws {
        let (api, _) = try await client()
        stub.reply(200, String(decoding: try fixture("subtitles_search_partial"), as: UTF8.self))
        let response = try await api.searchSubtitles(SubtitleSearchBody(mediaFileId: 42, languages: ["en", "fr"]))
        XCTAssertEqual(response.results.map(\.id), ["opaque-result"])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/subtitles/search")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["languages"] as? [String], ["en", "fr"])
        XCTAssertEqual(body.count, 2)

        stub.reset()
        let tooMany = SubtitleSearchBody(mediaFileId: 42, languages: (0...100).map { "l\($0)" })
        do { _ = try await api.searchSubtitles(tooMany); XCTFail("Sent 101 languages") }
        catch APIv2SubtitleRequestError.tooManyLanguages { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testDownloadPostsTheContractBodyAndReturnsTheStoredRow() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        stub.reply(200, Self.downloadResponse(id: "stored-9"))
        let row = try await api.downloadSubtitle(Self.downloadBody, auth: auth)
        XCTAssertEqual(row.id, "stored-9")
        XCTAssertEqual(row.mediaFileId, 42)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/subtitles/download")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["media_file_id", "provider", "subtitle_id", "language",
                                        "release_name", "score", "hearing_impaired"])
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["subtitle_id"] as? String, "os-123")
    }

    /// `downloadSubtitle` is `non_retryable`: every failure leaves exactly one
    /// request, and only a refusal or an error answer is a definite failure.
    func testDownloadFailuresAreSentOnceAndSortedByOutcome() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        let definite: [APIv2TestStub.Reply] = [
            .failure(URLError(.cannotConnectToHost)),
            .json(422, Self.problem("validation_failed", 422, "The provider result is not valid.")),
            .json(502, Self.problem("upstream_failed", 502, "The provider did not answer.")),
        ]
        let uncertain: [APIv2TestStub.Reply] = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
            .json(200, #"{"subtitle":"#),
            .json(201, Self.downloadResponse(id: "stored-9")),
        ]
        for (reply, expected) in definite.map({ ($0, false) }) + uncertain.map({ ($0, true) }) {
            stub.reset()
            stub.reply(reply)
            do {
                _ = try await api.downloadSubtitle(Self.downloadBody, auth: auth)
                XCTFail("Expected a failure for \(reply)")
            } catch {
                XCTAssertEqual(SubtitleDownloadOutcome.isUnconfirmed(error), expected, "\(error)")
            }
            XCTAssertEqual(stub.requests.count, 1, "download is never resent: \(reply)")
        }
    }

    func testDownloadForAReplacedOwnerIsRefusedOrUnconfirmed() async throws {
        // Replaced before the call: refused, nothing sent.
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        await tokens.setProfileId("profile-two")
        do { _ = try await api.downloadSubtitle(Self.downloadBody, auth: auth); XCTFail("Sent for a replaced owner") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)

        // Replaced while in flight: the server may have stored it.
        stub.reset()
        let (inFlight, inFlightTokens) = try await client()
        let inFlightOwner = try await owner(inFlightTokens)
        stub.reply(200, Self.downloadResponse(id: "stored-9"))
        stub.hold()
        let task = Task { try await inFlight.downloadSubtitle(Self.downloadBody, auth: inFlightOwner) }
        await stub.waitUntilHeld()
        await inFlightTokens.setProfileToken("replacement")
        stub.release()
        do {
            _ = try await task.value
            XCTFail("A response for a replaced owner cannot publish")
        } catch {
            XCTAssertEqual(error as? APIv2SubtitleRequestError, .outcomeUnknownOwnerChanged)
            XCTAssertTrue(SubtitleDownloadOutcome.isUnconfirmed(error))
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSearchUsesStringFileIDAndPreservesPartialResultWarning() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(APIv2SubtitleSearchBody(SubtitleSearchBody(mediaFileId: 42, languages: ["en"])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["languages"] as? [String], ["en"])
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSearchResponse.self,
            from: fixture("subtitles_search_partial")).playerValue
        XCTAssertEqual(response.results.first?.id, "opaque-result")
        XCTAssertNil(response.results.first?.uploadDate)
        XCTAssertEqual(response.warnings, ["One or more subtitle providers could not complete the search."])
        assertDecodingFails(APIv2SubtitleSearchResponse.self, from: Data(#"{"results":null,"warnings":[]}"#.utf8),
                            "results must be an array")
    }
}

private extension Data {
    func replacingEmptyJobKind() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""kind": """#, with: #""kind": "translate""#).utf8)
    }
}
