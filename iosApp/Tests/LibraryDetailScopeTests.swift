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
