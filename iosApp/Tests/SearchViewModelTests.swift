import Foundation
import Observation
import XCTest
@testable import Silo

/// Search state is read by SwiftUI on the main thread, so every write must
/// happen there too: the debounced keystroke search, retry, filter change and
/// load-more. Observation calls `onChange` from the property's `willSet` on
/// the writing thread, which is what these tests record.
@MainActor
final class SearchViewModelTests: XCTestCase {
    private let firstPage = #"{"items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}],"page":{"has_more":true,"next_cursor":"cursor-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
    private let lastPage = #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin"}],"page":{"has_more":false},"total":2,"total_exact":true,"window_cursor":"w"}"#

    private func client(stub: APIv2TestStub) async throws -> SiloAPI {
        let name = "SearchViewModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "search-vm-test")
        await tokens.setServerUrl("https://search.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens)
    }

    func testSearchAndLoadMorePublishOnTheMainThread() async throws {
        let stub = APIv2TestStub()
        let model = SearchViewModel(api: try await client(stub: stub))
        stub.sequence([.json(200, firstPage), .json(200, lastPage)])
        model.query = "heat"
        let log = ThreadLog()

        withObservationTracking { _ = model.isSearching } onChange: { log.recordCurrentThread() }
        withObservationTracking { _ = model.results } onChange: { log.recordCurrentThread() }
        await model.performSearch()

        XCTAssertEqual(log.entries.count, 2, "isSearching and results each change once")
        XCTAssertTrue(log.entries.allSatisfy { $0 }, "search state changed off the main thread: \(log.entries)")
        XCTAssertEqual(model.results.map(\.contentId), ["movie:heat"])
        XCTAssertTrue(model.hasMore)

        withObservationTracking { _ = model.results } onChange: { log.recordCurrentThread() }
        await model.loadMore()

        XCTAssertEqual(log.entries.count, 3, "load more appends to results once")
        XCTAssertTrue(log.entries.allSatisfy { $0 }, "load more changed results off the main thread: \(log.entries)")
        XCTAssertEqual(model.results.map(\.contentId), ["movie:heat", "movie:ronin"])
    }

    func testDebouncedQueryChangePublishesOnTheMainThread() async throws {
        let stub = APIv2TestStub()
        let model = SearchViewModel(api: try await client(stub: stub))
        stub.reply(200, lastPage)
        model.query = "heat"
        let log = ThreadLog()
        let published = expectation(description: "the debounced search publishes results")

        withObservationTracking { _ = model.results } onChange: {
            log.recordCurrentThread()
            published.fulfill()
        }
        model.onQueryChanged()
        await fulfillment(of: [published], timeout: 3)

        XCTAssertEqual(log.entries, [true], "the debounced search changed results off the main thread")
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.hasSearched, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.results.map(\.contentId), ["movie:ronin"])
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(stub.requests.map { $0.query["q"] }, ["heat"])
    }
}

/// Which thread each observed change ran on. `onChange` is `@Sendable` and
/// may run on any thread, so the log is lock-protected.
private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    /// Call only from the synchronous `onChange` closure.
    func recordCurrentThread() {
        let isMain = Thread.isMainThread
        lock.withLock { values.append(isMain) }
    }

    var entries: [Bool] { lock.withLock { values } }
}
