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
    /// Approved / queued / downloading — somewhere in the pipeline, including
    /// a finished download the library hasn't picked up yet. Sky.
    case onTheWay
    /// The title is in the library (or, from a server without `state`, the
    /// request completed). Emerald.
    case inLibrary
    /// Declined or failed — shows the reason. Rose. Chips read "Needs
    /// attention" for both; the detail page says which it is.
    case needsAttention(Attention, reason: String?)
    /// Not requestable and no request exists (limit reached, requests off,
    /// blocked user, …). Neutral — the request affordance simply doesn't
    /// render. Also covers cancelled requests.
    case unavailable(reason: String?)

    /// Why a request needs attention. A declined request and a failed one
    /// need different things from the user, so the copy keeps them apart.
    enum Attention: Equatable {
        case declined
        case failed

        var title: String {
            switch self {
            case .declined: "Declined"
            case .failed: "Request failed"
            }
        }
    }

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

    /// The request detail page's status line, which has room to say more
    /// than the chip.
    var detailTitle: String {
        switch self {
        case .pending: "Requested · Pending"
        case .onTheWay: "On the way"
        case .inLibrary: "In your library"
        case .needsAttention(let attention, let reason):
            RequestErrorCopy.message(forToken: reason).map { "\(attention.title) · \($0)" } ?? attention.title
        case .unavailable(let reason):
            RequestErrorCopy.message(forToken: reason) ?? "Unavailable"
        }
    }

    /// The catalog item to open instead of the request, when there is
    /// nothing about the request left to show: only a state that reads "In
    /// library", with a known item. A title in the library that still has an
    /// active request (missing seasons, a failure) opens the request, as its
    /// chip says.
    func libraryItemToOpen(contentId: String?) -> String? {
        guard self == .inLibrary, let contentId, !contentId.isEmpty else { return nil }
        return contentId
    }
}

enum RequestStatusTint {
    case amber, sky, emerald, rose, neutral
}

// MARK: - Derivation

extension RequestDisplayState {
    /// From a full request record (`/requests/mine`, detail-after-submit).
    /// Every surface that shows a record — card ribbon, row chip, My
    /// Requests bucket — derives it here, so they can't disagree.
    init(record: MediaRequest) {
        self.init(state: record.state, status: record.status, outcome: record.outcome, reason: record.lastError)
    }

    /// The server's `state` decides when present and recognized; `status`
    /// and `outcome` decide otherwise, for servers that don't send it.
    init(state: RequestUserState?, status: RequestStatus, outcome: RequestOutcome, reason: String? = nil) {
        if let state, let derived = RequestDisplayState(state: state, reason: reason) {
            self = derived
        } else {
            self.init(status: status, outcome: outcome, reason: reason)
        }
    }

    /// From the server's user-facing state. Nil for `.unknown`, so a state
    /// added by a newer server falls back to `status` and `outcome`.
    private init?(state: RequestUserState, reason: String?) {
        switch state {
        case .pending:
            self = .pending
        case .approved, .processing:
            self = .onTheWay
        case .partiallyAvailable:
            // Some requested seasons are in, the rest are still coming.
            // `.inLibrary` would file the request under Available before
            // every season has landed, the mistake `state` exists to
            // prevent; the web keeps it with the requests on their way too.
            self = .onTheWay
        case .available:
            self = .inLibrary
        case .declined:
            self = .needsAttention(.declined, reason: reason)
        case .failed:
            self = .needsAttention(.failed, reason: reason)
        case .cancelled:
            self = .unavailable(reason: reason)
        case .unknown:
            return nil
        }
    }

    /// The mapping for servers without `state`, which can't tell a finished
    /// download from a title in the library: `completed` reads as in library.
    /// `outcome` wins over `status` for terminal states: a declined request
    /// keeps its last status on the wire but is no longer in motion.
    init(status: RequestStatus, outcome: RequestOutcome, reason: String? = nil) {
        switch outcome {
        case .declined:
            self = .needsAttention(.declined, reason: reason)
            return
        case .failed:
            self = .needsAttention(.failed, reason: reason)
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
            self = .needsAttention(.failed, reason: reason)
        }
    }

    /// From a search/discover/detail card's compact annotations. Returns
    /// nil when the card has no state to show (missing, requestable, never
    /// requested) — that's the "Request" affordance state, not a chip.
    ///
    /// An active request's `state` comes before availability: a series in
    /// the library can have a request for its missing seasons, and the card
    /// must agree with My Requests about it. Without `state` (older servers),
    /// a title in the library reads as in library whatever its request says.
    ///
    /// `request.reason` says why the title can't be requested
    /// (`already_requested`, `quota_exceeded`, …), not why a request failed
    /// or was declined, so only a title with no request shows it.
    init?(availability: RequestAvailability, request: RequestState) {
        if let state = request.state, let derived = RequestDisplayState(state: state, reason: nil) {
            self = derived
            return
        }
        if availability == .available {
            self = .inLibrary
            return
        }
        if let status = request.status {
            self.init(status: status, outcome: .active, reason: nil)
            return
        }
        if request.requestable {
            return nil
        }
        self = .unavailable(reason: request.reason)
    }
}
