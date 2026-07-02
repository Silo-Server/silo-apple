import Foundation

/// The five user-facing request states. Chips render monochrome with a
/// small dot in the state's tint; the same mapping drives poster ribbons,
/// the detail page's primary action, and My Requests bucketing, so the two
/// platforms (and every surface on each) can never disagree about what a
/// given server state looks like.
///
/// Deliberately `Foundation`-only — the tint becomes a `Color` in the view
/// layer (`RequestStatusChip`), keeping this mapper trivially testable.
enum RequestDisplayState: Equatable {
    /// Submitted, awaiting approval. Amber. Cancelable by the requester.
    case pending
    /// Approved / queued / downloading — somewhere in the pipeline. Sky.
    case onTheWay
    /// Completed, or the title was already in the library. Emerald.
    case inLibrary
    /// Declined or failed — shows the reason. Rose.
    case needsAttention(reason: String?)
    /// Not requestable and no request exists (limit reached, requests off,
    /// blocked user, …). Neutral — the request affordance simply doesn't
    /// render. Also covers cancelled requests.
    case unavailable(reason: String?)

    var label: String {
        switch self {
        case .pending: "Pending"
        case .onTheWay: "On the way"
        case .inLibrary: "In library"
        case .needsAttention: "Needs attention"
        case .unavailable: "Unavailable"
        }
    }

    var tint: RequestStatusTint {
        switch self {
        case .pending: .amber
        case .onTheWay: .sky
        case .inLibrary: .emerald
        case .needsAttention: .rose
        case .unavailable: .neutral
        }
    }

    /// Whether this state represents an in-flight request the owner may
    /// still cancel (the server only allows cancel pre-submission, but
    /// offering it on any pending request and surfacing the server's
    /// answer is simpler than mirroring that rule client-side).
    var isCancelable: Bool {
        self == .pending
    }
}

enum RequestStatusTint {
    case amber, sky, emerald, rose, neutral
}

// MARK: - Derivation

extension RequestDisplayState {
    /// From a full request record (`/requests/mine`, detail-after-submit).
    /// `outcome` wins over `status` for terminal states: a declined request
    /// keeps its last status on the wire but is no longer in motion.
    init(status: RequestStatus, outcome: RequestOutcome, reason: String? = nil) {
        switch outcome {
        case .declined, .failed:
            self = .needsAttention(reason: reason)
            return
        case .cancelled:
            self = .unavailable(reason: reason)
            return
        case .active, .unknown:
            break
        }
        switch status {
        case .pending:
            self = .pending
        case .approved, .queued, .downloading, .unknown:
            // Unknown statuses are treated as in-flight rather than broken —
            // a newer server's added pipeline stage shouldn't read as an
            // error on older clients.
            self = .onTheWay
        case .completed:
            self = .inLibrary
        case .failed:
            self = .needsAttention(reason: reason)
        }
    }

    /// From a search/discover/detail card's compact annotations. Returns
    /// nil when the card has no state to show (missing, requestable, never
    /// requested) — that's the "Request" affordance state, not a chip.
    init?(availability: RequestAvailability, request: RequestState) {
        if availability == .available {
            self = .inLibrary
            return
        }
        if let status = request.status {
            self.init(status: status, outcome: .active, reason: request.reason)
            return
        }
        if request.requestable {
            return nil
        }
        self = .unavailable(reason: request.reason)
    }
}
