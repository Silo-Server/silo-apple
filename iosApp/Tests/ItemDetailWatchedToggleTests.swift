import XCTest
@testable import Silo

/// Holds a fetch or a write open until the test releases it.
private actor WatchedToggleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A detail load that may have read `played` before a watched change on the
/// page must not undo that change. Every personal-state write goes through
/// the injected `send`, so nothing reaches a signed-in server.
@MainActor
final class ItemDetailWatchedToggleTests: XCTestCase {
    private let itemId = "watched-race"
    private let nextItemId = "watched-race-next"

    func testWatchedTapSurvivesALoadThatStartedBeforeIt() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)
        let gate = WatchedToggleGate()
        let fetchStarted = expectation(description: "detail requested")
        let load = Task {
            await model.loadDetail(contentId: itemId, fetchDetail: { id in
                fetchStarted.fulfill()
                await gate.wait()
                return try syntheticDetail(id, played: false)
            })
        }
        await fulfillment(of: [fetchStarted], timeout: 5)

        await model.toggleWatched(send: { _, _ in .applied })
        await gate.open()
        await load.value

        XCTAssertTrue(model.isWatched)
    }

    func testLoadDuringTheWriteCannotRevertTheConfirmedChange() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)
        let gate = WatchedToggleGate()
        let sendStarted = expectation(description: "watched change sent")
        let tap = Task {
            await model.toggleWatched(send: { _, _ in
                sendStarted.fulfill()
                await gate.wait()
                return .applied
            })
        }
        await fulfillment(of: [sendStarted], timeout: 5)

        // Read before the server committed the change.
        await model.loadDetail(contentId: itemId, fetchDetail: { id in try syntheticDetail(id, played: false) })
        await gate.open()
        await tap.value

        XCTAssertTrue(model.isWatched)
    }

    func testLoadAfterTheChangeAdoptsTheServerValue() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)

        await model.toggleWatched(send: { _, _ in .applied })
        XCTAssertTrue(model.isWatched)

        // Unmarked elsewhere after the change landed.
        await model.loadDetail(contentId: itemId, fetchDetail: { id in try syntheticDetail(id, played: false) })

        XCTAssertFalse(model.isWatched)
    }

    func testFailedChangeStillReverts() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)
        let gate = WatchedToggleGate()
        let fetchStarted = expectation(description: "detail requested")
        let load = Task {
            await model.loadDetail(contentId: itemId, fetchDetail: { id in
                fetchStarted.fulfill()
                await gate.wait()
                return try syntheticDetail(id, played: false)
            })
        }
        await fulfillment(of: [fetchStarted], timeout: 5)

        await model.toggleWatched(send: { _, _ in .failed(nil) })
        await gate.open()
        await load.value

        XCTAssertFalse(model.isWatched)
        XCTAssertNotNil(model.personalStateNotice)
    }

    /// The page moves to another item while the first item's change is in
    /// flight, and the change confirms before the new item's load lands.
    func testConfirmedChangeOnAnEarlierItemDoesNotBlockTheNextItem() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)
        let writeGate = WatchedToggleGate()
        let fetchGate = WatchedToggleGate()
        let sendStarted = expectation(description: "watched change sent")
        let tap = Task {
            await model.toggleWatched(send: { _, _ in
                sendStarted.fulfill()
                await writeGate.wait()
                return .applied
            })
        }
        await fulfillment(of: [sendStarted], timeout: 5)

        let fetchStarted = expectation(description: "next item requested")
        let load = Task {
            await model.loadDetail(contentId: nextItemId, fetchDetail: { id in
                fetchStarted.fulfill()
                await fetchGate.wait()
                return try syntheticDetail(id, played: false)
            })
        }
        await fulfillment(of: [fetchStarted], timeout: 5)

        await writeGate.open()
        await tap.value
        await fetchGate.open()
        await load.value

        XCTAssertEqual(model.detail?.contentId, nextItemId)
        XCTAssertFalse(model.isWatched)
    }

    /// Same move, but the new item's load lands before the first item's
    /// change confirms.
    func testConfirmedChangeOnAnEarlierItemDoesNotOverwriteTheNextItem() async throws {
        clearCache()
        defer { clearCache() }
        let model = try hydratedModel(played: false)
        let writeGate = WatchedToggleGate()
        let sendStarted = expectation(description: "watched change sent")
        let tap = Task {
            await model.toggleWatched(send: { _, _ in
                sendStarted.fulfill()
                await writeGate.wait()
                return .applied
            })
        }
        await fulfillment(of: [sendStarted], timeout: 5)

        await model.loadDetail(contentId: nextItemId, fetchDetail: { id in try syntheticDetail(id, played: false) })
        await writeGate.open()
        await tap.value

        XCTAssertEqual(model.detail?.contentId, nextItemId)
        XCTAssertFalse(model.isWatched)
    }

    // MARK: - Fixtures

    /// An episode page painted from cache. Episodes skip `/watch` enrichment
    /// and have no season structure, so loads make no network requests.
    private func hydratedModel(played: Bool) throws -> ItemDetailViewModel {
        ResponseCache.shared.set(try syntheticDetail(itemId, played: played), for: CacheKey.itemDetail(itemId))
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: itemId)
        XCTAssertEqual(model.detail?.contentId, itemId)
        XCTAssertEqual(model.isWatched, played)
        return model
    }

    /// The prefix also covers the user-state and watch-detail keys.
    private func clearCache() {
        ResponseCache.shared.removeAll(withPrefix: CacheKey.itemDetail(itemId))
        ResponseCache.shared.removeAll(withPrefix: CacheKey.itemDetail(nextItemId))
    }
}

private func syntheticDetail(_ contentId: String, played: Bool) throws -> ItemDetail {
    try JSONDecoder().decode(ItemDetail.self, from: Data(
        "{\"contentId\":\"\(contentId)\",\"type\":\"episode\",\"title\":\"Synthetic\",\"userData\":{\"played\":\(played)}}".utf8
    ))
}
