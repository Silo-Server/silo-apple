import Foundation
import XCTest
@testable import Silo

/// The viewer's own star rating: `user_rating` on item detail, the two
/// `non_retryable` writes, the title page's optimistic value with its
/// one-in-flight queue, and the score math the rating controls share.
@MainActor
final class PersonalRatingTests: XCTestCase {
    private let seriesId = "personal-rating-series"
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub(fallback: .json(204, ""))
    }

    override func tearDown() async throws {
        ResponseCache.shared.removeItemMetadata(contentId: seriesId)
        try await super.tearDown()
    }

    // MARK: - Detail read

    func testDetailDecodesTheViewersRating() throws {
        XCTAssertEqual(try catalogDetail(#""user_rating":7"#).userRating, 7)
        XCTAssertNil(try catalogDetail("").userRating, "absent means unrated")
        XCTAssertNil(try catalogDetail(#""user_rating":11"#).userRating, "outside 1...10 is not a rating")
    }

    func testRatingSurvivesTheDetailCacheAndPlaybackEnrichment() throws {
        let detail = try catalogDetail(#""user_rating":9"#)
        let cached = try JSONDecoder().decode(ItemDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(cached.userRating, 9)

        let watch = try WatchDetail(v2: HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.WatchDetail.self, from: Data(
            #"{"content_id":"movie:rated","type":"movie","title":"Rated","subtitles":[],"versions":[]}"#.utf8)))
        XCTAssertEqual(detail.applyingPlaybackMetadata(watch).userRating, 9)
    }

    // MARK: - Writes

    func testSetSendsOnePutWithTheClosedBodyUnderTheActingProfile() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()

        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.setRating(contentId: "movie:a/b", to: 7, api: api, tokens: tokens, holds: holds)
        }

        XCTAssertEqual(outcome, .applied)
        let sent = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(encodedPath(sent), "/api/v2/ratings/movie:a%2Fb")
        XCTAssertEqual(sent.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.body)) as? [String: Any])
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["rating"] as? Int, 7)
    }

    func testRemoveSendsOneDeleteWithNoBody() async throws {
        let (api, tokens) = try await client()

        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.setRating(contentId: "movie:one", to: nil, api: api, tokens: tokens,
                                                  holds: PersonalStateHolds())
        }

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(stub.methods, ["DELETE"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/ratings/movie:one"])
        XCTAssertEqual(stub.requests.first?.header("X-Profile-Id"), "profile-one")
        XCTAssertNil(stub.requests.first?.body)
    }

    func testOnlyAnExact204Counts() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        stub.reply(200, "{}")

        do {
            try await api.setRating(id: "movie:one", score: 4, auth: owner)
            XCTFail("a 200 is not the contract's answer")
        } catch APIv2Error.httpStatus(let status) {
            XCTAssertEqual(status, 200)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testAnUnansweredWriteIsHeldAndNeverReplayed() async throws {
        let (api, tokens) = try await client()
        let holds = PersonalStateHolds()
        stub.fail(.networkConnectionLost)

        let first = await PersonalStateSync.outcome {
            try await PersonalStateSync.setRating(contentId: "movie:one", to: 8, api: api, tokens: tokens, holds: holds)
        }
        guard case .held(let change) = first else { return XCTFail("expected a hold, got \(first)") }
        XCTAssertEqual(change.target, .rating)

        stub.reply(204, "")
        let removal = await PersonalStateSync.outcome {
            try await PersonalStateSync.setRating(contentId: "movie:one", to: nil, api: api, tokens: tokens, holds: holds)
        }
        XCTAssertEqual(removal, .held(change), "the hold covers setting and removing")
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testBothWritesAreNeverReplayedAfterARefresh() {
        for method in ["PUT", "DELETE"] {
            let operation = APIv2MutationCatalog.operation(method: method, path: "/api/v2/ratings/movie:one")
            XCTAssertEqual(operation?.retrySafety, .nonRetryable, method)
            XCTAssertEqual(operation?.replaysAfterRefresh, false, method)
        }
    }

    // MARK: - Title page

    func testChangeShowsAtOnceAndStaysWhenTheServerAccepts() async throws {
        let model = try await loadedModel(rating: 6)
        let sender = RatingSender(holding: true)

        let write = Task { await model.setRating(9, send: sender.send) }
        await sender.waitForSends(1)
        XCTAssertEqual(model.userRating, 9, "shown before the server answers")
        sender.release()
        await write.value

        XCTAssertEqual(sender.sent, [9])
        XCTAssertEqual(model.userRating, 9)
        XCTAssertNil(model.personalStateNotice)
    }

    func testFailureRevertsToTheConfirmedValueAndRaisesTheNotice() async throws {
        let model = try await loadedModel(rating: 6)
        let sender = RatingSender(outcomes: [.failed(nil)])

        await model.setRating(nil, send: sender.send)

        XCTAssertEqual(sender.sent, [nil])
        XCTAssertEqual(model.userRating, 6)
        XCTAssertEqual(model.personalStateNotice, .failed(nil))
    }

    func testAnUnansweredWriteRevertsAndOffersTheHeldChange() async throws {
        let model = try await loadedModel(rating: nil)
        let (_, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let change = PersonalStateHeldChange(id: UUID(), owner: owner, target: .rating, contentId: seriesId,
                                             included: true)
        let sender = RatingSender(outcomes: [.held(change)])

        await model.setRating(4, send: sender.send)

        XCTAssertNil(model.userRating)
        XCTAssertEqual(model.personalStateNotice, .held(change))
    }

    func testOnlyTheNewestValueChosenDuringAWriteIsSentAfterIt() async throws {
        let model = try await loadedModel(rating: nil)
        let sender = RatingSender(holding: true)

        let write = Task { await model.setRating(6, send: sender.send) }
        await sender.waitForSends(1)
        await model.setRating(8, send: sender.send)
        await model.setRating(nil, send: sender.send)
        await model.setRating(3, send: sender.send)
        XCTAssertEqual(sender.sent, [6], "never two in flight")
        XCTAssertEqual(model.userRating, 3)
        sender.release()
        await write.value

        XCTAssertEqual(sender.sent, [6, 3])
        XCTAssertEqual(model.userRating, 3)
    }

    func testAQueuedValueEqualToTheConfirmedOneSendsNothing() async throws {
        let model = try await loadedModel(rating: 6)
        let sender = RatingSender(holding: true)

        let write = Task { await model.setRating(8, send: sender.send) }
        await sender.waitForSends(1)
        await model.setRating(2, send: sender.send)
        await model.setRating(8, send: sender.send)
        sender.release()
        await write.value

        XCTAssertEqual(sender.sent, [8])
        XCTAssertEqual(model.userRating, 8)

        await model.setRating(8, send: sender.send)
        XCTAssertEqual(sender.sent, [8], "an unchanged value sends nothing")
    }

    func testAFailedWriteDropsTheQueuedValue() async throws {
        let model = try await loadedModel(rating: 6)
        let sender = RatingSender(holding: true, outcomes: [.failed(nil)])

        let write = Task { await model.setRating(8, send: sender.send) }
        await sender.waitForSends(1)
        await model.setRating(10, send: sender.send)
        sender.release()
        await write.value

        XCTAssertEqual(sender.sent, [8])
        XCTAssertEqual(model.userRating, 6)
        XCTAssertEqual(model.personalStateNotice, .failed(nil))
    }

    func testALoadThatBeganBeforeTheChangeCannotOverwriteIt() async throws {
        let model = try await loadedModel(rating: 6)
        let gate = DetailGate()
        let stale = try seriesDetail(rating: 6)

        let reload = Task {
            await model.loadDetail(
                contentId: seriesId,
                fetchDetail: { _ in await gate.wait() },
                fetchSeasons: { _ in SeasonsResponse(seasons: []) },
                fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
            )
        }
        await gate.waitUntilRequested()
        await model.setRating(9, send: RatingSender().send)
        await gate.finish(stale)
        await reload.value

        XCTAssertEqual(model.userRating, 9)
    }

    func testOnlyLoadedMoviesAndSeriesCanBeRated() async throws {
        let model = ItemDetailViewModel()
        let episode = try JSONDecoder().decode(ItemDetail.self, from: Data(
            #"{"contentId":"personal-rating-episode","type":"episode","title":"Pilot"}"#.utf8))
        await model.loadDetail(
            contentId: "personal-rating-episode",
            fetchDetail: { _ in episode },
            fetchSeasons: { _ in SeasonsResponse(seasons: []) },
            fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
        )
        let sender = RatingSender()

        await model.setRating(8, send: sender.send)

        XCTAssertFalse(model.canRate)
        XCTAssertEqual(sender.sent, [])
        XCTAssertNil(model.userRating)
        ResponseCache.shared.removeItemMetadata(contentId: "personal-rating-episode")
    }

    // MARK: - Score math

    func testTrackMapsToHalfStarsAndClamps() {
        let cell: CGFloat = 36
        let expected: [(CGFloat, Int)] = [
            (-20, 0), (0, 0), (3.9, 0), (4, 1), (18, 1), (18.1, 2), (36, 2), (36.5, 3),
            (162, 9), (180, 10), (400, 10),
        ]
        for (x, value) in expected {
            XCTAssertEqual(RatingScore.fromTrack(x: x, cellWidth: cell).value, value, "x = \(x)")
        }
        XCTAssertEqual(RatingScore.fromTrack(x: 28, cellWidth: 28).value, 2, "the cell width is a parameter")
    }

    func testRightToLeftMeasuresFromTheFirstStarOnTheRight() {
        let leading = RatingScore.leadingOffset(x: 170, width: 180, isRightToLeft: true)
        XCTAssertEqual(RatingScore.fromTrack(x: leading, cellWidth: 36).value, 1)
        XCTAssertEqual(RatingScore.leadingOffset(x: 170, width: 180, isRightToLeft: false), 170)
    }

    func testTapFillsTheWholeStarAndTheCurrentWholeStarStepsToItsHalf() {
        XCTAssertEqual(RatingScore.tapped(starIndex: 2, current: .none).value, 6)
        XCTAssertEqual(RatingScore.tapped(starIndex: 2, current: RatingScore(6)).value, 5)
        XCTAssertEqual(RatingScore.tapped(starIndex: 2, current: RatingScore(5)).value, 6)
        XCTAssertEqual(RatingScore.tapped(starIndex: 4, current: RatingScore(10)).value, 9)
        XCTAssertEqual(RatingScore.tapped(starIndex: 0, current: RatingScore(2)).value, 1)
        XCTAssertEqual(RatingScore.tapped(x: 500, cellWidth: 36, current: .none).value, 10, "past the end is the last star")
        XCTAssertEqual(RatingScore.tapped(x: -8, cellWidth: 36, current: .none).value, 2, "before it is the first")
    }

    func testStepsClampAndStarsFill() {
        XCTAssertEqual(RatingScore(10).steppedUp.value, 10)
        XCTAssertEqual(RatingScore.none.steppedDown.value, 0)
        XCTAssertEqual(RatingScore(7).steppedUp.value, 8)
        XCTAssertEqual(RatingScore(7).stars, 3.5)
        XCTAssertNil(RatingScore.none.serverValue)
        XCTAssertEqual((0..<5).map { RatingScore(7).fill(ofStar: $0) }, [.full, .full, .full, .half, .empty])
    }

    func testDisplayUsesTheLocalesDecimalSeparator() {
        XCTAssertEqual(RatingScore(8).display(locale: Locale(identifier: "en_US")), "4")
        XCTAssertEqual(RatingScore(9).display(locale: Locale(identifier: "en_US")), "4.5")
        XCTAssertEqual(RatingScore(9).display(locale: Locale(identifier: "de_DE")), "4,5")
    }

    // MARK: - Helpers

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "PersonalRatingTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://ratings.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private func encodedPath(_ request: StubURLProtocol.Request) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
    }

    /// A minimal v2 movie detail with `extraFields` spliced in.
    private func catalogDetail(_ extraFields: String) throws -> ItemDetail {
        let extra = extraFields.isEmpty ? "" : "," + extraFields
        let body = #"{"content_id":"movie:rated","type":"movie","title":"Rated","status":"available","genres":[],"cast":[],"crew":[],"versions":[],"subtitles":[]\#(extra)}"#
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: Data(body.utf8))
        return try ItemDetail(catalog: wire)
    }

    private func seriesDetail(rating: Int?) throws -> ItemDetail {
        let field = rating.map { #","userRating":\#($0)"# } ?? ""
        return try JSONDecoder().decode(ItemDetail.self, from: Data(
            #"{"contentId":"personal-rating-series","type":"series","title":"Rated Series"\#(field)}"#.utf8))
    }

    /// A series page loaded from an injected detail, so nothing reaches the
    /// network.
    private func loadedModel(rating: Int?) async throws -> ItemDetailViewModel {
        let model = ItemDetailViewModel()
        let detail = try seriesDetail(rating: rating)
        await model.loadDetail(
            contentId: seriesId,
            fetchDetail: { _ in detail },
            fetchSeasons: { _ in SeasonsResponse(seasons: []) },
            fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
        )
        XCTAssertTrue(model.canRate)
        XCTAssertEqual(model.userRating, rating)
        return model
    }
}

/// Stands in for the network write: records each score, answers with the
/// queued outcomes (then `.applied`), and can hold every send until
/// `release()`.
@MainActor
private final class RatingSender {
    private(set) var sent: [Int?] = []
    private var outcomes: [PersonalStateOutcome]
    private var holding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool = false, outcomes: [PersonalStateOutcome] = []) {
        self.holding = holding
        self.outcomes = outcomes
    }

    func send(_ contentId: String, _ score: Int?) async -> PersonalStateOutcome {
        sent.append(score)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return outcomes.isEmpty ? .applied : outcomes.removeFirst()
    }

    func waitForSends(_ count: Int) async {
        while sent.count < count { await Task.yield() }
    }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

/// Holds an injected detail fetch until the test finishes it.
private actor DetailGate {
    private var value: ItemDetail?
    private var waiters: [CheckedContinuation<ItemDetail, Never>] = []
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> ItemDetail {
        requested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters = []
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(_ value: ItemDetail) {
        self.value = value
        waiters.forEach { $0.resume(returning: value) }
        waiters = []
    }
}
