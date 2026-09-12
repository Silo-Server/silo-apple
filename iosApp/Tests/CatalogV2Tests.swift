import Foundation
import XCTest
@testable import Silo

/// The v2 catalog wire layer: query grammar, strict page decoding, opaque
/// continuations, and the ownership fences around every catalog read and
/// membership mutation. Screen and view-model behavior is not covered here;
/// it arrives with the gate 3 read surfaces.
final class CatalogV2Tests: XCTestCase {
    private let terminal = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"window"}"#
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client(updateRequired: Bool = false,
                        captureBarrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore) {
        let name = "CatalogV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens,
            requestCaptureBarrier: { await captureBarrier?(tokens) })
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { updateRequired }), tokens)
    }

    // MARK: Ownership fences

    func testCatalogPagesRetainFullOwnerAtCaptureAndContinuation() async throws {
        for operation in [APIv2CatalogOperation.get, .query] {
            stub.reset()
            let (blocked, _) = try await client(captureBarrier: { await $0.setProfileToken("replacement") })
            do {
                _ = try await blocked.catalogPage(query: .init(), operation: operation)
                XCTFail("Must not replace original absent PIN at HTTP capture")
            } catch HTTPError.requestIdentityChanged { }
            XCTAssertTrue(stub.requests.isEmpty)

            let (api, tokens) = try await client()
            await tokens.setProfileToken("original")
            let authValue = await tokens.captureOrdinaryRequestAuth()
            let auth = try XCTUnwrap(authValue)
            stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque-original"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
            let first = try await api.catalogPage(query: .init(), operation: operation, auth: auth)
            let cursor = try XCTUnwrap(first.continuation)
            XCTAssertEqual(first.auth, auth)
            XCTAssertEqual(cursor.auth, auth)
            XCTAssertEqual(cursor.cursor, "opaque-original")
            XCTAssertEqual(cursor.operation, operation)
            await tokens.setProfileToken("replacement")
            do {
                _ = try await api.nextCatalogPage(cursor)
                XCTFail("Must not rebind continuation")
            } catch HTTPError.requestIdentityChanged { }
            do {
                _ = try await api.catalogPage(query: .init(), operation: operation, auth: auth)
                XCTFail("Must not rebind supplied first-page authority")
            } catch HTTPError.requestIdentityChanged { }
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    func testCatalogPageRejectsLatePINReplacementAndNon200() async throws {
        for operation in [APIv2CatalogOperation.get, .query] {
            stub.reset()
            let (api, tokens) = try await client()
            stub.reply(200, terminal)
            stub.hold()
            let task = Task { try await api.catalogPage(query: .init(), operation: operation) }
            await stub.waitUntilHeld()
            await tokens.setProfileToken("replacement")
            stub.release()
            do {
                _ = try await task.value
                XCTFail("Old PIN response cannot publish")
            } catch HTTPError.authorityChanged { }
            XCTAssertEqual(stub.requests.count, 1)

            stub.reply(202, terminal)
            do {
                _ = try await api.catalogPage(query: .init(), operation: operation)
                XCTFail("Catalog requires exact 200")
            } catch APIv2Error.httpStatus(202) { }
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testCatalogReadRejectsAccountChangeBeforePublishing() async throws {
        let (api, tokens) = try await client()
        stub.reply(200, detailJSON)
        stub.hold()
        let request = Task { try await api.catalogItem(id: "one") }
        await stub.waitUntilHeld()
        await tokens.switchActiveServer(serverId: "another-account")
        stub.release()
        do {
            _ = try await request.value
            XCTFail("Expected changed account")
        } catch HTTPError.authorityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testCatalogReadRejectsProfileChangeBeforePublishing() async throws {
        let (api, tokens) = try await client()
        stub.reply(200, detailJSON)
        stub.hold()
        let request = Task { try await api.catalogItem(id: "one") }
        await stub.waitUntilHeld()
        await tokens.setProfileId("another-profile")
        stub.release()
        do {
            _ = try await request.value
            XCTFail("Expected changed viewer")
        } catch HTTPError.authorityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testOwnedHierarchyReadsRefuseAReplacedOwnerBeforeDispatch() async throws {
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        stub.reply(200, #"{"items":[]}"#)
        _ = try await api.catalogSeasons(seriesId: "series", imageSize: nil, auth: auth)
        _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: 1, imageSize: nil, auth: auth)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/catalog/series/series/seasons",
                                             "/api/v2/catalog/series/series/seasons/1/episodes"])

        await tokens.setProfileToken("replacement")
        do {
            _ = try await api.catalogSeasons(seriesId: "series", imageSize: nil, auth: auth)
            XCTFail("a replaced owner cannot issue the read")
        } catch HTTPError.requestIdentityChanged { }
        do {
            _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: 1, imageSize: nil, auth: auth)
            XCTFail("a replaced owner cannot issue the read")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requests.count, 2, "nothing left the device after the owner changed")
    }

    // MARK: Membership mutations

    func testMembershipMutationsDispatchOnceWithTheOwnersMethodsAndPaths() async throws {
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        stub.reply(204, "")
        try await api.setFavoriteMembership(id: "movie:one", included: true, auth: auth)
        try await api.setWatchlistMembership(id: "movie:one", included: true, auth: auth)
        try await api.setFavoriteMembership(id: "movie:one", included: false, auth: auth)
        try await api.setWatchlistMembership(id: "movie:one", included: false, auth: auth)
        try await api.setWatchedState(id: "movie:one", included: true, auth: auth)
        try await api.setWatchedState(id: "movie:one", included: false, auth: auth)

        XCTAssertEqual(stub.methods, ["PUT", "PUT", "DELETE", "DELETE", "POST", "DELETE"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/favorites/movie:one", "/api/v2/watchlist/movie:one",
                                             "/api/v2/favorites/movie:one", "/api/v2/watchlist/movie:one",
                                             "/api/v2/watched/movie:one", "/api/v2/watched/movie:one"])
        for request in stub.requests {
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testMembershipMutationFailuresAreTypedAndSentOnce() async throws {
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        stub.reply(500, "{}")
        do {
            try await api.setFavoriteMembership(id: "movie:one", included: true, auth: auth)
            XCTFail("a 500 is a definite failure")
        } catch APIv2Error.httpStatus(500) { }
        stub.reply(401, "{}")
        do {
            try await api.setWatchlistMembership(id: "movie:one", included: true, auth: auth)
            XCTFail("a 401 on a single-dispatch mutation is not retried under a refreshed bearer")
        } catch APIv2Error.httpStatus(401) { }
        stub.reply(200, "{}")
        do {
            try await api.setWatchedState(id: "movie:one", included: true, auth: auth)
            XCTFail("watched requires exactly 204")
        } catch APIv2Error.httpStatus(200) { }
        XCTAssertEqual(stub.requests.count, 3, "each failure is exactly one dispatch")
    }

    func testMembershipMutationRefusesReplacedOwnerAndLateReceipt() async throws {
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        await tokens.setProfileToken("replacement")
        do {
            try await api.setFavoriteMembership(id: "movie:one", included: true, auth: auth)
            XCTFail("a prepared action cannot capture a replacement PIN")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)

        let currentValue = await tokens.captureOrdinaryRequestAuth()

        let current = try XCTUnwrap(currentValue)
        stub.reply(204, "")
        stub.hold()
        let pending = Task { try await api.setWatchlistMembership(id: "movie:one", included: true, auth: current) }
        await stub.waitUntilHeld()
        await tokens.setProfileToken("another")
        stub.release()
        do {
            try await pending.value
            XCTFail("a late receipt cannot be applied to a replacement owner")
        } catch HTTPError.authorityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testPersonalMembershipReadsEntryOn200AndAbsenceOnProblem404Only() async throws {
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        stub.reply(200, #"{"item_id":"movie:one","added_at":"2026-01-02T03:04:05Z"}"#)
        let present = try await api.personalMembership(id: "movie:one", watchlist: false, auth: auth)
        XCTAssertTrue(present)
        stub.reply(404, #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"No entry"}"#)
        let absent = try await api.personalMembership(id: "movie:one", watchlist: true, auth: auth)
        XCTAssertFalse(absent)
        stub.reply(204, "")
        do {
            _ = try await api.personalMembership(id: "movie:one", watchlist: true, auth: auth)
            XCTFail("legacy 204 is not an answer")
        } catch APIv2Error.httpStatus(204) { }
        stub.reply(200, #"{"item_id":"movie:other","added_at":"2026-01-02T03:04:05Z"}"#)
        do {
            _ = try await api.personalMembership(id: "movie:one", watchlist: true, auth: auth)
            XCTFail("an entry for another item is not a membership")
        } catch APIv2Error.incompleteCatalogRead { }
        do {
            _ = try await api.personalMembership(id: "movie:one", watchlist: true, auth: nil)
            XCTFail("an ownerless read is refused")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/favorites/movie:one", "/api/v2/watchlist/movie:one",
                                             "/api/v2/watchlist/movie:one", "/api/v2/watchlist/movie:one"])
    }

    // MARK: Read projection

    private func playableDetail(fileID: String = "41") throws -> String {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detailJSON.utf8)) as? [String: Any])
        body["type"] = "audiobook"
        body["versions"] = [["file_id": fileID, "file_name": "part-one.m4b", "resolution": "", "codec_video": "", "codec_audio": "aac",
            "hdr": false, "container": "m4b", "file_size": 123, "duration": 90, "bitrate": 12, "added_at": "2026-09-05T12:00:00.123Z",
            "presentation_kind": "audiobook_part", "presentation_part_index": 1,
            "chapters": [["index": 0, "title": "Chapter", "start_seconds": 0, "end_seconds": 90, "source": "embedded"]]]]
        body["user_data"] = ["played": false, "watched_count": 0, "unplayed_count": 1, "in_progress_count": 1,
            "position_seconds": 25, "duration_seconds": 90, "last_file_id": fileID]
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    func testReadProjectionPreservesAudioFilesChaptersAndResume() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(playableDetail().utf8))
        let detail = try ItemDetail(catalog: wire)
        let context = try XCTUnwrap(AudiobookPlaybackContext(detail: detail))
        XCTAssertEqual(context.tracks.map(\.fileId), [41])
        XCTAssertEqual(context.totalDurationSeconds, 90)
        XCTAssertEqual(context.resumePositionSeconds, 25)
        XCTAssertEqual(context.chapters.first?.startSeconds, 0)
        XCTAssertEqual(context.chapters.first?.endSeconds, 90)
        XCTAssertEqual(detail.userData?.lastFileId, 41)
    }

    func testReadProjectionRejectsUnrepresentableLegacyIDs() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        for id in ["opaque-file", "0", "-1", "999999999999999999999999999999"] {
            let wire = try decoder.decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(playableDetail(fileID: id).utf8))
            XCTAssertThrowsError(try ItemDetail(catalog: wire)) { error in
                guard case APIv2Error.unsupportedCatalogReadValue = error else { return XCTFail("Unexpected \(error)") }
            }
        }
        let person = try decoder.decode(APIv2CatalogRead.Person.self, from: Data(#"{"id":"23","name":"Person"}"#.utf8))
        XCTAssertEqual(try Person(catalog: person).id, 23)
    }

    func testReadProjectionPreservesEpisodeFilesAndSeasonOrdering() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let seasons = try decoder.decode(APIv2CatalogReadCollection<APIv2CatalogRead.Season>.self, from: Data(
            #"{"items":[{"content_id":"season2","season_number":2,"title":"Two","episode_count":1},{"content_id":"specials","season_number":0,"is_specials":true,"title":"Specials","episode_count":1},{"content_id":"season1","season_number":1,"title":"One","episode_count":2}]}"#.utf8))
        let projected = try seasons.completeItems().map { try Season(catalog: $0) }
        XCTAssertEqual(projected.sortedForDisplay().map(\.seasonNumber), [0, 1, 2])

        let episodes = try decoder.decode(APIv2CatalogReadCollection<APIv2CatalogRead.Episode>.self, from: Data(
            #"{"items":[{"content_id":"ep2","season_number":1,"episode_number":2,"title":"Two","runtime":40},{"content_id":"ep1","season_number":1,"episode_number":1,"title":"One","runtime":40,"files":[{"file_id":"77","hdr":false,"file_size":1234}]}]}"#.utf8))
        let items = try episodes.completeItems().map { try EpisodeListItem(catalog: $0) }
        let downloadable = try XCTUnwrap(items.first { $0.contentId == "ep1" })
        XCTAssertEqual(downloadable.files?.first?.fileId, 77)
        XCTAssertEqual(downloadable.files?.first?.fileSize, 1234)
        XCTAssertEqual(downloadable.seasonNumber, 1)
    }

    private var detailJSON: String {
        #"{"content_id":"movie:one","type":"movie","title":"One","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[]}"#
    }

    func testCatalogDetailRequiresArraysAndKeepsMarkerKeysSeparate() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let detail = try decoder.decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(detailJSON.utf8))
        XCTAssertEqual(detail.contentId, "movie:one")
        XCTAssertTrue(detail.versions.isEmpty)
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.CatalogItemDetail.self,
            from: Data(detailJSON.replacingOccurrences(of: ",\"versions\":[]", with: "").utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        let marker = try decoder.decode(APIv2CatalogRead.Marker.self, from: Data(#"{"start":12.5,"end":25}"#.utf8))
        XCTAssertEqual(marker.start, 12.5)
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.Marker.self,
            from: Data(#"{"start_seconds":12.5,"end_seconds":25}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    func testCatalogReadIDsAreStrictStringsAndInstantsAreDates() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let file = #"{"file_id":"opaque-file","resolution":"2160p","codec_video":"hevc","codec_audio":"aac","hdr":false,"container":"mkv","file_size":123,"duration":90,"bitrate":12,"added_at":"2026-09-05T12:00:00.123Z"}"#
        let value = try decoder.decode(APIv2CatalogRead.FileVersion.self, from: Data(file.utf8))
        XCTAssertEqual(value.fileId, "opaque-file")
        XCTAssertEqual(value.addedAt.timeIntervalSince1970, 1788609600.123, accuracy: 0.001)
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.FileVersion.self,
            from: Data(file.replacingOccurrences(of: "\"opaque-file\"", with: "123").utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.Person.self, from: Data(#"{"id":123,"name":"Person"}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        let rollup = #"{"last_file_id":"opaque-file","watched_count":1,"unplayed_count":2,"in_progress_count":0,"played":false}"#
        XCTAssertEqual(try decoder.decode(APIv2CatalogRead.WatchRollup.self, from: Data(rollup.utf8)).lastFileId, "opaque-file")
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.WatchRollup.self,
            from: Data(rollup.replacingOccurrences(of: "\"opaque-file\"", with: "123").utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        let parts = #"{"variant_id":"variant","part_count":1,"default_file_id":"file","parts":[{"part_index":1,"default_file_id":"part-file","versions":[]}]}"#
        let variant = try decoder.decode(APIv2CatalogRead.PlaybackVariant.self, from: Data(parts.utf8))
        XCTAssertEqual(variant.parts.first?.defaultFileId, "part-file")
    }

    func testFiniteCatalogReadsAcceptMissingPageButRejectPartialHierarchy() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        typealias People = APIv2CatalogReadCollection<APIv2CatalogRead.Person>
        let finite = try decoder.decode(People.self, from: Data(#"{"items":[{"id":"person","name":"Name"}]}"#.utf8))
        XCTAssertEqual(try finite.completeItems().first?.id, "person")
        XCTAssertThrowsError(try decoder.decode(People.self, from: Data(#"{"people":[]}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        for page in [#"{"has_more":true,"next_cursor":"next"}"#, #"{"has_more":false,"next_cursor":"next"}"#] {
            let partial = try decoder.decode(People.self, from: Data("{\"items\":[],\"page\":\(page)}".utf8))
            XCTAssertThrowsError(try partial.completeItems()) { error in
                guard case APIv2Error.incompleteCatalogRead = error else { return XCTFail("Unexpected \(error)") }
            }
        }
        XCTAssertTrue(try decoder.decode(People.self, from: Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)).completeItems().isEmpty)
    }

    // MARK: Catalog reads

    func testCatalogReadPathsScopesAndFiniteEnvelopes() async throws {
        let (api, _) = try await client()
        stub.reply(200, detailJSON)
        _ = try await api.catalogItem(id: "movie:one/two", libraryId: "library", fileId: "file", imageSize: "small")
        stub.reply(200, #"{"items":[]}"#)
        _ = try await api.catalogSeasons(seriesId: "series", libraryId: "library", imageSize: "small")
        _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: 0, libraryId: "library", imageSize: "small")
        stub.reply(200, #"{"id":"opaque-person","name":"Person"}"#)
        _ = try await api.catalogPerson(id: "opaque-person")
        let calls = stub.requests
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(try XCTUnwrap(calls[0].url).absoluteString.contains("movie:one%2Ftwo"))
        XCTAssertEqual(calls[1].path, "/api/v2/catalog/series/series/seasons")
        XCTAssertEqual(calls[2].path, "/api/v2/catalog/series/series/seasons/0/episodes")
        XCTAssertEqual(calls[3].path, "/api/v2/catalog/people/opaque-person")
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(call.method, "GET")
            XCTAssertEqual(call.header("x-profile-id"), "profile-one")
            XCTAssertNil(call.query["cursor"])
            XCTAssertNil(call.query["offset"])
            if index < 3 { XCTAssertEqual(call.query["library_id"], "library"); XCTAssertEqual(call.query["image_size"], "small") }
            if index == 0 { XCTAssertEqual(call.query["file_id"], "file") }
        }
    }

    func testCatalogReadRejectsInvalidInputsAndProblemDoesNotRetry() async throws {
        let (api, _) = try await client()
        do { _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: -1); XCTFail("Expected invalid season") }
        catch APIv2Error.invalidCatalogQuery { }
        do { _ = try await api.catalogItem(id: ".."); XCTFail("Expected invalid segment") }
        catch APIv2Error.invalidCatalogQuery { }
        do { _ = try await api.catalogPerson(id: ""); XCTFail("Expected invalid segment") }
        catch APIv2Error.invalidCatalogQuery { }
        XCTAssertTrue(stub.requests.isEmpty)
        stub.reply(404, #"{"type":"about:blank","title":"Missing","status":404,"detail":"No item","code":"not_found"}"#)
        do { _ = try await api.catalogItem(id: "missing"); XCTFail("Expected problem") }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 404) }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testCatalogReadGateBlocksDispatch() async throws {
        let (api, _) = try await client(updateRequired: true)
        do { _ = try await api.catalogSeasons(seriesId: "series"); XCTFail("Expected gate") }
        catch APIv2Error.serverUpdateRequired { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testSearchCapabilitiesAreFencedOnTheCapturedOwner() async throws {
        let (api, tokens) = try await client()
        stub.reply(200, #"{"revision":"one","state":"ready","provider":"search","allowed":true}"#)
        let capabilities = try await api.catalogSearchCapabilities()
        XCTAssertEqual(capabilities.allowed, true)
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        await tokens.setProfileToken("replacement")
        do {
            _ = try await api.catalogSearchCapabilities(auth: auth)
            XCTFail("a supplied owner that is no longer current cannot read capabilities")
        } catch HTTPError.authorityChanged { }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/catalog/search/capabilities"])
    }

    // MARK: Page grammar

    func testStrictPageRejectsLegacyAndMalformedEnvelopes() throws {
        for body in [
            #"{"items":[],"has_more":false,"total":0,"total_exact":true,"snapshot":"old"}"#,
            #"{"page":{"has_more":false},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[],"page":{},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[{"collection_id":"c","media_item_id":"m"}],"page":{"has_more":false},"total":1,"total_exact":true,"window_cursor":"w"}"#,
        ] {
            XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8))) { error in
                XCTAssertTrue(error is DecodingError, "\(body): \(error)")
            }
        }
    }

    func testGETSignedSortAndStructuredGroupsHaveNoLegacyPagination() throws {
        var query = APIv2CatalogQuery()
        query.libraryId = "opaque-library"
        query.sort = "year"
        query.order = "desc"
        query.skipTotal = true
        query.groups = [.init(match: "any", rules: [
            .init(field: "year", op: "between", value: .numbers([1990, 1999])),
            .init(field: "genre", op: "contains", value: .string("Science Fiction")),
        ])]
        let parameters = try query.getParameters()
        XCTAssertEqual(parameters["sort"], "-year")
        XCTAssertEqual(parameters["library_id"], "opaque-library")
        XCTAssertEqual(parameters["skip_total"], "true")
        for key in ["offset", "snapshot_at", "order", "include_total"] { XCTAssertNil(parameters[key]) }
        XCTAssertFalse(parameters.keys.contains { $0.hasPrefix("groups[") })
        let data = Data(try XCTUnwrap(parameters["groups"]).utf8)
        let groups = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let rules = try XCTUnwrap(groups.first?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["value"] as? [Int], [1990, 1999])
        XCTAssertEqual(rules[1]["value"] as? String, "Science Fiction")
        XCTAssertNil(try APIv2CatalogQuery().getParameters()["sort"], "No override preserves source order")
    }

    func testPOSTBodyUsesTypedValuesAndCursorWhileRetainingOperation() async throws {
        stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque"},"total":42,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.sort = "year"
        query.order = "desc"
        query.imageSize = "small"
        query.groups = [.init(match: "all", rules: [.init(field: "watched", op: "is", value: .bool(true))])]
        let first = try await api.catalogPage(query: query, operation: .query)
        stub.reply(200, terminal)
        _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        let calls = stub.requests
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertEqual(call.method, "POST")
            XCTAssertEqual(call.path, "/api/v2/catalog/query")
            XCTAssertEqual(call.header("x-profile-id"), "profile-one")
            XCTAssertEqual(call.query["image_size"], "small")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(call.body)) as? [String: Any])
            XCTAssertEqual(body["sort"] as? String, "year")
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertNil(body["image_size"])
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[1].body)) as? [String: Any])
        XCTAssertEqual(body["cursor"] as? String, "opaque")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        let rules = try XCTUnwrap(groups[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["value"] as? Bool, true)
    }

    func testGETContinuationPinsScopeAndRejectsProfileChangeBeforeDispatch() async throws {
        stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, tokens) = try await client()
        var query = APIv2CatalogQuery()
        query.source = "library_collection"
        query.collectionId = "c1"
        query.limit = 40
        let first = try await api.catalogPage(query: query)
        let continuation = try XCTUnwrap(first.continuation)
        XCTAssertEqual(continuation.query, query)
        await tokens.setProfileId("profile-two")
        do {
            _ = try await api.nextCatalogPage(continuation)
            XCTFail("Expected captured identity rejection")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testGETCursorDispatchRetainsScopeAndOmittedSort() async throws {
        stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque-next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.source = "library_collection"
        query.collectionId = "collection-one"
        query.libraryId = "library-one"
        query.limit = 40
        let first = try await api.catalogPage(query: query)
        stub.reply(200, terminal)
        let last = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        XCTAssertNil(last.continuation)
        let calls = stub.requests
        XCTAssertEqual(calls.count, 2)
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(call.method, "GET")
            XCTAssertEqual(call.path, "/api/v2/catalog")
            XCTAssertEqual(call.query["source"], "library_collection")
            XCTAssertEqual(call.query["collection_id"], "collection-one")
            XCTAssertEqual(call.query["library_id"], "library-one")
            XCTAssertEqual(call.query["limit"], "40")
            XCTAssertNil(call.query["sort"])
            XCTAssertNil(call.query["offset"])
            if index == 0 { XCTAssertNil(call.query["cursor"]) }
            else { XCTAssertEqual(call.query["cursor"], "opaque-next") }
        }
    }

    func testContinuationRejectsChangedAccountBeforeDispatch() async throws {
        stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, tokens) = try await client()
        let first = try await api.catalogPage(query: .init())
        await tokens.switchActiveServer(serverId: "another-server")
        do {
            _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("Expected captured account rejection")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testMissingAndRepeatedCursorsFailWithoutReturningPartialPage() async throws {
        let (api, _) = try await client()
        stub.reply(200, #"{"items":[],"page":{"has_more":true},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected missing cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        stub.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"same"},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        let first = try await api.catalogPage(query: .init())
        do { _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation)); XCTFail("Expected repeated cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testExpiredCursorProblemRequiresExplicitRestart() async throws {
        stub.reply(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Invalid cursor","status":400,"detail":"Ranking expired; restart.","instance":"urn:test"}"#)
        let (api, _) = try await client()
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected cursor problem") }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 400) }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testNestedFacetsAndStringLibraryIdentifier() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let facets = try decoder.decode(APIv2CatalogFilters.self, from: Data(#"{"genres":[],"studios":[],"networks":[],"countries":[],"content_ratings":[],"original_languages":[],"authors":[],"narrators":[],"series":[],"technical":{"resolutions":["4K"],"audio_languages":["en"],"subtitle_languages":[]}}"#.utf8))
        XCTAssertEqual(facets.technical?.resolutions, ["4K"])
        let tab = try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"opaque-library","collections":[],"groups":[]}"#.utf8))
        XCTAssertEqual(tab.libraryId, "opaque-library")
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":42,"collections":[],"groups":[]}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"42","collections":[]}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    func testSearchWindowIsNotGlobalTotalAndInstantDecodes() throws {
        let body = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"w","search_diagnostics":{"provider":"future-provider","mode":"hybrid","semantic_used":true,"result_window_limit":250,"session_expires_at":"2026-09-05T20:00:00.000Z"},"effective_sort":{"field":"title","order":"asc"}}"#
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8))
        XCTAssertEqual(page.total, 10000)
        XCTAssertFalse(page.totalExact)
        XCTAssertEqual(page.searchDiagnostics?.resultWindowLimit, 250)
        XCTAssertNotNil(page.searchDiagnostics?.sessionExpiresAt)
        XCTAssertEqual(page.effectiveSort?.field, "title")
    }

    func testPageLimitAndOversizedGETRejectBeforeTransport() async throws {
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.limit = 101
        do { _ = try await api.catalogPage(query: query); XCTFail("Expected invalid limit") }
        catch APIv2Error.invalidCatalogQuery { }
        query.limit = 50
        query.groups = [.init(match: "all", rules: [.init(field: "title", op: "contains", value: .string(String(repeating: "x", count: 32769)))])]
        do { _ = try await api.catalogPage(query: query); XCTFail("Expected oversized GET rejection") }
        catch APIv2Error.invalidCatalogQuery { }
        XCTAssertTrue(stub.requests.isEmpty)
    }
}
