import XCTest
@testable import Silo

/// A detail page that stays open while another device plays must offer and
/// resume from the server's newer position, not the page's snapshot.
final class DetailResumeStateTests: XCTestCase {

    private struct FetchFailure: Error {}

    /// Builds watch state the way `watchDetail` does: the server's
    /// snake_case `user_data` through the production decoder and projection.
    private func userData(position: Double?, duration: Double? = 2700) throws -> LeafItemUserData {
        var object: [String: Any] = [
            "played": false, "watched_count": 0, "unplayed_count": 1, "in_progress_count": 0,
        ]
        if let position { object["position_seconds"] = position }
        if let duration { object["duration_seconds"] = duration }
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.WatchRollup.self, from: data)
        return try LeafItemUserData(catalog: wire)
    }

    // MARK: - resumePosition(cached:)

    func testServerPositionWinsOverStaleSnapshot() throws {
        let cached = try userData(position: 307)
        let state = DetailResumeState.refreshed(try userData(position: 1210))
        XCTAssertEqual(state.resumePosition(cached: cached), 1210)
    }

    func testServerWithoutProgressSuppressesStaleResume() throws {
        let cached = try userData(position: 307)
        XCTAssertNil(DetailResumeState.refreshed(nil).resumePosition(cached: cached))
        XCTAssertNil(
            DetailResumeState.refreshed(try userData(position: nil)).resumePosition(cached: cached)
        )
    }

    func testServerProgressOffersResumeWhenSnapshotHadNone() throws {
        let state = DetailResumeState.refreshed(try userData(position: 1210))
        XCTAssertEqual(state.resumePosition(cached: nil), 1210)
    }

    func testServerPositionNearEndIsNotOffered() throws {
        let cached = try userData(position: 307)
        let state = DetailResumeState.refreshed(try userData(position: 2698, duration: 2700))
        XCTAssertNil(state.resumePosition(cached: cached))
    }

    func testUnavailableFallsBackToSnapshot() throws {
        let cached = try userData(position: 307)
        XCTAssertEqual(DetailResumeState.unavailable.resumePosition(cached: cached), 307)
        XCTAssertNil(DetailResumeState.unavailable.resumePosition(cached: nil))
    }

    // MARK: - load

    func testLoadReturnsFetchedWatchState() async throws {
        let fresh = try userData(position: 1210)
        let state = await DetailResumeState.load { fresh }
        XCTAssertEqual(state, .refreshed(fresh))
    }

    func testLoadKeepsServerAnswerOfNoWatchState() async {
        let state = await DetailResumeState.load { nil }
        XCTAssertEqual(state, .refreshed(nil))
    }

    func testLoadMapsFailureToUnavailable() async {
        let state = await DetailResumeState.load { throw FetchFailure() }
        XCTAssertEqual(state, .unavailable)
    }

    func testLoadTimesOutToUnavailable() async throws {
        let fresh = try userData(position: 1210)
        let started = ContinuousClock.now
        let state = await DetailResumeState.load(timeout: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(30))
            return fresh
        }
        XCTAssertEqual(state, .unavailable)
        // The stalled fetch is cancelled rather than awaited to completion.
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testLoadTimesOutWhenFetchIgnoresCancellation() async throws {
        let fresh = try userData(position: 1210)
        let started = ContinuousClock.now
        let state = await DetailResumeState.load(timeout: .milliseconds(50)) {
            // Joining an unstructured task, as a shared token-refresh flight
            // does, keeps the fetch waiting after it is cancelled.
            await Task { try? await Task.sleep(for: .seconds(5)) }.value
            return fresh
        }
        XCTAssertEqual(state, .unavailable)
        // The fallback arrives on time instead of after the stray fetch.
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testCancellingTheCallerReturnsUnavailableWithoutWaitingForFetch() async {
        let started = ContinuousClock.now
        let lookup = Task {
            await DetailResumeState.load(timeout: .seconds(30)) {
                await Task { try? await Task.sleep(for: .seconds(5)) }.value
                return nil
            }
        }
        lookup.cancel()
        let state = await lookup.value
        XCTAssertEqual(state, .unavailable)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }
}
