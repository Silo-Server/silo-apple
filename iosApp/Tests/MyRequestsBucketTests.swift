import XCTest
@testable import Silo

final class MyRequestsBucketTests: XCTestCase {
    private func record(
        id: String,
        status: RequestStatus,
        outcome: RequestOutcome = .active,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> MediaRequest {
        MediaRequest(
            id: id,
            mediaType: .movie,
            tmdbId: 1,
            title: "Title \(id)",
            year: 2026,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            status: status,
            outcome: outcome,
            targets: nil,
            libraryContentId: nil,
            lastError: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            completedAt: nil
        )
    }

    func testBucketAssignment() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "a", status: .pending),
            record(id: "b", status: .downloading),
            record(id: "c", status: .completed),
            record(id: "d", status: .pending, outcome: .declined),
            record(id: "e", status: .queued, outcome: .failed),
        ])

        XCTAssertEqual(buckets.map(\.bucket), [.inMotion, .landed, .needsAttention])
        XCTAssertEqual(buckets[0].requests.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(buckets[1].requests.map(\.id), ["c"])
        XCTAssertEqual(buckets[2].requests.map(\.id).sorted(), ["d", "e"])
    }

    func testCancelledRequestsDropOffEntirely() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "a", status: .pending, outcome: .cancelled)
        ])
        XCTAssertTrue(buckets.isEmpty)
    }

    func testEmptyBucketsAreOmitted() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "a", status: .completed)
        ])
        XCTAssertEqual(buckets.map(\.bucket), [.landed])
    }

    func testNewestFirstWithinBucket() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "old", status: .pending, createdAt: Date(timeIntervalSince1970: 100)),
            record(id: "new", status: .pending, createdAt: Date(timeIntervalSince1970: 200)),
        ])
        XCTAssertEqual(buckets[0].requests.map(\.id), ["new", "old"])
    }
}
