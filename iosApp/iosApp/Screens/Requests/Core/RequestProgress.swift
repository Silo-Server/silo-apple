import Foundation

/// The four steps every request walks through, drawn as the stage track on
/// cards, My Requests rows, the detail page, and the tvOS marquee.
enum RequestStep: Int, CaseIterable {
    case requested
    case approval
    case download
    case library

    var title: String {
        switch self {
        case .requested: "Requested"
        case .approval: "Approved"
        case .download: "Downloading"
        case .library: "In your library"
        }
    }
}

/// Where a request sits on the stage track, plus the finer labels the
/// five-state `RequestDisplayState` can't express ("Queued" vs
/// "Downloading" vs "Adding to library"). Derived from the same display
/// state, so the track, the dot color, and My Requests bucketing always
/// agree.
///
/// `Foundation`-only like `RequestDisplayState`; views map `tint` to a color.
struct RequestProgress: Equatable {
    let display: RequestDisplayState
    /// Steps fully behind the request (0...4). Drawn solid.
    let completedSteps: Int
    /// The step the request is on, drawn in `tint`. Nil once every step is
    /// done, and for requests that left the track (cancelled, blocked).
    let currentStep: RequestStep?
    /// One or two words for card captions and chips.
    let shortLabel: String
    /// A plain-language sentence start for list rows and the tvOS marquee.
    let longLabel: String

    var tint: RequestStatusTint { display.tint }

    // MARK: - Derivation

    /// From a full request record: My Requests, the hub strip, admin rows.
    init(record: MediaRequest) {
        self.init(
            display: RequestDisplayState(record: record),
            state: record.state,
            status: record.status
        )
    }

    /// From a search/discover/detail card's compact annotation. Nil when the
    /// card has no state to show (requestable, never requested).
    init?(availability: RequestAvailability, request: RequestState) {
        guard let display = RequestDisplayState(availability: availability, request: request) else {
            return nil
        }
        self.init(display: display, state: request.state, status: request.status)
    }

    /// The display state decides the bucket and color; `state` and `status`
    /// only refine where on the track an in-flight request sits.
    init(display: RequestDisplayState, state: RequestUserState?, status: RequestStatus?) {
        self.display = display
        switch display {
        case .pending:
            completedSteps = 1
            currentStep = .approval
            shortLabel = "Pending"
            longLabel = "Waiting for approval"
        case .onTheWay:
            let phase = Self.inFlightPhase(state: state, status: status)
            completedSteps = phase.step.rawValue
            currentStep = phase.step
            shortLabel = phase.short
            longLabel = phase.long
        case .inLibrary:
            completedSteps = RequestStep.allCases.count
            currentStep = nil
            shortLabel = "In library"
            longLabel = "In your library"
        case .needsAttention(.declined, _):
            completedSteps = 1
            currentStep = .approval
            shortLabel = "Declined"
            longLabel = "Declined"
        case .needsAttention(.failed, _):
            completedSteps = 2
            currentStep = .download
            shortLabel = "Failed"
            longLabel = "Request failed"
        case .unavailable:
            completedSteps = 0
            currentStep = nil
            shortLabel = display.label
            longLabel = display.detailTitle
        }
    }

    /// Where an approved-but-unfinished request is. `partially_available`
    /// and a finished download the library hasn't picked up yet are both on
    /// the last step; everything else is queued or downloading.
    private static func inFlightPhase(
        state: RequestUserState?,
        status: RequestStatus?
    ) -> (step: RequestStep, short: String, long: String) {
        if state == .partiallyAvailable {
            return (.library, "Partly in library", "Partly in your library")
        }
        switch status {
        case .downloading:
            return (.download, "Downloading", "Downloading")
        case .completed:
            return (.library, "Adding to library", "Adding to your library")
        case .approved, .queued:
            return (.download, "Queued", "Queued for download")
        case .pending, .failed, .unknown, nil:
            return (.download, "On the way", "On the way")
        }
    }
}

// MARK: - Per-quality targets

enum RequestTargetSummary {
    /// "1080p downloading · 4K queued" for a request fanned out to more than
    /// one quality. Nil for single-target requests, whose one state is
    /// already the request's own.
    static func text(for targets: [RequestTarget]?) -> String? {
        guard let targets, targets.count > 1 else { return nil }
        let parts = targets.compactMap { target -> String? in
            guard let quality = target.quality, !quality.isEmpty else { return nil }
            let word: String
            switch target.status {
            case .completed: word = "done"
            case .downloading: word = "downloading"
            case .queued, .approved: word = "queued"
            case .pending: word = "pending"
            case .failed: word = "failed"
            case .unknown: return nil
            }
            return "\(quality) \(word)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The requested qualities, for rows that aren't in flight: "1080p · 4K".
    static func qualities(for targets: [RequestTarget]?) -> String? {
        let qualities = (targets ?? []).compactMap(\.quality).filter { !$0.isEmpty }
        return qualities.isEmpty ? nil : qualities.joined(separator: " · ")
    }
}
