import Foundation
import XCTest
@testable import Silo

final class CatalogV2Tests: XCTestCase {
    private let terminal = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"window"}"#

    private func client(updateRequired: Bool = false) async throws -> (APIv2Client, TokenStore) {
        let name = "CatalogV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); CatalogProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { updateRequired }), tokens)
    }

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

    func testReadFacadePreservesAudioFilesChaptersAndResume() async throws {
        let (api, tokens) = try await client()
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        CatalogProtocol.reply(200, try playableDetail())
        let detail = try await facade.itemDetail(contentId: "book")
        let context = try XCTUnwrap(AudiobookPlaybackContext(detail: detail))
        XCTAssertEqual(context.tracks.map(\.fileId), [41])
        XCTAssertEqual(context.totalDurationSeconds, 90)
        XCTAssertEqual(context.resumePositionSeconds, 25)
        XCTAssertEqual(context.chapters.first?.startSeconds, 0)
        XCTAssertEqual(context.chapters.first?.endSeconds, 90)
        XCTAssertEqual(detail.userData?.lastFileId, 41)
        XCTAssertEqual(CatalogProtocol.requests().first?.0.url?.path, "/api/v2/catalog/items/book")
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

    private func hierarchyReplies() {
        CatalogProtocol.reply(path: "/api/v2/catalog/series/series/seasons", 200,
            #"{"items":[{"content_id":"season2","season_number":2,"title":"Two","episode_count":1},{"content_id":"specials","season_number":0,"is_specials":true,"title":"Specials","episode_count":1},{"content_id":"season1","season_number":1,"title":"One","episode_count":2}]}"#)
        CatalogProtocol.reply(path: "/api/v2/catalog/series/series/seasons/1/episodes", 200,
            #"{"items":[{"content_id":"ep2","season_number":1,"episode_number":2,"title":"Two","runtime":40},{"content_id":"ep1","season_number":1,"episode_number":1,"title":"One","runtime":40,"files":[{"file_id":"77","hdr":false,"file_size":1234}]}]}"#)
        CatalogProtocol.reply(path: "/api/v2/catalog/series/series/seasons/2/episodes", 200,
            #"{"items":[{"content_id":"ep3","season_number":2,"episode_number":1,"title":"Three","runtime":40}]}"#)
    }

    func testReadFacadePreservesDownloadEpisodeFilesAndSeasonOrdering() async throws {
        let (api, tokens) = try await client()
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        hierarchyReplies()
        let seasons = try await facade.seasons(seriesId: "series")
        XCTAssertEqual(seasons.seasons.sortedForDisplay().map(\.seasonNumber), [0, 1, 2])
        let episodes = try await facade.episodes(seriesId: "series", seasonNumber: 1)
        let downloadable = try XCTUnwrap(episodes.episodes.first { $0.contentId == "ep1" })
        XCTAssertEqual(downloadable.files?.first?.fileId, 77)
        XCTAssertEqual(downloadable.files?.first?.fileSize, 1234)
        XCTAssertEqual(downloadable.seasonNumber, 1)
    }

    func testNextUpUsesV2HierarchyForSameAndNextSeason() async throws {
        let (api, tokens) = try await client()
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        hierarchyReplies()
        let next = try await PlayerNextUpEpisode.resolve(contentId: "ep1", seriesId: "series", seriesTitle: "Series",
            seasonNumber: 1, episodeNumber: 1, api: facade)
        XCTAssertEqual(next?.contentId, "ep2")
        let rollover = try await PlayerNextUpEpisode.resolve(contentId: "ep2", seriesId: "series", seriesTitle: "Series",
            seasonNumber: 1, episodeNumber: 2, api: facade)
        XCTAssertEqual(rollover?.contentId, "ep3")
        XCTAssertFalse(CatalogProtocol.requests().contains { $0.0.url!.path.contains("/seasons/0/episodes") })
    }

    func testNextUpRefusesPartialCurrentSeason() async throws {
        let (api, tokens) = try await client()
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        hierarchyReplies()
        CatalogProtocol.reply(path: "/api/v2/catalog/series/series/seasons/1/episodes", 200,
            #"{"items":[],"page":{"has_more":true,"next_cursor":"unsupported"}}"#)
        do {
            _ = try await PlayerNextUpEpisode.resolve(contentId: "ep1", seriesId: "series", seriesTitle: nil,
                seasonNumber: 1, episodeNumber: 1, api: facade)
            XCTFail("Expected incomplete hierarchy")
        } catch APIv2Error.incompleteCatalogRead { }
    }

    func testMetadataReadPoolRejectsPriorViewerAndRefetches() async throws {
        let (api, tokens) = try await client()
        let pool = MetadataRequestPool(api: SiloAPI(tokenStore: tokens, v2: api), tokenStore: tokens)
        CatalogProtocol.reply(200, try playableDetail())
        let received = expectation(description: "metadata request captured")
        CatalogProtocol.hold { received.fulfill() }
        let request = Task { try await pool.itemDetail(contentId: "book") }
        await fulfillment(of: [received], timeout: 2)
        await tokens.setProfileId("new-profile")
        CatalogProtocol.release()
        do { _ = try await request.value; XCTFail("Expected changed viewer") }
        catch HTTPError.requestIdentityChanged { }
        let fresh = try await pool.itemDetail(contentId: "book")
        XCTAssertEqual(fresh.versions?.first?.fileId, 41)
        XCTAssertEqual(CatalogProtocol.requests().count, 2)
        XCTAssertEqual(CatalogProtocol.requests().last?.0.value(forHTTPHeaderField: "X-Profile-Id"), "new-profile")
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
            from: Data(detailJSON.replacingOccurrences(of: ",\"versions\":[]", with: "").utf8)))
        let marker = try decoder.decode(APIv2CatalogRead.Marker.self, from: Data(#"{"start":12.5,"end":25}"#.utf8))
        XCTAssertEqual(marker.start, 12.5)
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.Marker.self,
            from: Data(#"{"start_seconds":12.5,"end_seconds":25}"#.utf8)))
    }

    func testCatalogReadIDsAreStrictStringsAndInstantsAreDates() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let file = #"{"file_id":"opaque-file","resolution":"2160p","codec_video":"hevc","codec_audio":"aac","hdr":false,"container":"mkv","file_size":123,"duration":90,"bitrate":12,"added_at":"2026-09-05T12:00:00.123Z"}"#
        let value = try decoder.decode(APIv2CatalogRead.FileVersion.self, from: Data(file.utf8))
        XCTAssertEqual(value.fileId, "opaque-file")
        XCTAssertEqual(value.addedAt.timeIntervalSince1970, 1788609600.123, accuracy: 0.001)
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.FileVersion.self,
            from: Data(file.replacingOccurrences(of: "\"opaque-file\"", with: "123").utf8)))
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.Person.self, from: Data(#"{"id":123,"name":"Person"}"#.utf8)))
        let rollup = #"{"last_file_id":"opaque-file","watched_count":1,"unplayed_count":2,"in_progress_count":0,"played":false}"#
        XCTAssertEqual(try decoder.decode(APIv2CatalogRead.WatchRollup.self, from: Data(rollup.utf8)).lastFileId, "opaque-file")
        XCTAssertThrowsError(try decoder.decode(APIv2CatalogRead.WatchRollup.self,
            from: Data(rollup.replacingOccurrences(of: "\"opaque-file\"", with: "123").utf8)))
        let parts = #"{"variant_id":"variant","part_count":1,"default_file_id":"file","parts":[{"part_index":1,"default_file_id":"part-file","versions":[]}]}"#
        let variant = try decoder.decode(APIv2CatalogRead.PlaybackVariant.self, from: Data(parts.utf8))
        XCTAssertEqual(variant.parts.first?.defaultFileId, "part-file")
    }

    func testFiniteCatalogReadsAcceptMissingPageButRejectPartialHierarchy() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        typealias People = APIv2CatalogReadCollection<APIv2CatalogRead.Person>
        let finite = try decoder.decode(People.self, from: Data(#"{"items":[{"id":"person","name":"Name"}]}"#.utf8))
        XCTAssertEqual(try finite.completeItems().first?.id, "person")
        XCTAssertThrowsError(try decoder.decode(People.self, from: Data(#"{"people":[]}"#.utf8)))
        for page in [#"{"has_more":true,"next_cursor":"next"}"#, #"{"has_more":false,"next_cursor":"next"}"#] {
            let partial = try decoder.decode(People.self, from: Data("{\"items\":[],\"page\":\(page)}".utf8))
            XCTAssertThrowsError(try partial.completeItems())
        }
        XCTAssertTrue(try decoder.decode(People.self, from: Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)).completeItems().isEmpty)
    }

    func testCatalogReadPathsScopesAndFiniteEnvelopes() async throws {
        let (api, _) = try await client()
        CatalogProtocol.reply(200, detailJSON)
        _ = try await api.catalogItem(id: "movie:one/two", libraryId: "library", fileId: "file", imageSize: "small")
        CatalogProtocol.reply(200, #"{"items":[]}"#)
        _ = try await api.catalogSeasons(seriesId: "series", libraryId: "library", imageSize: "small")
        _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: 0, libraryId: "library", imageSize: "small")
        _ = try await api.catalogPeople(query: "Some Person", limit: 25)
        CatalogProtocol.reply(200, #"{"id":"opaque-person","name":"Person"}"#)
        _ = try await api.catalogPerson(id: "opaque-person")
        let calls = CatalogProtocol.requests()
        XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls[0].0.url!.absoluteString.contains("movie:one%2Ftwo"))
        XCTAssertEqual(calls[1].0.url?.path, "/api/v2/catalog/series/series/seasons")
        XCTAssertEqual(calls[2].0.url?.path, "/api/v2/catalog/series/series/seasons/0/episodes")
        XCTAssertEqual(calls[3].0.url?.path, "/api/v2/catalog/people")
        XCTAssertEqual(calls[4].0.url?.path, "/api/v2/catalog/people/opaque-person")
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(call.0.httpMethod, "GET")
            XCTAssertEqual(call.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile-one")
            let items = URLComponents(url: call.0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
            XCTAssertNil(query["cursor"])
            XCTAssertNil(query["offset"])
            if index < 3 { XCTAssertEqual(query["library_id"], "library"); XCTAssertEqual(query["image_size"], "small") }
            if index == 0 { XCTAssertEqual(query["file_id"], "file") }
            if index == 3 { XCTAssertEqual(query["q"], "Some Person"); XCTAssertEqual(query["limit"], "25") }
        }
    }

    func testCatalogReadRejectsInvalidInputsAndProblemDoesNotRetry() async throws {
        let (api, _) = try await client()
        do { _ = try await api.catalogPeople(query: "", limit: 101); XCTFail("Expected invalid limit") }
        catch APIv2Error.invalidCatalogQuery { }
        do { _ = try await api.catalogEpisodes(seriesId: "series", seasonNumber: -1); XCTFail("Expected invalid season") }
        catch APIv2Error.invalidCatalogQuery { }
        XCTAssertTrue(CatalogProtocol.requests().isEmpty)
        CatalogProtocol.reply(404, #"{"type":"about:blank","title":"Missing","status":404,"detail":"No item","code":"not_found"}"#)
        do { _ = try await api.catalogItem(id: "missing"); XCTFail("Expected problem") }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 404) }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testCatalogReadGateBlocksDispatch() async throws {
        let (api, _) = try await client(updateRequired: true)
        do { _ = try await api.catalogSeasons(seriesId: "series"); XCTFail("Expected gate") }
        catch APIv2Error.serverUpdateRequired { }
        XCTAssertTrue(CatalogProtocol.requests().isEmpty)
    }

    func testCatalogReadRejectsAccountChangeBeforePublishing() async throws {
        let (api, tokens) = try await client()
        CatalogProtocol.reply(200, detailJSON)
        let received = expectation(description: "request captured")
        CatalogProtocol.hold { received.fulfill() }
        let request = Task { try await api.catalogItem(id: "one") }
        await fulfillment(of: [received], timeout: 2)
        await tokens.switchActiveServer(serverId: "another-account")
        CatalogProtocol.release()
        do { _ = try await request.value; XCTFail("Expected changed account") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testCatalogReadRejectsProfileChangeBeforePublishing() async throws {
        let (api, tokens) = try await client()
        CatalogProtocol.reply(200, detailJSON)
        let received = expectation(description: "request captured")
        CatalogProtocol.hold { received.fulfill() }
        let request = Task { try await api.catalogItem(id: "one") }
        await fulfillment(of: [received], timeout: 2)
        await tokens.setProfileId("another-profile")
        CatalogProtocol.release()
        do { _ = try await request.value; XCTFail("Expected changed viewer") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    @MainActor
    func testSearchPreservesResultsAndRequiresReloadAfterCursorFailure() async throws {
        let (api, _) = try await client()
        let model = SearchViewModel(api: api)
        model.query = "example"
        CatalogProtocol.reply(200, #"{"items":[{"content_id":"one","type":"movie","title":"One"}],"page":{"has_more":true,"next_cursor":"next"},"total":10000,"total_exact":false,"window_cursor":"w","search_diagnostics":{"provider":"search","mode":"semantic","semantic_used":true,"result_window_limit":250}}"#)
        await model.performSearch()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.countLabel, "About 10000 results")
        XCTAssertEqual(model.resultWindowLimit, 250)
        CatalogProtocol.reply(400, #"{"type":"about:blank","title":"Expired","status":400,"detail":"Reload the search","code":"invalid_cursor"}"#)
        await model.loadMore()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasMore)
        let count = CatalogProtocol.requests().count
        await model.loadMore()
        XCTAssertEqual(CatalogProtocol.requests().count, count)
        CatalogProtocol.reply(200, terminal)
        await model.performSearch(reset: true)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(CatalogProtocol.requests().count, count + 2)
    }

    @MainActor
    func testSearchCapabilityDenialPreventsCatalogDispatch() async throws {
        let (api, _) = try await client()
        CatalogProtocol.denySearch()
        let model = SearchViewModel(api: api)
        model.query = "example"
        await model.performSearch()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(CatalogProtocol.requests().map { $0.0.url!.path }, ["/api/v2/catalog/search/capabilities"])
    }

    func testStrictPageRejectsLegacyAndMalformedEnvelopes() throws {
        for body in [
            #"{"items":[],"has_more":false,"total":0,"total_exact":true,"snapshot":"old"}"#,
            #"{"page":{"has_more":false},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[],"page":{},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[{"collection_id":"c","media_item_id":"m"}],"page":{"has_more":false},"total":1,"total_exact":true,"window_cursor":"w"}"#,
        ] {
            XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8)))
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
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque"},"total":42,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.sort = "year"
        query.order = "desc"
        query.imageSize = "small"
        query.groups = [.init(match: "all", rules: [.init(field: "watched", op: "is", value: .bool(true))])]
        let first = try await api.catalogPage(query: query, operation: .query)
        CatalogProtocol.reply(200, terminal)
        _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        let calls = CatalogProtocol.requests()
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertEqual(call.0.httpMethod, "POST")
            XCTAssertEqual(call.0.url?.path, "/api/v2/catalog/query")
            XCTAssertEqual(call.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile-one")
            let parameters = URLComponents(url: call.0.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(parameters?.first { $0.name == "image_size" }?.value, "small")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(call.1)) as? [String: Any])
            XCTAssertEqual(body["sort"] as? String, "year")
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertNil(body["image_size"])
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[1].1)) as? [String: Any])
        XCTAssertEqual(body["cursor"] as? String, "opaque")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        let rules = try XCTUnwrap(groups[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["value"] as? Bool, true)
    }

    func testGETContinuationPinsScopeAndRejectsProfileChangeBeforeDispatch() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
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
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testGETCursorDispatchRetainsScopeAndOmittedSort() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque-next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.source = "library_collection"
        query.collectionId = "collection-one"
        query.libraryId = "library-one"
        query.limit = 40
        let first = try await api.catalogPage(query: query)
        CatalogProtocol.reply(200, terminal)
        let last = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        XCTAssertNil(last.continuation)
        let calls = CatalogProtocol.requests()
        XCTAssertEqual(calls.count, 2)
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(call.0.httpMethod, "GET")
            XCTAssertEqual(call.0.url?.path, "/api/v2/catalog")
            let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(call.0.url), resolvingAgainstBaseURL: false)?.queryItems)
            let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
            XCTAssertEqual(parameters["source"], "library_collection")
            XCTAssertEqual(parameters["collection_id"], "collection-one")
            XCTAssertEqual(parameters["library_id"], "library-one")
            XCTAssertEqual(parameters["limit"], "40")
            XCTAssertNil(parameters["sort"])
            XCTAssertNil(parameters["offset"])
            if index == 0 { XCTAssertNil(parameters["cursor"]) }
            else { XCTAssertEqual(parameters["cursor"], "opaque-next") }
        }
    }

    func testContinuationRejectsChangedAccountBeforeDispatch() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, tokens) = try await client()
        let first = try await api.catalogPage(query: .init())
        await tokens.switchActiveServer(serverId: "another-server")
        do {
            _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("Expected captured account rejection")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testMissingAndRepeatedCursorsFailWithoutReturningPartialPage() async throws {
        let (api, _) = try await client()
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected missing cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"same"},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        let first = try await api.catalogPage(query: .init())
        do { _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation)); XCTFail("Expected repeated cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        XCTAssertEqual(CatalogProtocol.requests().count, 3)
    }

    func testExpiredCursorProblemRequiresExplicitRestart() async throws {
        CatalogProtocol.reply(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Invalid cursor","status":400,"detail":"Ranking expired; restart.","instance":"urn:test"}"#)
        let (api, _) = try await client()
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected cursor problem") }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 400) }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testNestedFacetsAndStringLibraryIdentifier() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let facets = try decoder.decode(APIv2CatalogFilters.self, from: Data(#"{"genres":[],"studios":[],"networks":[],"countries":[],"content_ratings":[],"original_languages":[],"authors":[],"narrators":[],"series":[],"technical":{"resolutions":["4K"],"audio_languages":["en"],"subtitle_languages":[]}}"#.utf8))
        XCTAssertEqual(facets.technical?.resolutions, ["4K"])
        let tab = try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"opaque-library","collections":[],"groups":[]}"#.utf8))
        XCTAssertEqual(tab.libraryId, "opaque-library")
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":42,"collections":[],"groups":[]}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"42","collections":[]}"#.utf8)))
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
        XCTAssertTrue(CatalogProtocol.requests().isEmpty)
    }
}

final class CatalogProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, "{}")
    nonisolated(unsafe) private static var routes: [String: (Int, String)] = [:]
    static func reply(path: String, _ status: Int, _ body: String) { lock.withLock { routes[path] = (status, body) } }
    nonisolated(unsafe) private static var searchAllowed = true
    nonisolated(unsafe) private static var onHeldRequest: (() -> Void)?
    nonisolated(unsafe) private static var pending: (() -> Void)?
    static func hold(_ notify: @escaping () -> Void) { lock.withLock { onHeldRequest = notify } }
    static func release() {
        let deliver = lock.withLock { let value = pending; pending = nil; onHeldRequest = nil; return value }
        deliver?()
    }
    static func denySearch() { lock.withLock { searchAllowed = false } }
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []
    static func reset() { lock.withLock { recorded = []; response = (200, "{}"); searchAllowed = true; onHeldRequest = nil; pending = nil; routes = [:] } }
    static func reply(_ status: Int, _ body: String) { lock.withLock { response = (status, body) } }
    static func requests() -> [(URLRequest, Data?)] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let reply = Self.lock.withLock {
            Self.recorded.append((request, data))
            if request.url?.path == "/api/v2/catalog/search/capabilities" {
                return (200, "{\"revision\":\"one\",\"state\":\"ready\",\"provider\":\"search\",\"allowed\":\(Self.searchAllowed)}")
            }
            return Self.routes[request.url!.path] ?? Self.response
        }
        let deliver: () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
            headerFields: ["Content-Type": reply.0 >= 400 ? "application/problem+json" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
        }
        let notify: (() -> Void)? = Self.lock.withLock {
            if let notify = Self.onHeldRequest { Self.pending = deliver; return notify }
            return nil
        }
        if let notify { notify() } else { deliver() }
    }

    override func stopLoading() {}
}
