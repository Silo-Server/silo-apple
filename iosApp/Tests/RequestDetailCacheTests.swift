import XCTest
@testable import Silo

/// The approval pin decides which request an admin's Approve, Decline, or
/// Retry targets, so a decided request must never keep it.
@MainActor
final class RequestDetailCacheTests: XCTestCase {
    private func record(id: String, tmdbId: Int = 1) -> MediaRequest {
        MediaRequest(
            id: id, mediaType: .movie, tmdbId: tmdbId, title: "Title", year: 2026,
            overview: nil, posterPath: nil, backdropPath: nil,
            status: .pending, outcome: .active, state: .pending, targets: nil,
            libraryContentId: nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            completedAt: nil
        )
    }

    private let key = RequestDetailCache.Key(mediaType: .movie, tmdbId: 1)

    func testAPinSurvivesWhileItsRequestIsStillQueued() {
        let cache = RequestDetailCache()
        cache.pinModeration(record(id: "a"))
        cache.storeModerationRecords([record(id: "a"), record(id: "b")])
        XCTAssertEqual(cache.pinnedModerationRecord(key)?.id, "a")
    }

    func testAPinDropsWhenAFullReadNoLongerListsIt() {
        let cache = RequestDetailCache()
        cache.pinModeration(record(id: "a"))
        cache.storeModerationRecords([record(id: "b")])
        XCTAssertNil(cache.pinnedModerationRecord(key))
    }

    func testAPinDropsWhenItsDecisionIsPublished() {
        let cache = RequestDetailCache()
        cache.pinModeration(record(id: "a"))
        cache.unpinModeration(record(id: "b"))
        XCTAssertEqual(cache.pinnedModerationRecord(key)?.id, "a", "another request's decision leaves the pin")
        cache.unpinModeration(record(id: "a"))
        XCTAssertNil(cache.pinnedModerationRecord(key))
    }
}

/// A lost approve/decline/retry may still be running when the next read
/// lands, so only a changed or departed request releases its hold.
final class ModerationHoldTests: XCTestCase {
    private func record(id: String = "a", updatedAt: TimeInterval = 0) -> MediaRequest {
        MediaRequest(
            id: id, mediaType: .movie, tmdbId: 1, title: "Title", year: 2026,
            overview: nil, posterPath: nil, backdropPath: nil,
            status: .pending, outcome: .active, state: .pending, targets: nil,
            libraryContentId: nil, lastError: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updatedAt),
            completedAt: nil
        )
    }

    func testAnUnchangedRequestKeepsTheHold() {
        let start = Date(timeIntervalSince1970: 1_000)
        let hold = ModerationHold(request: record(), since: start)
        XCTAssertFalse(hold.isSettled(by: record(), now: start.addingTimeInterval(5)))
    }

    func testAChangedOrDepartedRequestReleasesIt() {
        let start = Date(timeIntervalSince1970: 1_000)
        let hold = ModerationHold(request: record(), since: start)
        XCTAssertTrue(hold.isSettled(by: record(updatedAt: 10), now: start))
        XCTAssertTrue(hold.isSettled(by: nil, now: start))
    }

    func testAnUnchangedRequestReleasesItOnceTheLifetimeEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let hold = ModerationHold(request: record(), since: start)
        XCTAssertTrue(hold.isSettled(by: record(), now: start.addingTimeInterval(ModerationHold.lifetime)))
    }
}
