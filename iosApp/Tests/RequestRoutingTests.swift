import XCTest
@testable import Silo

/// Where a request card opens: the library item only when its chip reads
/// "In library", so a request still in flight on a title in the library
/// (missing seasons of a series, a failure) stays reachable.
final class RequestRoutingTests: XCTestCase {
    private let requestDetail = Route.requestDetail(mediaType: .series, tmdbId: 1399)
    private let libraryItem = Route.itemDetail(contentId: "series-1")

    private func result(
        availability: RequestAvailability,
        libraryContentId: String? = "series-1",
        status: RequestStatus? = nil,
        state: RequestUserState? = nil,
        requestable: Bool = false
    ) -> RequestMediaResult {
        RequestMediaResult(
            mediaType: .series,
            tmdbId: 1399,
            title: "Series",
            year: 2011,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            voteAverage: nil,
            availability: availability,
            libraryContentId: libraryContentId,
            request: RequestState(status: status, state: state, requestable: requestable, reason: nil, requestId: nil)
        )
    }

    private func record(
        status: RequestStatus,
        outcome: RequestOutcome = .active,
        state: RequestUserState?,
        libraryContentId: String? = "series-1"
    ) -> MediaRequest {
        let date = Date(timeIntervalSince1970: 0)
        return MediaRequest(
            id: "request-1",
            mediaType: .series,
            tmdbId: 1399,
            title: "Series",
            year: 2011,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            status: status,
            outcome: outcome,
            state: state,
            targets: nil,
            libraryContentId: libraryContentId,
            lastError: nil,
            createdAt: date,
            updatedAt: date,
            completedAt: nil
        )
    }

    func testCardOpensTheLibraryOnlyWhenItReadsInLibrary() {
        XCTAssertEqual(Route.requestDestination(for: result(availability: .available)), libraryItem)
        // In the library, with a request for its missing seasons.
        XCTAssertEqual(
            Route.requestDestination(for: result(availability: .available, status: .downloading, state: .processing)),
            requestDetail
        )
        XCTAssertEqual(
            Route.requestDestination(for: result(availability: .available, status: .completed, state: .partiallyAvailable)),
            requestDetail
        )
        XCTAssertEqual(
            Route.requestDestination(for: result(availability: .available, status: .queued, state: .failed)),
            requestDetail
        )
        // A server without `state`: availability decides, as before.
        XCTAssertEqual(Route.requestDestination(for: result(availability: .available, status: .pending)), libraryItem)
        // Nothing to open.
        XCTAssertEqual(Route.requestDestination(for: result(availability: .available, libraryContentId: nil)), requestDetail)
        XCTAssertEqual(
            Route.requestDestination(for: result(availability: .missing, libraryContentId: nil, requestable: true)),
            requestDetail
        )
    }

    func testRecordOpensTheLibraryOnlyWhenItReadsInLibrary() {
        XCTAssertEqual(Route.requestDestination(for: record(status: .completed, state: .available)), libraryItem)
        // The series is in the library; the requested seasons aren't yet.
        XCTAssertEqual(Route.requestDestination(for: record(status: .downloading, state: .processing)), requestDetail)
        XCTAssertEqual(Route.requestDestination(for: record(status: .completed, state: .partiallyAvailable)), requestDetail)
        XCTAssertEqual(
            Route.requestDestination(for: record(status: .queued, outcome: .failed, state: .failed)),
            requestDetail
        )
        // Downloaded, but the library hasn't picked it up.
        XCTAssertEqual(
            Route.requestDestination(for: record(status: .completed, state: .processing, libraryContentId: nil)),
            requestDetail
        )
        // A server without `state`.
        XCTAssertEqual(Route.requestDestination(for: record(status: .completed, state: nil)), libraryItem)
    }
}
