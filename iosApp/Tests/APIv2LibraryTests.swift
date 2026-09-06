import Foundation
import XCTest
@testable import Silo

@MainActor
final class APIv2LibraryTests: XCTestCase {
    private func fixture(captureBarrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore) {
        let name = "APIv2LibraryTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: defaults)
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://libraries.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryReadProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens,
            requestCaptureBarrier: { await captureBarrier?(tokens) })
        LibraryReadProtocol.reset()
        addTeardownBlock {
            suite.removePersistentDomain(forName: name)
            LibraryReadProtocol.reset()
        }
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    func testSeasonWatchedRefreshKeepsOriginalAuthority() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        do { _ = try await v2.catalogSeasons(seriesId: "series/a?b", imageSize: nil, auth: auth); XCTFail("authority rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)])
        let result = try await v2.catalogSeasons(seriesId: "series/a?b", imageSize: nil, auth: XCTUnwrap(current))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.url?.absoluteString, "https://libraries.example/api/v2/catalog/series/series%2Fa%3Fb/seasons")
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("foreign") }
        do { _ = try await v2.catalogSeasons(seriesId: "series", imageSize: nil, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
    }

    func testEpisodeWatchedRefreshKeepsOriginalAuthorityAndSeasonZero() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        do { _ = try await v2.catalogEpisodes(seriesId: "series/a?b", seasonNumber: 0, imageSize: nil, auth: auth); XCTFail("authority rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)])
        let result = try await v2.catalogEpisodes(seriesId: "series/a?b", seasonNumber: 0, imageSize: nil, auth: XCTUnwrap(current))
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.url?.absoluteString, "https://libraries.example/api/v2/catalog/series/series%2Fa%3Fb/seasons/0/episodes")
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"has_more":false}}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("foreign") }
        do { _ = try await v2.catalogEpisodes(seriesId: "series", seasonNumber: 0, imageSize: nil, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
    }

    func testHomeWatchlistReceiptInvalidationAndForeignRefusal() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let key = CacheKey.itemUserState("movie")
        defer { ResponseCache.shared.remove(key) }
        ResponseCache.shared.set(UserItemState(isFavorite: false, inWatchlist: true), for: key)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        let success = await PersonalListSync.setHomeWatchlist(contentId: "movie", inWatchlist: true, auth: auth, api: api, tokens: tokens)
        XCTAssertTrue(success)
        let cleared: UserItemState? = ResponseCache.shared.get(key)
        XCTAssertNil(cleared)
        ResponseCache.shared.set(UserItemState(isFavorite: false, inWatchlist: true), for: key)
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileToken("replacement") }
        let foreign = await PersonalListSync.setHomeWatchlist(contentId: "movie", inWatchlist: false, auth: auth, api: api, tokens: tokens)
        XCTAssertFalse(foreign)
        let retained: UserItemState? = ResponseCache.shared.get(key)
        XCTAssertEqual(retained?.inWatchlist, true)
        let count = LibraryReadProtocol.requests().count
        let stale = await PersonalListSync.setHomeWatchlist(contentId: "movie", inWatchlist: true, auth: auth, api: api, tokens: tokens)
        XCTAssertFalse(stale)
        XCTAssertEqual(LibraryReadProtocol.requests().count, count)
    }

    func testHomeFavoriteReceiptInvalidationAndForeignRefusal() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let key = CacheKey.itemUserState("movie")
        defer { ResponseCache.shared.remove(key) }
        ResponseCache.shared.set(UserItemState(isFavorite: false, inWatchlist: true), for: key)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        let success = await PersonalListSync.setHomeFavorite(contentId: "movie", isFavorite: true, auth: auth, api: api, tokens: tokens)
        XCTAssertTrue(success)
        let cleared: UserItemState? = ResponseCache.shared.get(key)
        XCTAssertNil(cleared)
        ResponseCache.shared.set(UserItemState(isFavorite: false, inWatchlist: true), for: key)
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileToken("replacement") }
        let foreign = await PersonalListSync.setHomeFavorite(contentId: "movie", isFavorite: false, auth: auth, api: api, tokens: tokens)
        XCTAssertFalse(foreign)
        let retained: UserItemState? = ResponseCache.shared.get(key)
        XCTAssertEqual(retained?.inWatchlist, true)
        let count = LibraryReadProtocol.requests().count
        let stale = await PersonalListSync.setHomeFavorite(contentId: "movie", isFavorite: true, auth: auth, api: api, tokens: tokens)
        XCTAssertFalse(stale)
        XCTAssertEqual(LibraryReadProtocol.requests().count, count)
    }

    func testDetailWatchedV2ExactIdentityMethodsAnd204() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data()])
        try await api.setWatched(contentId: "movie/a?b", played: true, auth: auth)
        try await api.setWatched(contentId: "movie/a?b", played: false, auth: auth)
        XCTAssertEqual(LibraryReadProtocol.requests().map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy {
            $0.url?.absoluteString == "https://libraries.example/api/v2/watched/movie%2Fa%3Fb"
        })
        XCTAssertTrue(LibraryReadProtocol.lastBody().isEmpty)
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(#"{}"#.utf8)])
        do { try await api.setWatched(contentId: "movie/a?b", played: true, auth: auth); XCTFail("non204") } catch {}
    }

    func testDetailWatchedV2RefusalsNeverReplayAuthentication() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        for included in [true, false] {
            for status in [401, 500] {
                LibraryReadProtocol.reset()
                LibraryReadProtocol.status = status
                LibraryReadProtocol.enqueue([Data(#"{"type":"https://silo.test/problems/refused","title":"Refused","status":401,"detail":"Synthetic refusal"}"#.utf8)])
                do { try await v2.setWatchedState(id: "movie", included: included, auth: XCTUnwrap(captured)); XCTFail("failure accepted") } catch {}
                XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
                XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.path, "/api/v2/watched/movie")
            }
        }
    }

    func testDetailWatchedV2PinsAuthorityAtCaptureAndReceipt() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        let noProfile = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setWatchedState(id: "movie", included: true, auth: XCTUnwrap(noProfile)); XCTFail("missing profile") } catch {}
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setWatchedState(id: "movie", included: true, auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await v2.setWatchedState(id: "movie", included: false, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testDetailFavoriteV2ExactIdentityMethodsAnd204() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data()])
        try await api.toggleFavorite(contentId: "movie/a?b", isFavorite: true, auth: auth)
        try await api.toggleFavorite(contentId: "movie/a?b", isFavorite: false, auth: auth)
        XCTAssertEqual(LibraryReadProtocol.requests().map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy {
            $0.url?.absoluteString == "https://libraries.example/api/v2/favorites/movie%2Fa%3Fb"
        })
        XCTAssertTrue(LibraryReadProtocol.lastBody().isEmpty)
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(#"{}"#.utf8)])
        do { try await api.toggleFavorite(contentId: "movie/a?b", isFavorite: true, auth: auth); XCTFail("non204") } catch {}
    }

    func testDetailFavoriteV2RefusalsNeverReplayAuthentication() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        for included in [true, false] {
            for status in [401, 500] {
                LibraryReadProtocol.reset()
                LibraryReadProtocol.status = status
                LibraryReadProtocol.enqueue([Data(#"{"type":"https://silo.test/problems/refused","title":"Refused","status":401,"detail":"Synthetic refusal"}"#.utf8)])
                do { try await v2.setFavoriteMembership(id: "movie", included: included, auth: XCTUnwrap(captured)); XCTFail("failure accepted") } catch {}
                XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
                XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.path, "/api/v2/favorites/movie")
            }
        }
    }

    func testDetailFavoriteV2PinsAuthorityAtCaptureAndReceipt() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        let noProfile = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setFavoriteMembership(id: "movie", included: true, auth: XCTUnwrap(noProfile)); XCTFail("missing profile") } catch {}
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setFavoriteMembership(id: "movie", included: true, auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await v2.setFavoriteMembership(id: "movie", included: false, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testDetailWatchlistV2ExactIdentityMethodsAnd204() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data()])
        try await api.toggleWatchlist(contentId: "movie/a?b", isInWatchlist: true, auth: auth)
        try await api.toggleWatchlist(contentId: "movie/a?b", isInWatchlist: false, auth: auth)
        XCTAssertEqual(LibraryReadProtocol.requests().map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy {
            $0.url?.absoluteString == "https://libraries.example/api/v2/watchlist/movie%2Fa%3Fb"
        })
        XCTAssertTrue(LibraryReadProtocol.lastBody().isEmpty)
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(#"{}"#.utf8)])
        do { try await api.toggleWatchlist(contentId: "movie/a?b", isInWatchlist: true, auth: auth); XCTFail("non204") } catch {}
    }

    func testDetailWatchlistV2RefusalsNeverReplayAuthentication() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        for included in [true, false] {
            for status in [401, 500] {
                LibraryReadProtocol.reset()
                LibraryReadProtocol.status = status
                LibraryReadProtocol.enqueue([Data(#"{"type":"https://silo.test/problems/refused","title":"Refused","status":401,"detail":"Synthetic refusal"}"#.utf8)])
                do { try await v2.setWatchlistMembership(id: "movie", included: included, auth: XCTUnwrap(captured)); XCTFail("failure accepted") } catch {}
                XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
                XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.path, "/api/v2/watchlist/movie")
            }
        }
    }

    func testDetailWatchlistV2PinsAuthorityAtCaptureAndReceipt() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        let noProfile = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setWatchlistMembership(id: "movie", included: true, auth: XCTUnwrap(noProfile)); XCTFail("missing profile") } catch {}
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.setWatchlistMembership(id: "movie", included: true, auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await v2.setWatchlistMembership(id: "movie", included: false, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testLibrarySectionsV2PreservesLibraryAndCardWire() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([homeBody])
        let read = try await v2.librarySections(id: 17, imageSize: "large", auth: XCTUnwrap(captured))
        XCTAssertEqual(read.libraryId, 17)
        XCTAssertEqual(read.sections.first?.id, "continue")
        XCTAssertEqual(read.sections.first?.totalCount, 20)
        XCTAssertEqual(read.sections.first?.items.first?.seasonNumber, 0)
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.absoluteString,
            "https://libraries.example/api/v2/library/17/sections?image_size=large")
        LibraryReadProtocol.enqueue([Data(#"{}"#.utf8)])
        do { _ = try await v2.librarySections(id: 17, imageSize: nil, auth: XCTUnwrap(captured)); XCTFail("missing sections") } catch {}
        let wrongLibrary = await StartupContentPrefetcher.librarySectionsAreCurrent(read, libraryId: 18, tokens: tokens)
        XCTAssertFalse(wrongLibrary)
    }

    func testLibrarySectionsAndWarmupPinAuthorityAtHTTPBoundary() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.librarySections(id: 17, imageSize: nil, auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        do { _ = try await v2.catalogItem(id: "series:1", imageSize: nil, auth: XCTUnwrap(captured)); XCTFail("warmup rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([homeBody])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.librarySections(id: 17, imageSize: nil, auth: XCTUnwrap(current)); XCTFail("foreign receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testLibraryModelReplacementAndForeignCacheRefusal() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.removeAll(withPrefix: "library:")
        defer {
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.removeAll(withPrefix: "library:")
        }
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let model = LibraryRecommendedViewModel(api: api, tokens: tokens)
        let arrived = expectation(description: "old library awaiting response")
        let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
        LibraryReadProtocol.enqueue([homeBody, Data(String(decoding: homeBody, as: UTF8.self).replacingOccurrences(of: "Continue", with: "New library").utf8)])
        LibraryReadProtocol.beforeNextReply { _ = await gate.check() }
        let old = Task { await model.loadSections(libraryId: 17) }
        await fulfillment(of: [arrived], timeout: 2)
        await model.loadSections(libraryId: 18)
        await gate.releaseOld(true)
        await old.value
        XCTAssertEqual(model.sections.first?.title, "New library")
        XCTAssertFalse(model.isLoading)
        let own = await StartupContentPrefetcher.cachedLibrarySections(libraryId: 18, tokens: tokens)
        XCTAssertNotNil(own)
        await tokens.setProfileToken("new")
        await model.loadSections(libraryId: 18) // Synthetic network failure cannot reuse the old PIN's rows.
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNotNil(model.error)
        let foreign = await StartupContentPrefetcher.cachedLibrarySections(libraryId: 18, tokens: tokens)
        XCTAssertNil(foreign)
    }

    func testLibraryRefreshFailureRevalidatesDisplayedOwner() async throws {
        for change in ["same", "pin", "profile"] {
            let (v2, tokens) = try await fixture()
            await tokens.setProfileId("profile")
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.removeAll(withPrefix: "library:")
            let model = LibraryRecommendedViewModel(api: SiloAPI(tokenStore: tokens, v2: v2), tokens: tokens)
            LibraryReadProtocol.enqueue([homeBody])
            await model.loadSections(libraryId: 17)
            XCTAssertFalse(model.sections.isEmpty)
            let arrived = expectation(description: "warm refresh suspended \(change)")
            let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
            LibraryReadProtocol.status = 500
            LibraryReadProtocol.enqueue([Data()])
            LibraryReadProtocol.beforeNextReply { _ = await gate.check() }
            let refresh = Task { await model.loadSections(libraryId: 17) }
            await fulfillment(of: [arrived], timeout: 2)
            XCTAssertFalse(model.sections.isEmpty)
            if change == "pin" { await tokens.setProfileToken("replacement") }
            if change == "profile" { await tokens.setProfileId("replacement") }
            await gate.releaseOld(true)
            await refresh.value
            XCTAssertEqual(model.sections.isEmpty, change != "same")
            XCTAssertEqual(model.error == nil, change == "same")
            XCTAssertFalse(model.isRefreshing)
        }
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.removeAll(withPrefix: "library:")
    }

    func testHomeDismissalV2PreservesExactAnchorsAnd204() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let auth = await tokens.captureOrdinaryRequestAuth()
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data()])
        try await api.dismissContinueWatchingItem(contentId: "episode/a?b", progressUpdatedAt: "2026-09-06T00:00:00.000Z", auth: auth)
        let progress = try JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: String]
        XCTAssertEqual(progress, ["progress_updated_at": "2026-09-06T00:00:00.000Z"])
        try await api.dismissNextUpItem(contentId: "episode/a?b", seriesId: "series:original", auth: auth)
        let next = try JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: String]
        XCTAssertEqual(next, ["series_id": "series:original"])
        XCTAssertEqual(LibraryReadProtocol.requests().map { $0.url!.absoluteString }, [
            "https://libraries.example/api/v2/home/dismissals/continue_watching/episode%2Fa%3Fb",
            "https://libraries.example/api/v2/home/dismissals/next_up/episode%2Fa%3Fb"
        ])
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy { $0.httpMethod == "PUT" })
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(#"{}"#.utf8)])
        do { try await api.dismissNextUpItem(contentId: "episode", seriesId: "series", auth: auth); XCTFail("non204") } catch {}
    }

    func testHomeDismissalPinsOriginalAuthorityAtCaptureAndReceipt() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let original = await tokens.captureOrdinaryRequestAuth()
        do { try await v2.dismissHomeItem(id: "episode", progressUpdatedAt: nil, seriesId: "series", auth: original); XCTFail("PIN rebound") } catch {}
        do { try await v2.dismissHomeItem(id: "episode", progressUpdatedAt: nil, seriesId: "series", auth: nil); XCTFail("recaptured missing owner") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await v2.dismissHomeItem(id: "episode", progressUpdatedAt: nil, seriesId: "series", auth: current); XCTFail("foreign receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testHomeDismissalReceiptCannotRemoveNewProgressObservation() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let auth = await tokens.captureOrdinaryRequestAuth()
        ResponseCache.shared.remove(CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let model = HomeViewModel(dismissContinueWatching: { id, stamp, original in
            XCTAssertEqual(original, auth)
            try await api.dismissContinueWatchingItem(contentId: id, progressUpdatedAt: stamp, auth: original)
        }, fetchHomeSections: { try await api.homeSections(auth: auth) },
            responseIsCurrent: { await StartupContentPrefetcher.homeResponseIsCurrent($0, tokens: tokens) })
        LibraryReadProtocol.enqueue([homeBody])
        await model.loadSections()
        let item = try XCTUnwrap(model.sections.first?.items.first)
        let arrived = expectation(description: "PUT awaiting receipt")
        let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { _ = await gate.check() }
        let dismiss = Task { await model.dismissContinueWatchingItem(item) }
        await fulfillment(of: [arrived], timeout: 2)
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(String(decoding: homeBody, as: UTF8.self).replacingOccurrences(of: "00:00:00.000Z", with: "00:01:00.000Z").utf8)])
        await model.loadSections()
        LibraryReadProtocol.status = 204
        await gate.releaseOld(true)
        await dismiss.value
        XCTAssertEqual(model.sections.first?.items.first?.progressUpdatedAt, "2026-09-06T00:01:00.000Z")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(LibraryReadProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testHomeDismissalCannotRemoveNewerBackgroundCacheAnchor() async throws {
        let (_, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let auth = await tokens.captureOrdinaryRequestAuth()
        ResponseCache.shared.remove(CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        var observed = try HTTPClient.makeJSONDecoder().decode(SectionsResponse.self, from: homeBody)
        observed.homeReadAuth = auth
        let item = try XCTUnwrap(observed.sections.first?.items.first)
        let arrived = expectation(description: "dismissal pending")
        let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
        let model = HomeViewModel(dismissContinueWatching: { _, _, _ in _ = await gate.check() },
            fetchHomeSections: { observed }, responseIsCurrent: { _ in true })
        await model.loadSections()
        let dismiss = Task { await model.dismissContinueWatchingItem(item) }
        await fulfillment(of: [arrived], timeout: 2)
        var newer = try HTTPClient.makeJSONDecoder().decode(SectionsResponse.self,
            from: Data(String(decoding: homeBody, as: UTF8.self).replacingOccurrences(of: "00:00:00.000Z", with: "00:02:00.000Z").utf8))
        newer.homeReadAuth = auth
        ResponseCache.shared.set(newer, for: CacheKey.homeSections)
        await gate.releaseOld(true)
        await dismiss.value
        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(cached?.sections.first?.items.first?.progressUpdatedAt, "2026-09-06T00:02:00.000Z")
        XCTAssertTrue(model.sections.first?.items.isEmpty == true)
        XCTAssertNil(model.actionError)
    }

    private var homeBody: Data {
        Data(#"{"sections":[{"id":"continue","section_type":"continue_watching","title":"Continue","featured":false,"item_limit":12,"total_count":20,"is_custom":false,"customized":false,"items":[{"content_id":"episode:1","type":"episode","title":"One","series_id":"series:1","season_number":0,"episode_number":1,"position_seconds":25,"duration_seconds":100,"progress_updated_at":"2026-09-06T00:00:00.000Z"}]}]}"#.utf8)
    }

    func testHomeV2PreservesSectionsAndPinsAuthority() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.homeSections(imageSize: "medium", auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([homeBody])
        let response = try await v2.homeSections(imageSize: "medium", auth: XCTUnwrap(current))
        XCTAssertEqual(response.sections.first?.totalCount, 20)
        XCTAssertEqual(response.sections.first?.items.first?.seasonNumber, 0)
        XCTAssertEqual(response.sections.first?.items.first?.progressUpdatedAt, "2026-09-06T00:00:00.000Z")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.absoluteString,
            "https://libraries.example/api/v2/home/sections?image_size=medium")
        let encoded = try JSONEncoder().encode(response)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("homeReadAuth"))
        LibraryReadProtocol.enqueue([homeBody])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.homeSections(imageSize: nil, auth: XCTUnwrap(current)); XCTFail("foreign reply") } catch {}
    }

    func testHomePrefetchInvalidationRefusesLateCacheAndForeignOwner() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.remove(CacheKey.homeSections)
        defer {
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.remove(CacheKey.homeSections)
        }
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.enqueue([homeBody])
        LibraryReadProtocol.beforeNextReply { await MainActor.run { StartupContentPrefetcher.invalidateHomeSectionsInFlight() } }
        do { _ = try await StartupContentPrefetcher.fetchHomeSections(api: api, tokens: tokens); XCTFail("pre-mutation read cached") } catch {}
        let none: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertNil(none)
        LibraryReadProtocol.enqueue([homeBody])
        _ = try await StartupContentPrefetcher.fetchHomeSections(api: api, tokens: tokens)
        let cached = await StartupContentPrefetcher.cachedHomeSections(tokens: tokens)
        XCTAssertNotNil(cached)
        await tokens.setProfileToken("new")
        let foreign = await StartupContentPrefetcher.cachedHomeSections(tokens: tokens)
        XCTAssertNil(foreign)
    }

    func testHomeModelRechecksRunAfterSuspendedAuthority() async throws {
        ResponseCache.shared.remove(CacheKey.homeSections)
        let decoder = HTTPClient.makeJSONDecoder()
        let original = try decoder.decode(SectionsResponse.self, from: homeBody)
        let replacement = SectionsResponse(sections: [])
        var reads = 0
        let oldArrival = expectation(description: "old authority suspended")
        let newArrival = expectation(description: "new authority suspended")
        let gate = MetadataAuthorityGate(passFirst: false, old: oldArrival, new: newArrival)
        let model = HomeViewModel(fetchHomeSections: {
            reads += 1
            return reads == 1 ? original : replacement
        }, responseIsCurrent: { _ in await gate.check() })
        let old = Task { await model.loadSections() }
        await fulfillment(of: [oldArrival], timeout: 2)
        let new = Task { await model.loadSections() }
        await fulfillment(of: [newArrival], timeout: 2)
        await gate.releaseNew()
        await new.value
        await gate.releaseOld(true)
        await old.value
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
        XCTAssertEqual(reads, 2)
    }

    func testHomeDismissalDuringAuthorityCheckCannotResurrectCard() async throws {
        ResponseCache.shared.remove(CacheKey.homeSections)
        let response = try HTTPClient.makeJSONDecoder().decode(SectionsResponse.self, from: homeBody)
        let item = try XCTUnwrap(response.sections.first?.items.first)
        let arrived = expectation(description: "read awaiting authority")
        let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
        let model = HomeViewModel(dismissContinueWatching: { _, _, _ in },
            fetchHomeSections: { response }, responseIsCurrent: { _ in await gate.check() })
        model.sections = response.sections
        let read = Task { await model.loadSections() }
        await fulfillment(of: [arrived], timeout: 2)
        await model.dismissContinueWatchingItem(item)
        await gate.releaseOld(true)
        await read.value
        XCTAssertTrue(model.sections.first?.items.isEmpty == true)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
    }

    func testMembershipReadsUseExactEntriesAndProblemAbsence() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let entry = Data(#"{"item_id":"movie/a?b","added_at":"2026-09-06T00:00:00.000Z"}"#.utf8)
        LibraryReadProtocol.enqueue([entry, entry])
        let favorite = try await api.isFavorite(contentId: "movie/a?b", auth: auth)
        let watchlist = try await api.isInWatchlist(contentId: "movie/a?b", auth: auth)
        XCTAssertTrue(favorite); XCTAssertTrue(watchlist)
        XCTAssertEqual(LibraryReadProtocol.requests().map { $0.url!.absoluteString }, [
            "https://libraries.example/api/v2/favorites/movie%2Fa%3Fb",
            "https://libraries.example/api/v2/watchlist/movie%2Fa%3Fb"
        ])
        LibraryReadProtocol.status = 404
        let absent = Data(#"{"type":"https://silo.test/problems/not_found","title":"Not found","status":404,"detail":"Not a member"}"#.utf8)
        LibraryReadProtocol.enqueue([absent, absent])
        let noFavorite = try await api.isFavorite(contentId: "movie/a?b", auth: auth)
        let noWatchlist = try await api.isInWatchlist(contentId: "movie/a?b", auth: auth)
        XCTAssertFalse(noFavorite); XCTAssertFalse(noWatchlist)
        LibraryReadProtocol.enqueue([Data("route missing".utf8)])
        do { _ = try await api.isFavorite(contentId: "movie/a?b", auth: auth); XCTFail("untyped absence") } catch {}
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data(#"{"item_id":"other","added_at":"2026-09-06T00:00:00.000Z"}"#.utf8)])
        do { _ = try await api.isFavorite(contentId: "movie/a?b", auth: auth); XCTFail("wrong identity") } catch {}
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        do { _ = try await api.isInWatchlist(contentId: "movie/a?b", auth: auth); XCTFail("legacy success") } catch {}
    }

    func testMembershipReadsPinNilAndReplacementAuthority() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.personalMembership(id: "movie", watchlist: false, auth: captured); XCTFail("PIN rebound") } catch {}
        do { _ = try await v2.personalMembership(id: "movie", watchlist: true, auth: nil); XCTFail("missing owner recaptured") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 404
        LibraryReadProtocol.enqueue([Data(#"{"type":"https://silo.test/problems/not_found","title":"Not found","status":404,"detail":"Not a member"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.personalMembership(id: "movie", watchlist: true, auth: current); XCTFail("foreign absence") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    private var discoverBody: Data {
        Data(#"{"items":[{"type":"popular","title":"Popular","items":[{"content_id":"movie:one","type":"movie","title":"One","rating_imdb":8.1}]},{"type":"cluster","title":"For You","items":[{"content_id":"episode:two","type":"episode","title":"Two","series_id":"series:2","season_number":0,"episode_number":2}]},{"type":"genre","title":"Empty","items":[]}],"page":{"has_more":false}}"#.utf8)
    }

    func testDiscoverV2ProjectsCompleteOrderedRowsAndRejectsContinuation() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.enqueue([discoverBody])
        let response = try await api.recommendationsDiscover(auth: auth)
        XCTAssertEqual(response.sections.map(\.title), ["Popular", "For You", "Empty"])
        XCTAssertEqual(response.sections[0].items.first?.ratingImdb, 8.1)
        XCTAssertEqual(response.sections[1].items.first?.seasonNumber, 0)
        XCTAssertEqual(response.sections[1].items.first?.seriesId, "series:2")
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.path, "/api/v2/recommendations/discover")
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"has_more":true,"next_cursor":"later"}}"#.utf8)])
        do { _ = try await api.recommendationsDiscover(auth: auth); XCTFail("partial rows") } catch {}
    }

    func testDiscoverV2PinsAuthorityAtCaptureAndReply() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.discover(auth: XCTUnwrap(captured)); XCTFail("rebound PIN") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([discoverBody])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.discover(auth: XCTUnwrap(current)); XCTFail("foreign reply") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testDiscoverModelScopesCacheAndPreservesForYouOrdering() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.remove(CacheKey.recommendations)
        defer {
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.remove(CacheKey.recommendations)
        }
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.enqueue([discoverBody])
        let model = RecommendationsViewModel(api: api, tokens: tokens)
        await model.loadRecommendations()
        XCTAssertEqual(model.sections.map(\.title), ["For You", "Popular"])
        let original = await tokens.captureOrdinaryRequestAuth()
        XCTAssertNotNil(StartupContentPrefetcher.cachedRecommendations(auth: try XCTUnwrap(original)))
        ResponseCache.shared.remove(CacheKey.recommendations)
        await model.refresh() // Failed refresh after invalidation keeps this owner's visible cards.
        XCTAssertEqual(model.sections.map(\.title), ["For You", "Popular"])
        // A changed PIN must not display the old owner's cache even when the fresh GET fails.
        await tokens.setProfileToken("replacement")
        await model.refresh()
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
        let current = await tokens.captureOrdinaryRequestAuth()
        XCTAssertNil(StartupContentPrefetcher.cachedRecommendations(auth: try XCTUnwrap(current)))
    }

    func testDiscoverReplacementDoesNotJoinOrPublishOldAuthorityFlight() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.remove(CacheKey.recommendations)
        defer {
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.remove(CacheKey.recommendations)
        }
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let model = RecommendationsViewModel(api: api, tokens: tokens)
        let arrived = expectation(description: "old GET awaiting reply")
        let gate = MetadataAuthorityGate(passFirst: false, old: arrived, new: XCTestExpectation(description: "unused"))
        LibraryReadProtocol.enqueue([discoverBody, Data(#"{"items":[{"type":"popular","title":"New owner","items":[{"content_id":"movie:new","type":"movie","title":"New"}]}]}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { _ = await gate.check() }
        let old = Task { await model.loadRecommendations() }
        await fulfillment(of: [arrived], timeout: 2)
        await tokens.setProfileToken("new")
        await model.refresh()
        await gate.releaseOld(true)
        await old.value
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
        XCTAssertEqual(model.sections.map(\.title), ["New owner"])
        XCTAssertFalse(model.isLoading)
    }

    private var calendarBody: Data {
        Data(#"{"events":[{"date":"2026-09-07","items":[{"content_id":"episode:7","type":"episode","title":"Series","series_id":"series:1","season_number":0,"episode_number":1,"air_date":"2026-09-06","air_at":"2026-09-07T01:00:00.000Z","air_timezone":"America/New_York","local_air_date":"2026-09-07","watched":false,"badges":["season_premiere"]}]}]}"#.utf8)
    }

    func testCalendarV2PreservesLocalDaysFiltersAndEventNavigation() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        LibraryReadProtocol.enqueue([calendarBody])
        let value = try await v2.calendar(start: "2026-09-07", end: "2026-09-13", filter: "following",
            timezone: "America/New_York", auth: auth)
        let event = try XCTUnwrap(value.events.first?.items.first)
        XCTAssertEqual(value.events.first?.date, "2026-09-07")
        XCTAssertEqual(event.navigationContentId, "series:1")
        XCTAssertEqual(event.seasonNumber, 0)
        XCTAssertEqual(event.airAt, "2026-09-07T01:00:00.000Z")
        XCTAssertEqual(event.displayBadges.map(\.rawValue), ["season_premiere"])
        let request = try XCTUnwrap(LibraryReadProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v2/calendar")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }),
            ["start":"2026-09-07", "end":"2026-09-13", "filter":"following", "timezone":"America/New_York"])
        LibraryReadProtocol.enqueue([Data(#"{"events":[]}"#.utf8)])
        let empty = try await v2.calendar(start: "2026-09-07", end: "2026-09-13", filter: "everything", timezone: "UTC", auth: auth)
        XCTAssertTrue(empty.events.isEmpty)
    }

    func testCalendarV2PinsAuthorityAtCaptureAndReply() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.calendar(start: "2026-09-07", end: "2026-09-13", filter: "trending", timezone: "UTC", auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.enqueue([calendarBody])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.calendar(start: "2026-09-07", end: "2026-09-13", filter: "trending", timezone: "UTC", auth: XCTUnwrap(current)); XCTFail("late reply") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testCalendarModelSupersededLoadCannotPublishOrReuseForeignCache() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let model = CalendarViewModel(api: api, tokens: tokens)
        let old = expectation(description: "old response held")
        let gate = MetadataAuthorityGate(passFirst: false, old: old, new: old)
        LibraryReadProtocol.enqueue([calendarBody, Data(#"{"events":[]}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { _ = await gate.check() }
        let first = Task { await model.load(ignoreCache: true) }
        await fulfillment(of: [old], timeout: 2)
        await model.load(ignoreCache: true)
        await gate.releaseOld(true)
        await first.value
        XCTAssertTrue(model.days.isEmpty)
        XCTAssertFalse(model.isLoading)
        LibraryReadProtocol.enqueue([calendarBody])
        await model.load(ignoreCache: true)
        XCTAssertFalse(model.days.isEmpty)
        await tokens.setProfileToken("replacement")
        LibraryReadProtocol.status = 503
        LibraryReadProtocol.enqueue([Data()])
        await model.load()
        XCTAssertTrue(model.days.isEmpty, "old proof cache must not survive")
        XCTAssertNotNil(model.error)
    }

    func testSimilarRecommendationsUseOrderedCardsWithoutDetailRequests() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        LibraryReadProtocol.enqueue([Data(#"{"items":[{"content_id":"movie-b","type":"movie","title":"Second","year":2024,"poster_url":"/images/b"},{"content_id":"series-a","type":"series","title":"First"}],"page":{"limit":12,"has_more":false}}"#.utf8)])
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let cards = try await api.recommendationsSimilar(contentId: "movie/a?b", auth: auth)
        XCTAssertEqual(cards.map(\.contentId), ["movie-b", "series-a"])
        let posters = cards.map(SimilarPosterItem.init(card:))
        XCTAssertEqual(posters.first?.title, "Second")
        XCTAssertEqual(posters.first?.posterUrl, "/images/b")
        XCTAssertEqual(posters.first?.year, 2024)
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.absoluteString,
            "https://libraries.example/api/v2/recommendations/similar/movie%2Fa%3Fb?limit=12")
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"limit":12,"has_more":false}}"#.utf8)])
        let empty = try await api.recommendationsSimilar(contentId: "movie", auth: auth)
        XCTAssertTrue(empty.isEmpty)
    }

    func testSimilarRecommendationsRefuseIncompleteCollectionAndAuthorityChanges() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        do { _ = try await v2.similarCards(id: "movie", limit: 12, auth: XCTUnwrap(captured)); XCTFail("PIN rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(current)
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"limit":12,"has_more":true,"next_cursor":"next"}}"#.utf8)])
        do { _ = try await v2.similarCards(id: "movie", limit: 12, auth: auth); XCTFail("incomplete collection") } catch {}
        LibraryReadProtocol.enqueue([Data(#"{"items":[],"page":{"limit":12,"has_more":false}}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.similarCards(id: "movie", limit: 12, auth: auth); XCTFail("late authority") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testTrailerRefreshStatusPairsAndNoReplay() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        for (code, status) in [(202, "queued"), (200, "cooldown"), (200, "disabled")] {
            LibraryReadProtocol.status = code
            LibraryReadProtocol.enqueue([Data("{\"status\":\"\(status)\"}".utf8)])
            let value = try await v2.refreshTrailers(id: "movie/a?b", auth: auth)
            XCTAssertEqual(value.status, status)
        }
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.absoluteString,
                       "https://libraries.example/api/v2/catalog/items/movie%2Fa%3Fb/trailers/refresh")
        for (code, status) in [(200, "queued"), (202, "disabled"), (202, "unknown"), (401, "queued"), (429, "queued")] {
            LibraryReadProtocol.status = code
            LibraryReadProtocol.enqueue([Data("{\"status\":\"\(status)\"}".utf8)])
            let count = LibraryReadProtocol.requests().count
            do { _ = try await v2.refreshTrailers(id: "movie", auth: auth); XCTFail("invalid acknowledgement") } catch {}
            XCTAssertEqual(LibraryReadProtocol.requests().count, count + 1)
        }
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy { $0.httpMethod == "POST" })
        XCTAssertTrue(LibraryReadProtocol.lastBody().isEmpty)
    }

    func testTrailerRefreshPinsAuthorityBeforeDispatchAndAfterReply() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("new") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        do { _ = try await v2.refreshTrailers(id: "movie", auth: auth); XCTFail("PIN rebound") } catch {}
        do { _ = try await v2.trailerItem(id: "movie", imageSize: nil, auth: auth); XCTFail("poll rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([Data(#"{"status":"queued"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.refreshTrailers(id: "movie", auth: XCTUnwrap(current)); XCTFail("late receipt") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testTrailerCancelledAuthorityCheckCannotPublishIntoReplacement() async throws {
        let old = expectation(description: "old suspended")
        let new = expectation(description: "replacement suspended")
        let gate = MetadataAuthorityGate(passFirst: false, old: old, new: new)
        var sends = 0
        let coordinator = TrailerFetchCoordinator(request: {
            sends += 1
            return TrailerRefreshResponse(status: "disabled", nextAllowedAt: nil)
        }, fetchDetail: { throw URLError(.badServerResponse) }, matchesAuthority: { await gate.check() })
        coordinator.start(baseline: nil)
        await fulfillment(of: [old], timeout: 2)
        let oldTask = try XCTUnwrap(coordinator.taskForTesting)
        coordinator.stop()
        coordinator.start(baseline: nil)
        await fulfillment(of: [new], timeout: 2)
        let newTask = try XCTUnwrap(coordinator.taskForTesting)
        await gate.releaseOld(false)
        await oldTask.value
        XCTAssertEqual(coordinator.phase, .requesting)
        XCTAssertEqual(sends, 0)
        coordinator.stop()
        await gate.releaseNew()
        await newTask.value
        XCTAssertEqual(sends, 0)
    }

    func testViewerPersonRefreshExact202AndSingleSend() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([Data(#"{"status":"queued","person_id":"7"}"#.utf8)])
        let response = try await v2.refreshPerson(id: 7, auth: auth)
        XCTAssertEqual(response.personId, 7)
        XCTAssertEqual(response.status, "queued")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.url?.path, "/api/v2/catalog/people/7/refresh")
        XCTAssertTrue(LibraryReadProtocol.lastBody().isEmpty)
        for body in [#"{"status":"queued","person_id":"8"}"#, #"{"status":"queued","person_id":7}"#, #"{"status":"done","person_id":"7"}"#] {
            LibraryReadProtocol.enqueue([Data(body.utf8)])
            do { _ = try await v2.refreshPerson(id: 7, auth: auth); XCTFail("invalid receipt") } catch {}
        }
        for status in [200, 401, 429, 503] {
            LibraryReadProtocol.status = status
            LibraryReadProtocol.enqueue([Data(#"{"status":"queued","person_id":"7"}"#.utf8)])
            let count = LibraryReadProtocol.requests().count
            do { _ = try await v2.refreshPerson(id: 7, auth: auth); XCTFail("unexpected success") } catch {}
            XCTAssertEqual(LibraryReadProtocol.requests().count, count + 1)
        }
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy { $0.httpMethod == "POST" })
    }

    func testViewerPersonRefreshAuthorityAtCaptureAndReply() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        do { _ = try await v2.refreshPerson(id: 7, auth: auth); XCTFail("PIN rebound") } catch {}
        do { _ = try await v2.catalogPerson(id: 7, auth: auth); XCTFail("poll rebound") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        let current = await tokens.captureOrdinaryRequestAuth()
        let replacement = try XCTUnwrap(current)
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([Data(#"{"status":"queued","person_id":"7"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await v2.refreshPerson(id: 7, auth: replacement); XCTFail("late reply") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testViewerPersonFailedEnqueueOnlyPollsBoundedlyWithoutReplay() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        let model = PersonDetailViewModel(personId: 7, api: api, tokens: tokens,
            pollDelay: { LibraryReadProtocol.status = 200 })
        await model.captureMetadataRefreshAuthority()
        model.person = try HTTPClient.makeJSONDecoder().decode(Person.self, from: Data(#"{"id":7,"name":"Original"}"#.utf8))
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data()] + Array(repeating: Data(#"{"id":"7","name":"Original"}"#.utf8), count: 5))
        model.resumeMetadataRefreshIfNeeded()
        let task = try XCTUnwrap(model.metadataRefreshTaskForTesting)
        await task.value
        XCTAssertFalse(model.isRefreshingMetadata)
        XCTAssertEqual(model.person?.name, "Original")
        XCTAssertEqual(LibraryReadProtocol.requests().map(\.httpMethod), ["POST", "GET", "GET", "GET", "GET", "GET"])
        model.resumeMetadataRefreshIfNeeded()
        XCTAssertNil(model.metadataRefreshTaskForTesting)
        XCTAssertEqual(LibraryReadProtocol.requests().count, 6)
    }

    func testViewerPersonCancelledRunCannotClearReplacementOrPublish() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        for beforePublish in [false, true] {
            LibraryReadProtocol.reset()
            LibraryReadProtocol.status = 202
            LibraryReadProtocol.enqueue([Data(#"{"status":"queued","person_id":"7"}"#.utf8),
                Data(#"{"id":"7","name":"Late result"}"#.utf8)])
            let old = expectation(description: "old authority suspended")
            let new = expectation(description: "replacement authority suspended")
            let gate = MetadataAuthorityGate(passFirst: false, old: old, new: new)
            var checks = 0
            let model = PersonDetailViewModel(personId: 7, api: api, tokens: tokens,
                pollDelay: { LibraryReadProtocol.status = 200 }, authorityCheck: { _ in
                    checks += 1
                    if beforePublish && checks <= 2 { return true }
                    return await gate.check()
                })
            await model.captureMetadataRefreshAuthority()
            model.person = try HTTPClient.makeJSONDecoder().decode(Person.self, from: Data(#"{"id":7,"name":"Original"}"#.utf8))
            model.resumeMetadataRefreshIfNeeded()
            await fulfillment(of: [old], timeout: 2)
            let oldTask = try XCTUnwrap(model.metadataRefreshTaskForTesting)
            model.stopMetadataRefresh()
            model.resumeMetadataRefreshIfNeeded()
            await fulfillment(of: [new], timeout: 2)
            let replacement = try XCTUnwrap(model.metadataRefreshTaskForTesting)
            await gate.releaseOld(true)
            await oldTask.value
            XCTAssertEqual(model.person?.name, "Original")
            XCTAssertTrue(model.isRefreshingMetadata)
            XCTAssertNotNil(model.metadataRefreshTaskForTesting)
            XCTAssertEqual(LibraryReadProtocol.requests().filter { $0.httpMethod == "POST" }.count, beforePublish ? 1 : 0)
            model.stopMetadataRefresh()
            await gate.releaseNew()
            await replacement.value
        }
    }

    func testTrackPreferencesFourOperationsAndOffOmission() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data(), Data(), Data(), Data()])
        let key = "movie/a?b#c%"
        try await api.setAudioPref(seriesId: key,
            body: AudioPrefRequest(audioTrackIndex: -1, audioLanguage: "", trackSignature: nil), auth: auth)
        let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(audio["audio_track_index"] as? Int, -1)
        XCTAssertEqual(audio["audio_language"] as? String, "")
        try await api.setSubtitlePref(seriesId: key,
            body: TrackSelectionPersistence.subtitleOffRequest(showForced: nil), auth: auth)
        let off = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(off["subtitle_track_index"] as? Int, -1)
        XCTAssertEqual(off["subtitle_mode"] as? String, "off")
        XCTAssertEqual(off["subtitle_language"] as? String, "")
        XCTAssertNil(off["show_forced_subtitles"])
        XCTAssertNil(off["track_signature"])
        try await api.setSubtitlePref(seriesId: key,
            body: TrackSelectionPersistence.subtitleOffRequest(showForced: false), auth: auth)
        let forced = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(forced["show_forced_subtitles"] as? Bool, false)
        try await api.deleteAudioPref(seriesId: key, auth: auth)
        try await api.deleteSubtitlePref(seriesId: key, auth: auth)
        let requests = LibraryReadProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "PUT", "PUT", "DELETE", "DELETE"])
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://libraries.example/api/v2/audio-prefs/movie%2Fa%3Fb%23c%25")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile" })
    }

    func testTrackPreferencesRequireProfileAndPreserveSignatures() async throws {
        let (v2, tokens) = try await fixture()
        let absent = await tokens.captureOrdinaryRequestAuth()
        do {
            try await v2.deleteTrackPreference(kind: "audio", seriesId: "series", auth: XCTUnwrap(absent))
            XCTFail("profileless preference dispatched")
        } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data(), Data()])
        try await v2.writeTrackPreference(kind: "audio", seriesId: "series",
            body: AudioPrefRequest(audioTrackIndex: 1, audioLanguage: "eng",
                trackSignature: AudioTrackSignature(embeddedTitle: "Surround", channels: 6, isDefault: true)), auth: auth)
        let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        let signature = try XCTUnwrap(audio["track_signature"] as? [String: Any])
        XCTAssertEqual(signature["default"] as? Bool, true)
        XCTAssertEqual(signature["embedded_title"] as? String, "Surround")
        XCTAssertEqual(signature["channels"] as? Int, 6)
        XCTAssertNil(signature["is_default"])
        try await v2.writeTrackPreference(kind: "subtitle", seriesId: "series",
            body: SubtitlePrefRequest(subtitleLanguage: "eng", subtitleTrackIndex: 3,
                externalSubtitlePath: "sidecar.srt", subtitleMode: "always",
                trackSignature: SubtitleTrackSignature(source: "external", language: "eng", forced: true, hearingImpaired: true),
                showForcedSubtitles: nil), auth: auth)
        let subtitle = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        let subSignature = try XCTUnwrap(subtitle["track_signature"] as? [String: Any])
        XCTAssertEqual(subSignature["hearing_impaired"] as? Bool, true)
        XCTAssertEqual(subSignature["forced"] as? Bool, true)
        XCTAssertEqual(subtitle["external_subtitle_path"] as? String, "sidecar.srt")
        XCTAssertNil(subtitle["show_forced_subtitles"])
    }

    func testTrackPreferencesScheduledWriterNeverRecapturesAuthority() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        // Same server/profile, different account epoch: routing alone is insufficient.
        try await tokens.installAccountSession(accessToken: "replacement", refreshToken: "replacement-refresh", accountID: "2")
        await tokens.setProfileId("profile")
        let api = SiloAPI(tokenStore: tokens, v2: v2)
        await TrackSelectionPersistence.saveAudio(prefKey: "series",
            request: AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "eng", trackSignature: nil), auth: auth, api: api).value
        await TrackSelectionPersistence.saveSubtitle(prefKey: "series",
            request: TrackSelectionPersistence.subtitleOffRequest(showForced: nil), auth: auth, api: api).value
        await TrackSelectionPersistence.clearAudio(prefKey: "series", auth: auth, api: api).value
        await TrackSelectionPersistence.clearSubtitle(prefKey: "series", auth: auth, api: api).value
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testTrackPreferencesPinsPINAtTransportIncludingNil() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("replacement") })
        await tokens.setProfileId("profile")
        for pin in [nil, "original"] as [String?] {
            await tokens.setProfileToken(pin)
            let captured = await tokens.captureOrdinaryRequestAuth()
            let auth = try XCTUnwrap(captured)
            do {
                try await v2.deleteTrackPreference(kind: "audio", seriesId: "series", auth: auth)
                XCTFail("replacement PIN dispatched")
            } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testTrackPreferencesRejectLateAuthorityAndRequire204() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do {
            try await v2.deleteTrackPreference(kind: "subtitle", seriesId: "series", auth: auth)
            XCTFail("late reply accepted")
        } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data()])
        do {
            try await v2.deleteTrackPreference(kind: "audio", seriesId: "series", auth: auth)
            XCTFail("non-contract response accepted")
        } catch APIv2Error.httpStatus(200) {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    private var onboardingStateBody: Data { Data(#"{"tour_id":"tour","last_step":"welcome","done":false}"#.utf8) }
    private var onboardingFlowBody: Data { Data(#"{"version":1,"tour_id":"tour","steps":[]}"#.utf8) }

    func testOnboardingAcknowledgedValidatorAndOldWriterRefusal() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        let request = OnboardingProgressRequest(tourId: "tour", lastStep: "next", completed: false, skipped: false, writerID: flow.writerID)
        LibraryReadProtocol.tag = "\"rev1\""
        LibraryReadProtocol.enqueue([onboardingStateBody])
        try await facade.postOnboardingProgress(request)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.httpMethod, "PUT")
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "If-Match"), "\"rev0\"")
        LibraryReadProtocol.enqueue([onboardingStateBody])
        try await facade.postOnboardingProgress(request)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "If-Match"), "\"rev1\"")
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        _ = try await facade.onboardingFlow(surface: "phone")
        let count = LibraryReadProtocol.requests().count
        do { try await facade.postOnboardingProgress(request); XCTFail("old writer") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, count)
    }

    func testOnboarding401ConsumesWriterWithoutRefreshOrReplay() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        let request = OnboardingProgressRequest(tourId: "tour", lastStep: "next", completed: false, skipped: false, writerID: flow.writerID)
        for _ in 0..<2 { do { try await facade.postOnboardingProgress(request); XCTFail("replayed writer") } catch {} }
        XCTAssertEqual(LibraryReadProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(LibraryReadProtocol.requests().count, 3)
    }

    func testOnboardingWriterRefusesChangedProfileBeforeDispatch() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        await tokens.setProfileId("other")
        do { try await facade.postOnboardingProgress(OnboardingProgressRequest(tourId: "tour", lastStep: nil, completed: true, skipped: false, writerID: flow.writerID)); XCTFail("wrong profile") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testMetadataCancelledAuthorityReadCannotStartPollOrFailReplacement() async throws {
        try await exerciseMetadataAuthorityReplacement(afterDetailRead: false)
    }

    func testMetadataCancelledAuthorityPublicationCannotApplyOrFailReplacement() async throws {
        try await exerciseMetadataAuthorityReplacement(afterDetailRead: true)
    }

    private func exerciseMetadataAuthorityReplacement(afterDetailRead: Bool) async throws {
        for oldResult in [true, false] {
            let (v2, tokens) = try await fixture()
            await tokens.setProfileId("profile")
            let api = SiloAI(v2: v2)
            LibraryReadProtocol.status = 202
            let job = Data(#"{"id":"job","target_kind":"item","content_id":"item","target_language":"fr","status":"pending"}"#.utf8)
            LibraryReadProtocol.enqueue([job, job])
            let oldSuspended = expectation(description: "old authority check")
            let newSuspended = expectation(description: "new authority check")
            let gate = MetadataAuthorityGate(passFirst: afterDetailRead, old: oldSuspended, new: newSuspended)
            let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self,
                from: Data(#"{"content_id":"item","type":"movie","title":"One","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[]}"#.utf8))
            let detail = try ItemDetail(catalog: wire)
            var reads = 0
            var applied = 0
            let cacheKey = CacheKey.itemDetail("item")
            ResponseCache.shared.set("unchanged", for: cacheKey)
            defer { ResponseCache.shared.remove(cacheKey) }
            let coordinator = DescriptionTranslationCoordinator(api: api, backoff: [0],
                authorityCheck: { _ in await gate.check() }, detailRead: { _ in reads += 1; return detail })
            coordinator.translate(contentId: "item", targetLanguage: "fr") { _ in applied += 1 }
            let oldTask = try XCTUnwrap(coordinator.runTaskForTesting)
            await fulfillment(of: [oldSuspended], timeout: 2)
            coordinator.cancel()
            coordinator.translate(contentId: "item", targetLanguage: "fr") { _ in applied += 1 }
            await fulfillment(of: [newSuspended], timeout: 2)
            let newTask = try XCTUnwrap(coordinator.runTaskForTesting)
            await gate.releaseOld(oldResult)
            await oldTask.value
            XCTAssertEqual(coordinator.phase, .translating)
            XCTAssertEqual(applied, 0)
            XCTAssertEqual(ResponseCache.shared.get(cacheKey, as: String.self), "unchanged")
            XCTAssertEqual(reads, afterDetailRead ? 1 : 0)
            coordinator.cancel()
            await gate.releaseNew()
            await newTask.value
        }
    }

    func testMetadataCapabilityUnknownModesAndUnavailableRemainOff() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        LibraryReadProtocol.enqueue([
            Data(#"{"state":"not_configured","revision":"opaque","on_view":"auto"}"#.utf8),
            Data(#"{"state":"available","revision":"opaque","on_view":"future"}"#.utf8)])
        let disabled = try await api.metadataAIStatus()
        XCTAssertFalse(disabled.enabled); XCTAssertEqual(disabled.onView, .off)
        let future = try await api.metadataAIStatus()
        XCTAssertTrue(future.enabled); XCTAssertEqual(future.onView, .off)
    }

    func testMetadataTranslationDecodesBareFailedJobAndEncodesContentIdentity() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([Data(#"{"id":"opaque-job","target_kind":"season","content_id":"season/a?#%","target_language":"fr","status":"failed"}"#.utf8)])
        let result = try await api.translateDescription(contentId: "season/a?#%", targetLanguage: "fr", auth: auth)
        XCTAssertEqual(result.id, "opaque-job"); XCTAssertTrue(result.failed)
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        XCTAssertTrue(request.url!.absoluteString.contains("season%2Fa%3F%23%25/translate-description"))
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testMetadataTranslationProblemsAreSingleSendAndLateAuthorityIsRejected() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        for status in [401, 409, 422] {
            LibraryReadProtocol.status = status
            LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
            do { _ = try await api.translateDescription(contentId: "item", targetLanguage: "fr", auth: auth); XCTFail("accepted Problem") } catch {}
        }
        XCTAssertEqual(LibraryReadProtocol.requests().count, 3)
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([Data(#"{"id":"job","target_kind":"item","content_id":"item","target_language":"fr","status":"pending"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.translateDescription(contentId: "item", targetLanguage: "fr", auth: auth); XCTFail("stale reply") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 4)
    }

    private func subtitleCreateBody() -> TranslateSubtitleBody {
        TranslateSubtitleBody(mediaFileId: 42, kind: .translate, sourceIndex: 3, sourceLanguage: "en",
            targetLanguage: "fr", sessionId: "session-exact", startPosition: 12.5)
    }
    private func subtitleCreateReply(file: String = "42") -> Data {
        Data("""
        {"job":{"id":"9007199254740993","media_file_id":"\(file)","kind":"translate","source_index":3,"source_language":"en","target_language":"fr","engine":"","model":"","status":"pending","progress":0,"progress_message":"","created_at":"1970-01-01T00:01:40.000Z","updated_at":"1970-01-01T00:01:40.000Z"},"live_delivery_attached":false}
        """.utf8)
    }
    func testSubtitleCreationUsesExact202WireAndBackgroundFlag() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([subtitleCreateReply()])
        let result = try await api.translateSubtitle(subtitleCreateBody(), auth: auth)
        XCTAssertEqual(result.job.id, "9007199254740993")
        XCTAssertFalse(result.liveDeliveryAttached)
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/v2/subtitles/ai/translate")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(fields["media_file_id"] as? String, "42")
        XCTAssertEqual(fields["session_id"] as? String, "session-exact")
        XCTAssertEqual(fields["source_index"] as? Int, 3)
        XCTAssertEqual(fields["start_position"] as? Double, 12.5)
    }
    func testSubtitleCreation401CannotRefreshOrReenqueue() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data()])
        for _ in 0..<2 {
            do { _ = try await api.translateSubtitle(subtitleCreateBody(), auth: auth); XCTFail("replayed") } catch {}
        }
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }
    func testSubtitleCreationRejectsPINReplacementAtHTTPCapture() async throws {
        let (v2, tokens) = try await fixture(captureBarrier: { await $0.setProfileToken("proof-b") })
        await tokens.setProfileId("profile")
        await tokens.setProfileToken("proof-a")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        do { _ = try await api.translateSubtitle(subtitleCreateBody(), auth: auth); XCTFail("replacement PIN dispatched") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testSubtitleCreationPinsAbsentProfileAndPINAtHTTPCapture() async throws {
        let (v2, _) = try await fixture(captureBarrier: {
            await $0.setProfileId("new-profile")
            await $0.setProfileToken("new-proof")
        })
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        XCTAssertNil(auth.profileId); XCTAssertNil(auth.profileToken)
        do { _ = try await api.translateSubtitle(subtitleCreateBody(), auth: auth); XCTFail("absent authority replaced") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testSubtitleCreationRejectsChangedProfileBeforeAndAfterDispatch() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        await tokens.setProfileId("other")
        do { _ = try await v2.createSubtitle(APIv2SubtitleCreateBody(subtitleCreateBody()), auth: auth); XCTFail("stale caller") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([subtitleCreateReply()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.translateSubtitle(subtitleCreateBody(), auth: auth); XCTFail("stale response") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testSubtitleCreationRejectsForeignFileAndRetainsUncertainty() async throws {
        let (v2, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let api = SiloAI(v2: v2)
        let auth = try await api.captureCreationAuthority()
        LibraryReadProtocol.status = 202
        LibraryReadProtocol.enqueue([subtitleCreateReply(file: "43")])
        for _ in 0..<2 {
            do { _ = try await api.translateSubtitle(subtitleCreateBody(), auth: auth); XCTFail("foreign file") } catch {}
        }
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testSettingsEffectiveReadPreservesRepeatedQueryAndTypedValues() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.enqueue([Data(#"{"revision":999,"items":[{"key":"ui.card_overlays","value":{"camelCase":true},"stored_value":null,"source":"profile","profile_id":"profile","library_id":"42"}],"page":{"has_more":false}}"#.utf8)])
        let result = try await facade.getEffectiveValues(keys: [.uiCardOverlays], libraryIds: [42, 43])
        XCTAssertEqual(result.settings.first?.libraryId, 42)
        XCTAssertEqual(result.settings.first?.value, .object(["camelCase": .bool(true)]))
        XCTAssertEqual(result.settings.first?.storedValue, .null)
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.filter { $0.name == "library_ids" }.compactMap(\.value), ["42", "43"])
        XCTAssertEqual(request.url?.path, "/api/v2/settings/values/effective")
    }

    func testSettingsReadsRejectStaleReplyAndDoNotFallback() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.enqueue([Data(#"{"enabled":false,"quick_actions_enabled":false,"quick_actions_default":"off"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await facade.overlayConfig(); XCTFail("stale reply") } catch {}
        LibraryReadProtocol.status = 404
        LibraryReadProtocol.enqueue([Data()])
        do { _ = try await facade.getEffectiveValues(); XCTFail("missing route") }
        catch SettingsAPIError.serverUpgradeRequired { XCTFail("would enable legacy fallback") }
        catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testSubtitleCancellationUsesExactIDAndEmpty204() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        try await SiloAI(v2: api).cancelSubtitleJob(id: "9223372036854775807")
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v2/subtitles/ai/jobs/9223372036854775807/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertNil(request.httpBody)
        do { try await api.cancelSubtitleJob(id: "1/cancel"); XCTFail("invalid ID") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testSubtitleCancellationRejectsUnexpectedStatusAndStaleProfile() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data()])
        do { try await api.cancelSubtitleJob(id: "1"); XCTFail("unexpected200") } catch {}
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await api.cancelSubtitleJob(id: "1"); XCTFail("stale profile") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testManagedCreation401NeverReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        let body = try DownloadCreateV2Body(CreateDownloadRequest(contentId: "movie", episodeId: nil, fileId: 42,
            quality: "original", series: nil, seasonNumber: nil, caps: nil), existing: nil, batchID: nil)
        do { let _: DownloadCreateV2Page = try await api.requestPost("/api/v2/downloads", body: body); XCTFail("accepted401") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    private func profileBody() throws -> Data {
        try APIv2FixtureTestSupport.data(named: "update_profile_ok", bundleClass: Self.self)
    }

    func testHouseholdListBeforeSelectionAndCreateStringLibraries() async throws {
        let (api, tokens) = try await fixture()
        let row = try profileBody()
        LibraryReadProtocol.enqueue([Data("{\"items\":[\(String(decoding: row, as: UTF8.self))]}".utf8)])
        let profiles = try await api.householdProfiles()
        XCTAssertEqual(profiles.first?.id, "p-owner")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.value(forHTTPHeaderField: "X-Profile-Id") ?? "", "")
        await tokens.setProfileId("manager")
        LibraryReadProtocol.status = 201
        LibraryReadProtocol.enqueue([row])
        _ = try await api.createHouseholdProfile(CreateProfileRequestBody(name: "Reader", avatar: nil, pin: nil,
            isChild: false, maxContentRating: nil, libraryRestrictionsEnabled: true, allowedLibraryIds: [7]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(body["allowed_library_ids"] as? [String], ["7"])
        XCTAssertNil(body["pin"]); XCTAssertNil(body["avatar"])
        XCTAssertEqual(LibraryReadProtocol.requests().last?.url?.path, "/api/v2/profiles")
    }

    func testHouseholdCreate401IsSingleSend() async throws {
        let (api, _) = try await fixture()
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do {
            _ = try await api.createHouseholdProfile(CreateProfileRequestBody(name: "Reader", avatar: nil, pin: nil,
                isChild: false, maxContentRating: nil, libraryRestrictionsEnabled: false, allowedLibraryIds: []))
            XCTFail("accepted401")
        } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testHouseholdPINWrongAndStaleProofNeverPersist() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([Data(#"{"valid":false,"expires_at":null}"#.utf8),
            Data(#"{"valid":true,"profile_token":"proof","expires_at":null}"#.utf8)])
        let wrong = try await api.verifyHouseholdPIN(id: "target", pin: "wrong")
        XCTAssertFalse(wrong.valid)
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("replacement") }
        do { _ = try await api.verifyHouseholdPIN(id: "target", pin: "1234"); XCTFail("stale proof") } catch {}
        let auth = await tokens.captureOrdinaryRequestAuth()
        XCTAssertNil(auth?.profileToken)
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy { $0.url?.path == "/api/v2/profiles/target/verify-pin" })
    }

    private func subtitleRequest() throws -> SubtitleDownloadBody {
        let result = try HTTPClient.makeJSONDecoder().decode(SubtitleSearchResult.self,
            from: Data(#"{"id":"opaque+/=01","provider":"provider","language":"en","format":"untrusted","release_name":"release"}"#.utf8))
        return SubtitleDownloadBody(from: result, mediaFileId: 42)
    }

    private func subtitleReply(file: String = "42") -> Data {
        Data("{\"subtitle\":{\"id\":\"9007199254740993\",\"media_file_id\":\"\(file)\",\"provider\":\"provider\",\"language\":\"en\",\"format\":\"srt\",\"release_name\":\"release\",\"score\":0,\"hearing_impaired\":false,\"created_at\":\"2026-01-01T00:00:00Z\"}}".utf8)
    }

    func testProviderDownloadUsesExactWireAndServerFormat() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.enqueue([subtitleReply()])
        let value = try await api.downloadSubtitle(subtitleRequest())
        XCTAssertEqual(value.id, 9007199254740993)
        XCTAssertEqual(value.format, "srt")
        let request = try XCTUnwrap(LibraryReadProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v2/subtitles/download")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["subtitle_id"] as? String, "opaque+/=01")
        XCTAssertNil(object["format"])
    }

    func testProviderDownloadRefusesReplacedCallerBeforeDispatch() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let expected = try XCTUnwrap(captured)
        await tokens.setProfileId("replacement")
        do { _ = try await api.downloadSubtitle(subtitleRequest(), expectedAuth: expected); XCTFail("replaced caller") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testSubscriptionCreate401NeverRefreshesOrReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do {
            let _: ServerSubscription = try await api.requestPost("/api/v2/downloads/subscriptions",
                body: CreateSubscriptionRequest(seriesId: "series", mode: "specific_seasons", seasonNumbers: [0], deleteWatched: false, maxStorageBytes: 0))
            XCTFail("accepted401")
        } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(object["season_numbers"] as? [Int], [0])
    }

    func testProviderDownload401NeverRefreshesOrReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("accepted401") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testProviderDownloadRejectsStaleProfileAndForeignFile() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.enqueue([subtitleReply(), subtitleReply(file: "43")])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("stale profile") } catch {}
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("foreign file") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    private func body() throws -> Data {
        try APIv2FixtureTestSupport.data(named: "user_libraries", bundleClass: Self.self)
    }

    func testAccountAndProfileDiscoveryRetainProjection() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([try body(), try body()])
        let accountRows = try await api.userLibraries()
        let library = try Library(v2: XCTUnwrap(accountRows.first))
        XCTAssertEqual(library.id, 12)
        XCTAssertEqual(library.sortOrder, 2)
        XCTAssertEqual(library.posterUrl, "https://images.example/poster")
        XCTAssertEqual(library.name, "Movies")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.value(forHTTPHeaderField: "X-Profile-Id") ?? "", "")
        await tokens.setProfileId("profile")
        _ = try await api.userLibraries()
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy {
            $0.url?.path == "/api/v2/user/libraries" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer access"
        })
    }

    func testAuthorityChangeDuringResponseDiscardsLibraries() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([try body(), try body()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.userLibraries(); XCTFail("published stale profile response") } catch {}
        LibraryReadProtocol.beforeNextReply {
            try? await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "2")
        }
        do { _ = try await api.userLibraries(); XCTFail("published stale account response") } catch {}
    }

    func testLibraryIDsRequireExactSupportedProjection() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        for id in ["9007199254740993", "9223372036854775808", "01", "opaque", "0"] {
            let wire = APIv2UserLibrary(id: id, name: "Library", type: "future", sortOrder: 3, posterUrl: nil)
            if id == "9007199254740993" {
                let value = try Library(v2: wire)
                XCTAssertEqual(value.id, 9007199254740993)
                XCTAssertNil(value.posterUrl)
                XCTAssertTrue(LibrariesResponse(libraries: [value]).libraries.isEmpty)
            } else { XCTAssertThrowsError(try Library(v2: wire)) }
        }
        let numeric = Data(#"{"id":12,"name":"Movies","type":"movies","sort_order":2}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(APIv2UserLibrary.self, from: numeric))
        let empty = try decoder.decode(APIv2CatalogReadCollection<APIv2UserLibrary>.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertTrue(try empty.completeItems().isEmpty)
    }
}

private final class LibraryReadProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [Data] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var hook: (@Sendable () async -> Void)?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var tag: String?
    nonisolated(unsafe) private static var body = Data()
    static func lastBody() -> Data { lock.withLock { body } }
    static func reset() { lock.withLock { pages = []; captured = []; hook = nil; status = 200; tag = nil; body = Data() } }
    static func enqueue(_ values: [Data]) { lock.withLock { pages.append(contentsOf: values) } }
    static func beforeNextReply(_ value: @escaping @Sendable () async -> Void) { lock.withLock { hook = value } }
    static func requests() -> [URLRequest] { lock.withLock { captured } }
    static func cursors() -> [String?] {
        requests().map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data?, (@Sendable () async -> Void)?) in
            Self.captured.append(request)
            if let data = request.httpBody { Self.body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                Self.body = data
            }
            let data = Self.pages.isEmpty ? nil : Self.pages.removeFirst()
            let hook = Self.hook
            Self.hook = nil
            return (data, hook)
        }
        Task {
            await state.1?()
            guard let data = state.0 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json", "ETag": Self.tag ?? ""])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}


private actor MetadataAuthorityGate {
    private let passFirst: Bool
    private let old: XCTestExpectation
    private let new: XCTestExpectation
    private var calls = 0
    private var oldWaiter: CheckedContinuation<Bool, Never>?
    private var newWaiter: CheckedContinuation<Bool, Never>?
    init(passFirst: Bool, old: XCTestExpectation, new: XCTestExpectation) {
        self.passFirst = passFirst; self.old = old; self.new = new
    }
    func check() async -> Bool {
        calls += 1
        if passFirst && calls == 1 { return true }
        let isOld = calls == (passFirst ? 2 : 1)
        return await withCheckedContinuation { continuation in
            if isOld { oldWaiter = continuation; old.fulfill() }
            else { newWaiter = continuation; new.fulfill() }
        }
    }
    func releaseOld(_ result: Bool) { oldWaiter?.resume(returning: result); oldWaiter = nil }
    func releaseNew() { newWaiter?.resume(returning: true); newWaiter = nil }
}
