import XCTest
@testable import Silo

final class MyRequestsBucketTests: XCTestCase {
    private func record(
        id: String,
        status: RequestStatus,
        outcome: RequestOutcome = .active,
        state: RequestUserState? = nil,
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
            state: state,
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

        XCTAssertEqual(buckets.map(\.bucket), [.inMotion, .needsAttention, .landed])
        XCTAssertEqual(buckets[0].requests.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(buckets[1].requests.map(\.id).sorted(), ["d", "e"])
        XCTAssertEqual(buckets[2].requests.map(\.id), ["c"])
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

    func testFinishedDownloadStaysInMotionUntilTheLibraryHasIt() throws {
        // `/requests/mine` records as the server sends them: both downloads
        // finished, only one title has been found by the library scan.
        func wire(_ id: String, _ state: String) -> String {
            #"{"id":"\#(id)","provider":"tmdb","media_type":"movie","tmdb_id":1,"title":"\#(id)","status":"completed","outcome":"active","state":"\#(state)","is_anime":false,"targets":[],"created_at":"2026-01-02T03:04:05.000Z","updated_at":"2026-01-02T03:04:05.000Z"}"#
        }
        let json = "[\(wire("up", "processing")),\(wire("heat", "available"))]"
        let records = try HTTPClient.makeJSONDecoder().decode([MediaRequest].self, from: Data(json.utf8))

        let buckets = MyRequestsBucket.bucket(records)

        XCTAssertEqual(buckets.map(\.bucket), [.inMotion, .landed])
        XCTAssertEqual(buckets.first?.requests.map(\.id), ["up"])
        XCTAssertEqual(buckets.last?.requests.map(\.id), ["heat"])
    }

    func testPartlyAvailableSeasonRequestStaysInMotion() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "a", status: .completed, state: .partiallyAvailable)
        ])
        XCTAssertEqual(buckets.map(\.bucket), [.inMotion])
    }

    func testNewestFirstWithinBucket() {
        let buckets = MyRequestsBucket.bucket([
            record(id: "old", status: .pending, createdAt: Date(timeIntervalSince1970: 100)),
            record(id: "new", status: .pending, createdAt: Date(timeIntervalSince1970: 200)),
        ])
        XCTAssertEqual(buckets[0].requests.map(\.id), ["new", "old"])
    }
}
