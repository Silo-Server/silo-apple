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

    // MARK: - Record derivation (server `state`)

    func testFinishedDownloadIsOnTheWayUntilTheLibraryHasIt() {
        // The download finished (`completed`) but the library scan hasn't
        // found the title yet, so the server says `processing`.
        XCTAssertEqual(RequestDisplayState(state: .processing, status: .completed, outcome: .active), .onTheWay)
        XCTAssertEqual(RequestDisplayState(state: .available, status: .completed, outcome: .active), .inLibrary)
    }

    func testEachServerStateMapsToOneDisplayState() {
        // The status and outcome the server sends alongside each state.
        let cases: [(RequestUserState, RequestStatus, RequestOutcome, RequestDisplayState)] = [
            (.pending, .pending, .active, .pending),
            (.approved, .approved, .active, .onTheWay),
            (.processing, .downloading, .active, .onTheWay),
            // Some requested seasons are in, the rest are still coming.
            (.partiallyAvailable, .completed, .active, .onTheWay),
            (.available, .completed, .active, .inLibrary),
            (.failed, .downloading, .failed, .needsAttention(reason: "grab failed")),
            (.declined, .pending, .declined, .needsAttention(reason: "grab failed")),
            (.cancelled, .pending, .cancelled, .unavailable(reason: "grab failed")),
        ]
        for (state, status, outcome, expected) in cases {
            XCTAssertEqual(
                RequestDisplayState(state: state, status: status, outcome: outcome, reason: "grab failed"),
                expected,
                "\(state)"
            )
        }
    }

    func testMissingOrUnknownStateFallsBackToStatusAndOutcome() {
        // A server without `state` can't tell a finished download from a
        // title in the library.
        XCTAssertEqual(RequestDisplayState(state: nil, status: .completed, outcome: .active), .inLibrary)
        XCTAssertEqual(RequestDisplayState(state: nil, status: .downloading, outcome: .active), .onTheWay)
        XCTAssertEqual(
            RequestDisplayState(state: nil, status: .queued, outcome: .declined, reason: "no space"),
            .needsAttention(reason: "no space")
        )
        // A state added by a newer server defers to the fields this client knows.
        XCTAssertEqual(RequestDisplayState(state: .unknown, status: .pending, outcome: .active), .pending)
        XCTAssertEqual(RequestDisplayState(state: .unknown, status: .completed, outcome: .active), .inLibrary)
    }

    // MARK: - Card derivation (availability + RequestState)

    private func state(
        status: RequestStatus? = nil,
        state: RequestUserState? = nil,
        requestable: Bool,
        reason: String? = nil
    ) -> RequestState {
        RequestState(status: status, state: state, requestable: requestable, reason: reason, requestId: nil)
    }

    func testCardShowsAFinishedDownloadAsOnTheWay() {
        XCTAssertEqual(
            RequestDisplayState(
                availability: .missing,
                request: state(status: .completed, state: .processing, requestable: false)
            ),
            .onTheWay
        )
        // Without `state`, the card keeps the old mapping.
        XCTAssertEqual(
            RequestDisplayState(availability: .missing, request: state(status: .completed, requestable: false)),
            .inLibrary
        )
        XCTAssertEqual(
            RequestDisplayState(
                availability: .missing,
                request: state(status: .pending, state: .unknown, requestable: false)
            ),
            .pending
        )
    }

    func testAvailableWinsOverStatusWithoutState() {
        // A server without `state`: in-library beats the request's status —
        // the card is a door, not a chip.
        let result = RequestDisplayState(
            availability: .available,
            request: state(status: .pending, requestable: false)
        )
        XCTAssertEqual(result, .inLibrary)
    }

    func testActiveRequestStateWinsOverLibraryAvailability() {
        // A series in the library with a request for its missing seasons
        // reads as My Requests shows it, not as "In library".
        XCTAssertEqual(
            RequestDisplayState(
                availability: .available,
                request: state(status: .downloading, state: .processing, requestable: false)
            ),
            .onTheWay
        )
        XCTAssertEqual(
            RequestDisplayState(
                availability: .available,
                request: state(status: .completed, state: .partiallyAvailable, requestable: false)
            ),
            .onTheWay
        )
        XCTAssertEqual(
            RequestDisplayState(
                availability: .available,
                request: state(status: .queued, state: .failed, requestable: false, reason: "already_requested")
            ),
            .needsAttention(reason: "already_requested")
        )
        // No request: still a door into the library.
        XCTAssertEqual(
            RequestDisplayState(availability: .available, request: state(requestable: false, reason: "already_available")),
            .inLibrary
        )
        // A state this client doesn't know leaves availability in charge.
        XCTAssertEqual(
            RequestDisplayState(
                availability: .available,
                request: state(status: .downloading, state: .unknown, requestable: false)
            ),
            .inLibrary
        )
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
