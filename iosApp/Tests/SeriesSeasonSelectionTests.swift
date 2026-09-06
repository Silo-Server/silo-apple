import XCTest
@testable import Silo

@MainActor
final class SeriesSeasonSelectionTests: XCTestCase {
    func testCompletedChoiceRemainsAuthoritativeBeforeTheSelectorRedraws() async throws {
        let selection = SeriesSeasonSelection()
        let load = DeferredLoad()
        let displayedSeason = try season(1)
        let newSeason = try season(2)
        selection.select(newSeason, load: load.load) { _ in }
        await fulfillment(of: [load.started], timeout: 2)
        load.finish("s2e1")
        await fulfillment(of: [load.finished], timeout: 2)

        // A queued focus callback can still hold the previous rendered season.
        // Returning to S1 must not be mistaken for a no-op after S2 completes.
        let latestChoice = selection.latestSeasonId ?? displayedSeason.id
        XCTAssertNotEqual(latestChoice, displayedSeason.id)
        XCTAssertEqual(latestChoice, newSeason.id)
    }

    func testRapidReversalOnlyScrollsToLatestChoice() async throws {
        let selection = SeriesSeasonSelection()
        var destinations: [String] = []
        let first = DeferredLoad()
        let second = DeferredLoad()
        let returned = DeferredLoad()
        let season1 = try season(1)
        let season2 = try season(2)

        selection.select(season1, load: first.load) { destinations.append($0) }
        await fulfillment(of: [first.started], timeout: 2)
        selection.select(season2, load: second.load) { destinations.append($0) }
        await fulfillment(of: [second.started], timeout: 2)
        selection.select(season1, load: returned.load) { destinations.append($0) }
        await fulfillment(of: [returned.started], timeout: 2)

        // An old completion cannot clear the newer request, even for the same season.
        first.finish("old-s1e1")
        await fulfillment(of: [first.finished], timeout: 2)
        XCTAssertEqual(selection.latestSeasonId, season1.id)
        XCTAssertTrue(destinations.isEmpty)

        returned.finish("s1e1")
        await fulfillment(of: [returned.finished], timeout: 2)
        second.finish("s2e1")
        await fulfillment(of: [second.finished], timeout: 2)
        XCTAssertEqual(destinations, ["s1e1"])
        XCTAssertEqual(selection.latestSeasonId, season1.id)
    }

    func testEpisodeFocusCancelsPendingSeasonScroll() async throws {
        let selection = SeriesSeasonSelection()
        let load = DeferredLoad()
        var destinations: [String] = []
        selection.select(try season(2), load: load.load) { destinations.append($0) }
        await fulfillment(of: [load.started], timeout: 2)
        selection.cancel()
        load.finish("s2e1")
        await fulfillment(of: [load.finished], timeout: 2)
        XCTAssertTrue(destinations.isEmpty)
        XCTAssertNil(selection.latestSeasonId)
    }

    func testEmptyOrFailedSelectionCanBeRetried() async throws {
        let selection = SeriesSeasonSelection()
        let failed = DeferredLoad()
        let retry = DeferredLoad()
        var destinations: [String] = []
        let target = try season(2)
        selection.select(target, load: failed.load) { destinations.append($0) }
        await fulfillment(of: [failed.started], timeout: 2)
        failed.finish(nil)
        await fulfillment(of: [failed.finished], timeout: 2)
        XCTAssertNil(selection.latestSeasonId)
        XCTAssertTrue(destinations.isEmpty)
        selection.select(target, load: retry.load) { destinations.append($0) }
        await fulfillment(of: [retry.started], timeout: 2)
        retry.finish("s2e1")
        await fulfillment(of: [retry.finished], timeout: 2)
        XCTAssertEqual(destinations, ["s2e1"])
    }

    private func season(_ number: Int) throws -> Season {
        try JSONDecoder().decode(Season.self, from: Data(
            "{\"contentId\":\"season-\(number)\",\"seasonNumber\":\(number)}".utf8
        ))
    }

    /// Deliberately ignores cancellation, like a shared request already in flight.
    private final class DeferredLoad {
        let started = XCTestExpectation(description: "load started")
        let finished = XCTestExpectation(description: "load returned")
        private var continuation: CheckedContinuation<String?, Never>?

        func load(_ season: Season) async -> String? {
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
            finished.fulfill()
            return result
        }

        func finish(_ contentId: String?) {
            continuation?.resume(returning: contentId)
            continuation = nil
        }
    }
}
