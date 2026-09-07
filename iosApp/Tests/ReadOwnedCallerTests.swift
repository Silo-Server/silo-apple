import Foundation
import XCTest
@testable import Silo

@MainActor
final class ReadOwnedCallerTests: XCTestCase {
    private let page = #"{"items":[{"content_id":"movie:one","type":"movie","title":"One","user_state":{"played":true,"is_favorite":false,"in_watchlist":false}}],"page":{"has_more":false},"total":1,"total_exact":true,"window_cursor":"window"}"#

    private func harness(barrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore) {
        let name = "ReadOwnedCallerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://catalog.example")
        try await tokens.installAccountSession(accessToken: "test-access", refreshToken: "test-refresh", accountID: "test-account")
        await tokens.setProfileId("profile")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadOwnedProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens,
            requestCaptureBarrier: { await barrier?(tokens) })
        ReadOwnedProtocol.reset()
        addTeardownBlock { defaults.removePersistentDomain(forName: name); ReadOwnedProtocol.reset() }
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    func testCollectionPaginationRetainsQueryAndRejectsCaptureReplacement() async throws {
        let (api, tokens) = try await harness()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        ReadOwnedProtocol.replies([(200, page.replacingOccurrences(of: #""has_more":false"#, with: #""has_more":true,"next_cursor":"opaque""#)), (200, page)])
        let response = try await api.personalCollectionCards(id: "collection-one", auth: auth)
        XCTAssertEqual(response.items.count, 2)
        let requests = ReadOwnedProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.path, "/api/v2/catalog")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "source" }?.value, "user_collection")
            XCTAssertEqual(query.first { $0.name == "collection_id" }?.value, "collection-one")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        }
        XCTAssertTrue(requests[1].url!.query!.contains("cursor=opaque"))

        let (blocked, otherTokens) = try await harness(barrier: { await $0.setProfileToken("changed") })
        let other = await otherTokens.captureOrdinaryRequestAuth()
        do {
            _ = try await blocked.personalCollectionCards(id: "collection-one", auth: XCTUnwrap(other))
            XCTFail("Must retain the original absent proof at capture")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(ReadOwnedProtocol.requests().isEmpty)
    }

    func testCollectionRejectsRepeatedCursorAndLateOwnerWithoutPublishingPartialRows() async throws {
        let (api, tokens) = try await harness()
        let model = CollectionDetailViewModel(api: api, tokens: tokens)
        let id = UUID().uuidString
        defer { ResponseCache.shared.remove(CacheKey.collectionItems(id)) }
        let continued = page.replacingOccurrences(of: #""has_more":false"#, with: #""has_more":true,"next_cursor":"repeated""#)
        ReadOwnedProtocol.replies([(200, continued), (200, continued)])
        await model.load(collectionId: id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.membership.displayedRead)

        let received = expectation(description: "late collection page")
        ReadOwnedProtocol.replies([(200, page)])
        ReadOwnedProtocol.hold { received.fulfill() }
        let task = Task { await model.load(collectionId: id) }
        await fulfillment(of: [received], timeout: 2)
        await tokens.setProfileToken("replacement")
        ReadOwnedProtocol.release()
        await task.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.membership.displayedRead)
    }

    func testCollectionCacheAndPreparedActionCannotCrossOwner() async throws {
        let (api, tokens) = try await harness()
        let id = UUID().uuidString
        defer { ResponseCache.shared.remove(CacheKey.collectionItems(id)) }
        let model = CollectionDetailViewModel(api: api, tokens: tokens)
        ReadOwnedProtocol.replies([(200, page)])
        await model.load(collectionId: id)
        let action = try XCTUnwrap(model.membership.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
        await tokens.setProfileToken("replacement")
        let result = await model.membership.performCardAction(action)
        XCTAssertNil(result)
        XCTAssertEqual(ReadOwnedProtocol.requests().count, 1)
        ReadOwnedProtocol.replies([(503, "{}")])
        await model.load(collectionId: id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.membership.displayedRead)
    }

    func testMembershipFourOperationsPreserveSiblingAndConsumeEachActionOnce() async throws {
        let (api, tokens) = try await harness()
        let id = UUID().uuidString
        defer { ResponseCache.shared.remove(CacheKey.collectionItems(id)) }
        let model = CollectionDetailViewModel(api: api, tokens: tokens)
        ReadOwnedProtocol.replies([(200, page)])
        await model.load(collectionId: id)
        ReadOwnedProtocol.replies(Array(repeating: (204, ""), count: 4))
        for (target, included) in [(APIv2PersonalListKind.favorites, true), (.watchlist, true), (.favorites, false), (.watchlist, false)] {
            let action = try XCTUnwrap(model.membership.prepareCardAction(contentId: "movie:one", target: target, included: included))
            let result = await model.membership.performCardAction(action)
            XCTAssertEqual(result, true)
            let repeated = await model.membership.performCardAction(action)
            XCTAssertNil(repeated)
            XCTAssertEqual(model.membership.userState(for: "movie:one")?.played, true)
            if target == .watchlist { XCTAssertEqual(model.membership.userState(for: "movie:one")?.isFavorite, included) }
        }
        let calls = Array(ReadOwnedProtocol.requests().dropFirst())
        XCTAssertEqual(calls.map(\.httpMethod), ["PUT", "PUT", "DELETE", "DELETE"])
        XCTAssertTrue(calls.allSatisfy { $0.url!.path.hasPrefix("/api/v2/") })
        XCTAssertTrue(calls.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") == nil })
    }

    func testMembershipUnknownHoldsAcrossReadAndLateReceiptCannotChangeNewProjection() async throws {
        let (api, tokens) = try await harness()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = CatalogCardOwner(auth: try XCTUnwrap(captured), scope: "recommendations", filterKey: "")
        let model = ReadOwnedMembershipModel(api: api, tokens: tokens)
        let state = MediaItemUserState(played: false, isFavorite: false, inWatchlist: false)
        model.publish(owner: owner, rows: [("movie:one", state)])
        let action = try XCTUnwrap(model.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
        ReadOwnedProtocol.replies([(503, "{}")])
        let result = await model.performCardAction(action)
        XCTAssertEqual(result, false)
        model.publish(owner: owner, rows: [("movie:one", state)])
        XCTAssertNil(model.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(ReadOwnedProtocol.requests().count, 1)

        let next = try XCTUnwrap(model.prepareCardAction(contentId: "movie:one", target: .watchlist, included: true))
        let received = expectation(description: "late membership receipt")
        ReadOwnedProtocol.replies([(204, "")]); ReadOwnedProtocol.hold { received.fulfill() }
        let task = Task { await model.performCardAction(next) }
        await fulfillment(of: [received], timeout: 2)
        model.publish(owner: owner, rows: [("movie:one", state)])
        ReadOwnedProtocol.release()
        let late = await task.value
        XCTAssertNil(late)
        XCTAssertEqual(model.userState(for: "movie:one")?.inWatchlist, false)
    }

    func testRecommendationReadPublishesMembershipOwnerAndRejectsStaleAction() async throws {
        let (api, tokens) = try await harness()
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        ResponseCache.shared.remove(CacheKey.recommendations)
        defer {
            StartupContentPrefetcher.resetProfileScopedPrefetches()
            ResponseCache.shared.remove(CacheKey.recommendations)
        }
        let model = RecommendationsViewModel(api: SiloAPI(tokenStore: tokens, v2: api), tokens: tokens)
        ReadOwnedProtocol.replies([(200, #"{"items":[{"type":"popular","title":"Popular","items":[{"content_id":"movie:one","type":"movie","title":"One","user_state":{"played":true,"is_favorite":false,"in_watchlist":false}}]}]}"#)])
        await model.loadRecommendations()
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertEqual(model.membership.displayedRead?.auth, model.displayedAuth)
        let action = try XCTUnwrap(model.membership.prepareCardAction(contentId: "movie:one", target: .watchlist, included: true))
        ReadOwnedProtocol.replies([(204, "")])
        let applied = await model.membership.performCardAction(action)
        XCTAssertEqual(applied, true)
        let next = try XCTUnwrap(model.membership.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
        await tokens.setProfileToken("replacement")
        let stale = await model.membership.performCardAction(next)
        XCTAssertNil(stale)
        XCTAssertEqual(ReadOwnedProtocol.requests().count, 2)
    }

    func testLibraryAndHistoryPagesKeepDisplayedOwnerAndMembership() async throws {
        for source in ["library_collection", "history"] {
            let (api, tokens) = try await harness()
            let model = CollectionDetailViewModel(api: api, tokens: tokens)
            var query = APIv2CatalogQuery()
            query.source = source
            if source == "library_collection" { query.collectionId = "one"; query.libraryId = "7" }
            ReadOwnedProtocol.replies([(200, page.replacingOccurrences(of: #""has_more":false"#, with: #""has_more":true,"next_cursor":"next""#)), (200, page)])
            await model.loadCatalog(query: query, reset: true)
            XCTAssertTrue(model.hasMore)
            let owner = try XCTUnwrap(model.membership.displayedRead)
            let action = try XCTUnwrap(model.membership.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
            ReadOwnedProtocol.replies([(204, ""), (200, page)])
            let applied = await model.membership.performCardAction(action)
            XCTAssertEqual(applied, true)
            await model.loadCatalog(query: query, reset: false)
            XCTAssertFalse(model.hasMore)
            XCTAssertEqual(model.items.count, 1)
            XCTAssertEqual(model.items.first?.userState?.isFavorite, true)
            XCTAssertEqual(model.membership.displayedRead, owner)
            XCTAssertNotNil(model.membership.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
            await tokens.setProfileToken("replacement")
            ReadOwnedProtocol.replies([(503, "{}")])
            await model.loadCatalog(query: query, reset: true)
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertNil(model.membership.displayedRead)
        }
    }

    func testMembership401NeverRefreshesOrResendsUnderNewAuthorization() async throws {
        let (api, tokens) = try await harness()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = CatalogCardOwner(auth: try XCTUnwrap(captured), scope: "history", filterKey: "")
        let model = ReadOwnedMembershipModel(api: api, tokens: tokens)
        model.publish(owner: owner, rows: [("movie:one", MediaItemUserState(played: false, isFavorite: false, inWatchlist: false))])
        let action = try XCTUnwrap(model.prepareCardAction(contentId: "movie:one", target: .favorites, included: true))
        ReadOwnedProtocol.replies([(401, "{}")])
        _ = await model.performCardAction(action)
        _ = await model.performCardAction(action)
        XCTAssertEqual(ReadOwnedProtocol.requests().count, 1)
        XCTAssertEqual(ReadOwnedProtocol.requests().first?.url?.path, "/api/v2/favorites/movie:one")
    }

    func testWatchedLateReceiptCannotInvalidateReplacementOwnersCache() async throws {
        let (api, tokens) = try await harness()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let key = "ReadOwnedCallerTests.\(UUID())"
        defer { ResponseCache.shared.remove(key) }
        let owner = SectionReadOwner(auth: try XCTUnwrap(captured), cacheKey: key)
        let actions = SectionWatchedActions(api: api, tokens: tokens)
        actions.display(owner)
        let generation = actions.generation
        let received = expectation(description: "watched receipt held")
        ReadOwnedProtocol.replies([(204, "")]); ReadOwnedProtocol.hold { received.fulfill() }
        let task = Task { await actions.setWatched(contentId: "episode:one", played: true, owner: owner) }
        await fulfillment(of: [received], timeout: 2)
        await tokens.setProfileToken("replacement")
        let replacement = await tokens.captureOrdinaryRequestAuth()
        actions.display(SectionReadOwner(auth: try XCTUnwrap(replacement), cacheKey: key))
        ResponseCache.shared.set("replacement", for: key)
        ReadOwnedProtocol.release()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNotEqual(actions.generation, generation)
        let cache: String? = ResponseCache.shared.get(key)
        XCTAssertEqual(cache, "replacement")
    }

    func testSectionWatchedCapturesOwnerAndHoldsUnknownWithoutRefreshReplay() async throws {
        let (api, tokens) = try await harness()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = SectionReadOwner(auth: try XCTUnwrap(captured), cacheKey: CacheKey.recommendations)
        let actions = SectionWatchedActions(api: api, tokens: tokens)
        actions.display(owner)
        ReadOwnedProtocol.replies([(204, ""), (503, "{}")])
        let success = await actions.setWatched(contentId: "episode:one", played: true, owner: owner)
        XCTAssertTrue(success)
        let unknown = await actions.setWatched(contentId: "episode:one", played: false, owner: owner)
        XCTAssertFalse(unknown)
        actions.display(owner)
        let repeatAction = await actions.setWatched(contentId: "episode:one", played: false, owner: owner)
        XCTAssertFalse(repeatAction)
        XCTAssertNotNil(actions.errorMessage)
        XCTAssertEqual(ReadOwnedProtocol.requests().map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertTrue(ReadOwnedProtocol.requests().allSatisfy { $0.url!.path == "/api/v2/watched/episode:one" })
        await tokens.setProfileToken("replacement")
        let stale = await actions.setWatched(contentId: "episode:two", played: true, owner: owner)
        XCTAssertFalse(stale)
        XCTAssertEqual(ReadOwnedProtocol.requests().count, 2)
    }
}

private final class ReadOwnedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [(Int, String)] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var held: (() -> Void)?
    nonisolated(unsafe) private static var pending: (() -> Void)?
    static func reset() { lock.withLock { responses = []; recorded = []; held = nil; pending = nil } }
    static func replies(_ values: [(Int, String)]) { lock.withLock { responses = values } }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }
    static func hold(_ notify: @escaping () -> Void) { lock.withLock { held = notify } }
    static func release() {
        let deliver = lock.withLock { let value = pending; pending = nil; held = nil; return value }
        deliver?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
        }
        let deliver = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let notify: (() -> Void)? = Self.lock.withLock { () -> (() -> Void)? in
            if let held = Self.held { Self.pending = deliver; return held }
            return nil as (() -> Void)?
        }
        if let notify { notify() } else { deliver() }
    }
    override func stopLoading() {}
}
