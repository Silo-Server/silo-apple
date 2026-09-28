import XCTest
@testable import Silo

/// The request detail page's status line. A failed request must not read as
/// declined, and a title's requestability code (`already_requested`, …) is
/// not the reason a request failed or was declined.
final class RequestDetailStatusTitleTests: XCTestCase {
    private func detailTitle(
        availability: RequestAvailability = .missing,
        status: RequestStatus?,
        state: RequestUserState?,
        reason: String? = "already_requested"
    ) -> String? {
        let request = RequestState(status: status, state: state, requestable: false, reason: reason, requestId: "request-1")
        return RequestDisplayState(availability: availability, request: request)?.detailTitle
    }

    private func record(outcome: RequestOutcome, state: RequestUserState?, lastError: String?) -> MediaRequest {
        let date = Date(timeIntervalSince1970: 0)
        return MediaRequest(
            id: "request-1", mediaType: .movie, tmdbId: 949, title: "Heat", year: 1995,
            overview: nil, posterPath: nil, backdropPath: nil,
            status: .queued, outcome: outcome, state: state, targets: nil,
            libraryContentId: nil, lastError: lastError,
            createdAt: date, updatedAt: date, completedAt: nil
        )
    }

    func testFailedRequestReadsAsFailedWithoutTheRequestabilityCode() {
        XCTAssertEqual(detailTitle(status: .queued, state: .failed), "Request failed")
        // A series in the library with a failed request for its missing seasons.
        XCTAssertEqual(detailTitle(availability: .available, status: .queued, state: .failed), "Request failed")
    }

    func testDeclinedRequestReadsAsDeclinedWithoutTheRequestabilityCode() {
        XCTAssertEqual(detailTitle(status: .pending, state: .declined), "Declined")
    }

    func testRecordsKeepTheirOwnReasonAndKind() {
        // Servers without `state` decide from `outcome`.
        XCTAssertEqual(
            RequestDisplayState(record: record(outcome: .declined, state: nil, lastError: "no space")).detailTitle,
            "Declined · No space"
        )
        XCTAssertEqual(
            RequestDisplayState(record: record(outcome: .failed, state: nil, lastError: "grab failed")).detailTitle,
            "Request failed · Grab failed"
        )
        XCTAssertEqual(
            RequestDisplayState(record: record(outcome: .failed, state: .failed, lastError: "grab failed")).detailTitle,
            "Request failed · Grab failed"
        )
    }

    func testTitleWithoutARequestStillShowsWhyItCantBeRequested() {
        XCTAssertEqual(detailTitle(status: nil, state: nil, reason: "quota_exceeded"), "Request limit reached")
    }
}
