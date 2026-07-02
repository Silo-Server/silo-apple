import XCTest
@testable import Silo

/// The status mapper is the single source of truth for every request chip,
/// ribbon, bucket, and primary-action state across iOS/tvOS — branch-heavy
/// pure logic that would regress silently, so it gets exhaustive coverage.
final class RequestDisplayStateTests: XCTestCase {
    // MARK: - Record derivation (status × outcome)

    func testActiveOutcomeMapsStatusAxis() {
        XCTAssertEqual(RequestDisplayState(status: .pending, outcome: .active), .pending)
        XCTAssertEqual(RequestDisplayState(status: .approved, outcome: .active), .onTheWay)
        XCTAssertEqual(RequestDisplayState(status: .queued, outcome: .active), .onTheWay)
        XCTAssertEqual(RequestDisplayState(status: .downloading, outcome: .active), .onTheWay)
        XCTAssertEqual(RequestDisplayState(status: .completed, outcome: .active), .inLibrary)
    }

    func testTerminalOutcomesBeatStatus() {
        // A declined request keeps its last wire status but is terminal.
        XCTAssertEqual(
            RequestDisplayState(status: .downloading, outcome: .declined, reason: "no space"),
            .needsAttention(reason: "no space")
        )
        XCTAssertEqual(
            RequestDisplayState(status: .completed, outcome: .failed),
            .needsAttention(reason: nil)
        )
        XCTAssertEqual(
            RequestDisplayState(status: .pending, outcome: .cancelled),
            .unavailable(reason: nil)
        )
    }

    func testFailedStatusWithActiveOutcomeNeedsAttention() {
        // `failed` is target-only on the wire, but tolerate it on a record.
        XCTAssertEqual(
            RequestDisplayState(status: .failed, outcome: .active, reason: "grab failed"),
            .needsAttention(reason: "grab failed")
        )
    }

    func testUnknownWireValuesStayInFlight() {
        // A newer server's added pipeline stage must not read as an error.
        XCTAssertEqual(RequestDisplayState(status: .unknown, outcome: .active), .onTheWay)
        XCTAssertEqual(RequestDisplayState(status: .pending, outcome: .unknown), .pending)
    }

    // MARK: - Card derivation (availability + RequestState)

    private func state(
        status: RequestStatus? = nil,
        requestable: Bool,
        reason: String? = nil
    ) -> RequestState {
        RequestState(status: status, requestable: requestable, reason: reason, requestId: nil)
    }

    func testAvailableAlwaysWins() {
        // In-library beats any request state — the card is a door, not a chip.
        let result = RequestDisplayState(
            availability: .available,
            request: state(status: .pending, requestable: false)
        )
        XCTAssertEqual(result, .inLibrary)
    }

    func testActiveRequestOnMissingTitle() {
        XCTAssertEqual(
            RequestDisplayState(availability: .missing, request: state(status: .pending, requestable: false)),
            .pending
        )
        XCTAssertEqual(
            RequestDisplayState(availability: .missing, request: state(status: .downloading, requestable: false)),
            .onTheWay
        )
    }

    func testRequestableMissingTitleHasNoChip() {
        // No state to show — that's the "Request" affordance, not a chip.
        XCTAssertNil(
            RequestDisplayState(availability: .missing, request: state(requestable: true))
        )
    }

    func testBlockedMissingTitleIsUnavailableWithReason() {
        XCTAssertEqual(
            RequestDisplayState(
                availability: .missing,
                request: state(requestable: false, reason: "quota_exceeded")
            ),
            .unavailable(reason: "quota_exceeded")
        )
    }

    // MARK: - Presentation invariants

    func testTintMapping() {
        XCTAssertEqual(RequestDisplayState.pending.tint, .amber)
        XCTAssertEqual(RequestDisplayState.onTheWay.tint, .sky)
        XCTAssertEqual(RequestDisplayState.inLibrary.tint, .emerald)
        XCTAssertEqual(RequestDisplayState.needsAttention(reason: nil).tint, .rose)
        XCTAssertEqual(RequestDisplayState.unavailable(reason: nil).tint, .neutral)
    }

    func testOnlyPendingIsCancelable() {
        XCTAssertTrue(RequestDisplayState.pending.isCancelable)
        XCTAssertFalse(RequestDisplayState.onTheWay.isCancelable)
        XCTAssertFalse(RequestDisplayState.inLibrary.isCancelable)
        XCTAssertFalse(RequestDisplayState.needsAttention(reason: nil).isCancelable)
        XCTAssertFalse(RequestDisplayState.unavailable(reason: nil).isCancelable)
    }
}
