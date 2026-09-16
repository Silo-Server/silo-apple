import Foundation
import XCTest
@testable import Silo

final class LibraryDetailScopeTests: XCTestCase {
    private let detailJSON = #"{"content_id":"movie","type":"movie","title":"Movie","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[]}"#
    private let watchJSON = #"{"content_id":"movie","type":"movie","title":"Movie","versions":[],"subtitles":[]}"#

    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "LibraryDetailScopeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "scope-test")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    func testFacadeSendsLibraryOnEveryDetailReadAndOmitsItForGlobalReads() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/catalog/items/movie", 200, detailJSON)
        stub.reply(path: "/api/v2/catalog/series/series/seasons", 200, #"{"items":[]}"#)
        stub.reply(path: "/api/v2/catalog/series/series/seasons/0/episodes", 200, #"{"items":[]}"#)
        stub.reply(path: "/api/v2/watch/movie", 200, watchJSON)
        for libraryId: Int? in [7, 8, nil] {
            _ = try await api.itemDetail(contentId: "movie", libraryId: libraryId)
            _ = try await api.seasons(seriesId: "series", libraryId: libraryId)
            _ = try await api.episodes(seriesId: "series", seasonNumber: 0, libraryId: libraryId)
            _ = try await api.watchDetail(contentId: "movie", libraryId: libraryId)
        }
        XCTAssertEqual(stub.requests.count, 12)
        for (index, request) in stub.requests.enumerated() {
            XCTAssertEqual(request.query["library_id"], ["7", "8", nil][index / 4])
            XCTAssertTrue(request.path.hasPrefix("/api/v2/"))
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testVersionListsFollowServerResponseAndDeniedScopeDoesNotFallBack() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        let first = #"{"file_id":"71","resolution":"2160p","codec_video":"hevc","codec_audio":"aac","hdr":false,"container":"mkv","file_size":123,"duration":90,"bitrate":12,"added_at":"2026-09-05T12:00:00.123Z"}"#
        let second = first.replacingOccurrences(of: "71", with: "81")
        for versions in [[first], [first, second]] {
            // The same scope can return one or all versions as the server setting changes.
            let body = detailJSON.replacingOccurrences(of: #""versions":[]"#, with: #""versions":[\#(versions.joined(separator: ","))]"#)
            stub.reply(200, body)
            let detail = try await api.itemDetail(contentId: "movie", libraryId: 7)
            XCTAssertEqual((detail.versions ?? []).map(\.fileId), versions.count == 1 ? [71] : [71, 81])
            let watchBody = watchJSON.replacingOccurrences(of: #""versions":[]"#, with: #""versions":[\#(versions.joined(separator: ","))]"#)
                .replacingOccurrences(of: #""duration":"#, with: #""duration_seconds":"#)
            stub.reply(200, watchBody)
            let watch = try await api.watchDetail(contentId: "movie", libraryId: 7)
            XCTAssertEqual(watch.versions.map(\.fileId), (detail.versions ?? []).map(\.fileId))
        }
        let before = stub.requests.count
        stub.reply(403, #"{"type":"about:blank","title":"Forbidden","status":403}"#)
        do {
            _ = try await api.itemDetail(contentId: "movie", libraryId: 8)
            XCTFail("A rejected library must remain rejected")
        } catch { }
        XCTAssertEqual(stub.requests.count, before + 1)
        XCTAssertEqual(stub.requests.last?.query["library_id"], "8")
    }

    func testScopedReadDoesNotJoinAnActiveHomeWarmup() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        let pool = MetadataRequestPool(api: api, tokenStore: tokens)
        stub.reply(200, detailJSON)
        stub.hold()
        let home = Task { try await pool.itemDetail(contentId: "movie") }
        await stub.waitUntilHeld()
        // This must finish while the unscoped request is still parked.
        let scoped = try await pool.itemDetail(contentId: "movie", libraryId: 7)
        XCTAssertEqual(scoped.contentId, "movie")
        stub.release()
        _ = try await home.value
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertNil(stub.requests[0].query["library_id"])
        XCTAssertEqual(stub.requests[1].query["library_id"], "7")
    }

    @MainActor
    func testAudioPreparationReadsTheSelectedLibraryAndGlobalEntryClearsIt() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(200, detailJSON)
        let player = AudioPlayerViewModel(api: api)
        for libraryId: Int? in [7, 8, nil] {
            // An item without audio files ends preparation after the real
            // catalog read, before any playback session can be created.
            await player.start(contentId: "movie", libraryId: libraryId)
            XCTAssertNotNil(player.error)
        }
        await player.close()
        XCTAssertEqual(stub.requests.map { $0.query["library_id"] }, ["7", "8", nil])
    }

    @MainActor
    func testHydrationAndInvalidationRespectLibraryPresentations() throws {
        let cache = ResponseCache.shared
        let id = "scope-test-\(UUID().uuidString)"
        defer { cache.removeItemMetadata(contentId: id) }
        for libraryId: Int? in [nil, 7, 8] {
            let label = libraryId.map(String.init) ?? "global"
            let json = #"{"contentId":"\#(id)","type":"movie","title":"\#(label)"}"#
            let item = try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
            cache.set(item, for: CacheKey.itemDetail(id, libraryId: libraryId))
        }
        for libraryId: Int? in [nil, 7, 8, 9] {
            let model = ItemDetailViewModel(libraryId: libraryId)
            model.hydrateFromCache(contentId: id)
            XCTAssertEqual(model.detail?.title, libraryId == 9 ? nil : libraryId.map(String.init) ?? "global")
        }
        cache.removeItemMetadata(contentId: id)
        for libraryId: Int? in [nil, 7, 8] {
            let cached: ItemDetail? = cache.get(CacheKey.itemDetail(id, libraryId: libraryId))
            XCTAssertNil(cached)
        }
    }

    @MainActor
    func testOpaqueIDsCannotCollideWithScopeOrHierarchySuffixes() {
        let cache = ResponseCache.shared
        let id = UUID().uuidString
        let distinctKeys = [
            CacheKey.itemDetail(id, libraryId: 7),
            CacheKey.itemDetail(id + ":library:7"),
            CacheKey.itemDetail(id + "%3Alibrary%3A7"),
            CacheKey.itemDetail(id + ":seasons"),
            CacheKey.itemSeasons(id),
            CacheKey.itemDetail(id + ":userState"),
            CacheKey.itemUserState(id),
            CacheKey.itemDetail(id + ":similar"),
            CacheKey.similar(id),
        ]
        XCTAssertEqual(Set(distinctKeys).count, distinctKeys.count)
        defer { for key in distinctKeys { cache.remove(key) } }
        for (index, key) in distinctKeys.enumerated() { cache.set(index, for: key) }
        for (index, key) in distinctKeys.enumerated() {
            let value: Int? = cache.get(key)
            XCTAssertEqual(value, index)
        }
        cache.removeItemMetadata(contentId: id)
        for index in [1, 2, 3, 5, 7] {
            let value: Int? = cache.get(distinctKeys[index])
            XCTAssertEqual(value, index, "Invalidation must preserve another opaque item")
        }
        for index in [0, 4, 6, 8] {
            let value: Int? = cache.get(distinctKeys[index])
            XCTAssertNil(value)
        }
    }

    @MainActor
    func testAutoplayHierarchyReadsRetainTheCurrentLibrary() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/catalog/series/series/seasons", 200,
            #"{"items":[{"content_id":"season-1","season_number":1,"title":"One","episode_count":1},{"content_id":"season-2","season_number":2,"title":"Two","episode_count":1}]}"#)
        stub.reply(path: "/api/v2/catalog/series/series/seasons/1/episodes", 200,
            #"{"items":[{"content_id":"ep-1","season_number":1,"episode_number":1,"title":"One","runtime":40}]}"#)
        stub.reply(path: "/api/v2/catalog/series/series/seasons/2/episodes", 200,
            #"{"items":[{"content_id":"ep-2","season_number":2,"episode_number":1,"title":"Two","runtime":40}]}"#)
        let model = PlayerViewModel(libraryId: 7)
        defer { model.cleanup() }
        let next = try await model.resolveNextUpEpisode(contentId: "ep-1", seriesId: "series",
            seriesTitle: "Series", seasonNumber: 1, episodeNumber: 1, api: api)
        XCTAssertEqual(next?.contentId, "ep-2")
        XCTAssertEqual(stub.requests.count, 3)
        XCTAssertTrue(stub.requests.allSatisfy { $0.query["library_id"] == "7" })
    }

    @MainActor
    func testAutoplayAndRecoveryRetainScopeButGlobalOnDeckClearsIt() throws {
        let model = PlayerViewModel(libraryId: 7)
        defer { model.cleanup() }
        model.loadAndPlay(contentId: "ep-1", startFromBeginning: false)
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"ep-2","seasonNumber":1,"episodeNumber":2,"title":"Two"}"#.utf8))
        model.nextUpEpisode = PlayerNextUpEpisode(episode: episode, seriesId: "series", seriesTitle: "Series")
        model.playNextEpisodeNow()
        XCTAssertEqual(model.libraryId, 7)

        let global = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"other-library-movie","type":"movie","title":"Other movie"}"#.utf8))
        model.playOnDeckItemNow(PlayerOnDeckItem(item: global))
        XCTAssertNil(model.libraryId)
        model.retry()
        XCTAssertNil(model.libraryId)

        let scopedRequest = PlayerViewModel.LoadRequest(libraryId: 7, contentId: "movie", preferredFileId: 71,
            preferredAudioTrackIndex: nil, preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil, startFromBeginning: false)
        let recovery = scopedRequest.copyForRecovery(preferredFileId: 72, preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil, preferredSidecarSubtitleTrackId: nil, offlineDownloadId: nil)
        XCTAssertEqual(recovery.libraryId, 7)
    }

    #if os(iOS)
    @MainActor
    func testSheetKeepsLibraryWhenPagingAndGlobalNavigationClearsIt() throws {
        let router = AppRouter()
        let source = ItemDetailBrowseSource(originID: "library", contentIDs: ["one", "two"])
        router.presentItemDetail(contentId: "one", libraryId: 7, browseSource: source)
        router.selectPresentedItemDetail(contentId: "two")
        XCTAssertEqual(router.presentedItemDetail?.contentId, "two")
        XCTAssertEqual(router.presentedItemDetail?.libraryId, 7)
        router.dismissItemDetail()
        router.navigate(to: .itemDetail(contentId: "two"))
        XCTAssertNil(router.presentedItemDetail?.libraryId)
        router.presentPlayer(contentId: "two", libraryId: 7)
        XCTAssertEqual(router.presentedPlayer?.libraryId, 7)
        XCTAssertEqual(router.presentedPlayer?.reopened().libraryId, 7)
        router.presentPlayer(contentId: "two")
        XCTAssertNil(router.presentedPlayer?.libraryId)
        router.presentedPlayer = nil
        router.dismissItemDetail()
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTVMarqueeAndContinueWatchingHydrateTheirOwnLibrary() async throws {
        let id = "marquee-scope-\(UUID().uuidString)"
        let cache = ResponseCache.shared
        defer { cache.removeItemMetadata(contentId: id) }
        let item = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"\#(id)","type":"movie","title":"Movie"}"#.utf8))
        let store = TVContinueWatchingPlaybackMetadataStore.shared
        for libraryId: Int? in [nil, 7, 8] {
            let label = libraryId.map(String.init) ?? "global"
            let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(
                #"{"contentId":"\#(id)","type":"movie","title":"\#(label)","contentRating":"\#(label)"}"#.utf8))
            cache.set(detail, for: CacheKey.itemDetail(id, libraryId: libraryId))
        }
        // Revisit Home after both libraries to exercise the store's retained
        // same-revision values as well as its first response-cache hydration.
        for libraryId: Int? in [nil, 7, 8, nil, 7] {
            let label = libraryId.map(String.init) ?? "global"
            let model = TVFocusMarqueeModel(libraryId: libraryId)
            model.seed(TVMarqueeContent(item: item, rowTitle: "Movies"))
            XCTAssertEqual(model.enrichment?.contentRatingBadge, label.uppercased())
            model.suspend()
            let saved = await store.load(item: item, libraryId: libraryId)
            XCTAssertEqual(saved?.title, label)
        }
    }

    @MainActor
    func testTVModelCacheSeparatesLibrariesAndGlobalEntry() {
        let cache = ItemDetailCache.shared
        defer { cache.clearAll() }
        let global = cache.viewModel(for: "movie")
        let first = cache.viewModel(for: "movie", libraryId: 7)
        let second = cache.viewModel(for: "movie", libraryId: 8)
        XCTAssertFalse(global === first)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first === cache.viewModel(for: "movie", libraryId: 7))
        XCTAssertEqual(first.libraryId, 7)
        XCTAssertNil(global.libraryId)
    }
    #endif
}
