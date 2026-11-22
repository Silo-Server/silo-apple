import Foundation
import XCTest
@testable import Silo

/// Open Requests screens close once the server answers that requests are
/// unavailable (1.0 Requests AC7), back to whatever opened them, and never
/// while the answer is unknown or after a failed probe.
@MainActor
final class RequestsScreensCloseTests: XCTestCase {
    private struct ProbeFailed: Error {}

    private static func status(available: Bool) -> RequestsFeatureStatus {
        RequestsFeatureStatus(requestsEnabled: available, state: available ? "available" : "disabled", allowed: true)
    }

    // MARK: Which routes close

    func testOnlyTheRequestsPagesOnTopClose() {
        XCTAssertEqual(RequestsRouteVisibility.requestsRoutesOnTop(
            [.settings, .requestsHub, .myRequests, .requestDetail(mediaType: .movie, tmdbId: 949)]), 3)
        XCTAssertEqual(RequestsRouteVisibility.requestsRoutesOnTop(
            [.requestsHub, .requestDiscoverRow(key: "r_anime", title: "Anime")]), 2)
        // A title opened from Requests stays in view; the hub under it waits.
        XCTAssertEqual(RequestsRouteVisibility.requestsRoutesOnTop(
            [.requestsHub, .itemDetail(contentId: "movie-1")]), 0)
        XCTAssertEqual(RequestsRouteVisibility.requestsRoutesOnTop(
            [.requestsHub, .itemDetail(contentId: "movie-1"), .requestDetail(mediaType: .series, tmdbId: 1399)]), 1)
        XCTAssertEqual(RequestsRouteVisibility.requestsRoutesOnTop([]), 0)
    }

    // MARK: When they close

    func testOnlyAnAnsweredUnavailableProbeCountsAsOff() async {
        var next: Result<RequestsFeatureStatus, Error> = .failure(ProbeFailed())
        let store = RequestsFeatureStore(probe: { try next.get() })
        XCTAssertFalse(store.isKnownUnavailable, "unknown before the first answer")

        await store.refresh()
        XCTAssertFalse(store.isKnownUnavailable, "a failed first probe is still unknown")

        next = .success(Self.status(available: true))
        await store.refresh()
        XCTAssertFalse(store.isKnownUnavailable)

        next = .failure(ProbeFailed())
        await store.refresh()
        XCTAssertTrue(store.isEnabled, "a transient failure keeps the open screens")
        XCTAssertFalse(store.isKnownUnavailable)

        next = .success(Self.status(available: false))
        await store.refresh()
        XCTAssertTrue(store.isKnownUnavailable)

        store.reset()
        XCTAssertFalse(store.isKnownUnavailable, "a reset (profile or server switch) is unknown again")
    }

    func testAProbeFromBeforeAResetIsDiscarded() async {
        var store: RequestsFeatureStore!
        store = RequestsFeatureStore(probe: {
            // The profile switches while this probe is in flight.
            store.reset()
            return Self.status(available: false)
        })
        await store.refresh()
        XCTAssertFalse(store.isKnownUnavailable)
    }

    func testAnOlderProbeCannotOverwriteANewerAnswer() async {
        var parked: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = RequestsFeatureStore(probe: {
            calls += 1
            guard calls == 1 else { return Self.status(available: false) }
            // The first probe answers "available" only after a newer one.
            await withCheckedContinuation { parked = $0 }
            return Self.status(available: true)
        })
        let older = Task { await store.refresh() }
        while parked == nil { await Task.yield() }

        await store.refresh()
        XCTAssertTrue(store.isKnownUnavailable)
        parked?.resume()
        await older.value
        XCTAssertTrue(store.isKnownUnavailable, "the newer disabled answer stands")
    }

    func testANewerProbeThatFailsKeepsAnOlderAnswer() async {
        var parked: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = RequestsFeatureStore(probe: {
            calls += 1
            guard calls == 1 else { throw ProbeFailed() }
            // The first probe answers "disabled" only after a newer one failed.
            await withCheckedContinuation { parked = $0 }
            return Self.status(available: false)
        })
        let older = Task { await store.refresh() }
        while parked == nil { await Task.yield() }

        await store.refresh()
        XCTAssertFalse(store.isResolved)
        parked?.resume()
        await older.value
        XCTAssertTrue(store.isKnownUnavailable, "the older answer is the newest one there is")
    }

    func testOnlyCapabilityOffAndRefusedProblemsTriggerAReprobe() throws {
        func problem(_ id: String) throws -> Error {
            let body = #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(id)","title":"T","status":409,"detail":"d"}"#
            return APIv2Error.problem(try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(body.utf8)))
        }
        for id in ["capability_disabled", "capability_not_configured", "capability_unsupported", "permission_denied"] {
            XCTAssertTrue(RequestsFeatureStore.shouldReprobe(after: try problem(id)), id)
        }
        XCTAssertFalse(RequestsFeatureStore.shouldReprobe(after: try problem("conflict")))
        XCTAssertFalse(RequestsFeatureStore.shouldReprobe(after: ProbeFailed()))
    }

    // MARK: Router

    func testClosingPopsTheRequestsPagesBackToWhatOpenedThem() {
        let router = AppRouter()
        router.navigate(to: .settings)
        router.navigate(to: .requestsHub)
        router.navigate(to: .myRequests)
        router.closeRequestsScreens()
        XCTAssertEqual(router.visiblePushedRoutes, [.settings])
        XCTAssertEqual(router.path.count, 1)
    }

    func testClosingLeavesOtherPagesAlone() {
        let router = AppRouter()
        router.navigate(to: .requestsHub)
        router.navigate(to: .settings)
        router.closeRequestsScreens()
        XCTAssertEqual(router.path.count, 2)

        // Back onto the hub: it closes on the next check.
        router.goBack()
        router.closeRequestsScreens()
        XCTAssertTrue(router.path.isEmpty)
    }

    #if os(iOS)
    func testARequestDetailCardCloses() {
        let router = AppRouter()
        router.navigate(to: .requestsHub)
        router.navigate(to: .requestDetail(mediaType: .movie, tmdbId: 949))
        XCTAssertNotNil(router.presentedItemDetail?.request)

        router.closeRequestsScreens()
        XCTAssertNil(router.presentedItemDetail)
        XCTAssertEqual(router.path.count, 1, "the hub behind the card waits until it is in view")

        router.closeRequestsScreens()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testARequestPagePushedInsideATitleCardPopsOnlyThatPage() {
        let router = AppRouter()
        router.presentItemDetail(contentId: "movie-1")
        router.navigate(to: .requestDetail(mediaType: .movie, tmdbId: 949))
        XCTAssertEqual(router.itemDetailPath.count, 1)

        router.closeRequestsScreens()
        XCTAssertEqual(router.presentedItemDetail?.contentId, "movie-1")
        XCTAssertTrue(router.itemDetailPath.isEmpty)
    }
    #endif
}
