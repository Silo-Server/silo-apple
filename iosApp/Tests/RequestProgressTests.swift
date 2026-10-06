import XCTest
@testable import Silo

/// The stage track is drawn from one mapper on cards, rows, the detail
/// page, and the tvOS marquee; these pin where each server state lands.
final class RequestProgressTests: XCTestCase {
    private func progress(
        state: RequestUserState? = nil,
        status: RequestStatus,
        outcome: RequestOutcome = .active
    ) -> RequestProgress {
        RequestProgress(
            display: RequestDisplayState(state: state, status: status, outcome: outcome),
            state: state,
            status: status
        )
    }

    func testPendingWaitsOnApproval() {
        let p = progress(state: .pending, status: .pending)
        XCTAssertEqual(p.completedSteps, 1)
        XCTAssertEqual(p.currentStep, .approval)
        XCTAssertEqual(p.tint, .amber)
    }

    func testApprovedAndQueuedSitOnDownload() {
        for status in [RequestStatus.approved, .queued] {
            let p = progress(state: .approved, status: status)
            XCTAssertEqual(p.completedSteps, 2)
            XCTAssertEqual(p.currentStep, .download)
        }
    }

    func testDownloadingSitsOnDownload() {
        let p = progress(state: .processing, status: .downloading)
        XCTAssertEqual(p.currentStep, .download)
        XCTAssertEqual(p.tint, .sky)
    }

    func testFinishedDownloadWaitsOnTheLibrary() {
        // `processing` + `completed`: downloaded, not yet in the library.
        let p = progress(state: .processing, status: .completed)
        XCTAssertEqual(p.display, .onTheWay)
        XCTAssertEqual(p.completedSteps, 3)
        XCTAssertEqual(p.currentStep, .library)
    }

    func testPartiallyAvailableSitsOnLibrary() {
        let p = progress(state: .partiallyAvailable, status: .downloading)
        XCTAssertEqual(p.currentStep, .library)
    }

    func testAvailableCompletesTheTrack() {
        let p = progress(state: .available, status: .completed)
        XCTAssertEqual(p.completedSteps, 4)
        XCTAssertNil(p.currentStep)
        XCTAssertEqual(p.tint, .emerald)
    }

    func testDeclinedAndFailedStopWhereTheyBroke() {
        let declined = progress(state: .declined, status: .pending, outcome: .declined)
        XCTAssertEqual(declined.currentStep, .approval)
        XCTAssertEqual(declined.tint, .rose)

        let failed = progress(state: .failed, status: .downloading, outcome: .failed)
        XCTAssertEqual(failed.currentStep, .download)
    }

    func testCancelledLeavesTheTrack() {
        let p = progress(state: .cancelled, status: .pending, outcome: .cancelled)
        XCTAssertEqual(p.completedSteps, 0)
        XCTAssertNil(p.currentStep)
    }

    func testOlderServerWithoutStateStillPlacesDownloads() {
        // Without `state`, the status alone places the request where a
        // current server's state would.
        for (status, state) in [(RequestStatus.downloading, RequestUserState.processing), (.queued, .approved)] {
            let older = progress(status: status)
            let current = progress(state: state, status: status)
            XCTAssertEqual(older.currentStep, current.currentStep, "\(status)")
            XCTAssertEqual(older.shortLabel, current.shortLabel, "\(status)")
        }
    }

    func testRequestableCardHasNoProgress() {
        let request = RequestState(status: nil, state: nil, requestable: true, reason: nil, requestId: nil)
        XCTAssertNil(RequestProgress(availability: .missing, request: request))
    }

    func testTargetSummaryOnlyForMultipleQualities() {
        XCTAssertNil(RequestTargetSummary.text(for: [RequestTarget(quality: "1080p", status: .downloading, lastError: nil)]))
        XCTAssertEqual(
            RequestTargetSummary.text(for: [
                RequestTarget(quality: "1080p", status: .downloading, lastError: nil),
                RequestTarget(quality: "4K", status: .queued, lastError: nil),
            ]),
            "1080p downloading · 4K queued"
        )
    }
}
