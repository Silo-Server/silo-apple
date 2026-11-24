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
        case .requested: AppLanguage.string(.requestsStageRequested)
        case .approval: AppLanguage.string(.requestsStageApproved)
        case .download: AppLanguage.string(.requestsStageDownloading)
        case .library: AppLanguage.string(.requestsStageLibrary)
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
            shortLabel = AppLanguage.string(.requestsShortPending)
            longLabel = AppLanguage.string(.requestsLongPending)
        case .onTheWay:
            let phase = Self.inFlightPhase(state: state, status: status)
            completedSteps = phase.step.rawValue
            currentStep = phase.step
            shortLabel = phase.short
            longLabel = phase.long
        case .inLibrary:
            completedSteps = RequestStep.allCases.count
            currentStep = nil
            shortLabel = AppLanguage.string(.requestsShortInLibrary)
            longLabel = AppLanguage.string(.requestsLongInLibrary)
        case .needsAttention(.declined, _):
            completedSteps = 1
            currentStep = .approval
            shortLabel = AppLanguage.string(.requestsShortDeclined)
            longLabel = AppLanguage.string(.requestsLongDeclined)
        case .needsAttention(.failed, _):
            completedSteps = 2
            currentStep = .download
            shortLabel = AppLanguage.string(.requestsShortFailed)
            longLabel = AppLanguage.string(.requestsLongFailed)
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
            return (.library, AppLanguage.string(.requestsShortPartly), AppLanguage.string(.requestsLongPartly))
        }
        switch status {
        case .downloading:
            return (.download, AppLanguage.string(.requestsShortDownloading), AppLanguage.string(.requestsLongDownloading))
        case .completed:
            return (.library, AppLanguage.string(.requestsShortAdding), AppLanguage.string(.requestsLongAdding))
        case .approved, .queued:
            return (.download, AppLanguage.string(.requestsShortQueued), AppLanguage.string(.requestsLongQueued))
        case .pending, .failed, .unknown, nil:
            return (.download, AppLanguage.string(.requestsShortOnTheWay), AppLanguage.string(.requestsLongOnTheWay))
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
            // `quality` is the server's label, such as 1080p or 4K.
            switch target.status {
            case .completed: return AppLanguage.string(.requestsTargetDone(quality))
            case .downloading: return AppLanguage.string(.requestsTargetDownloading(quality))
            case .queued, .approved: return AppLanguage.string(.requestsTargetQueued(quality))
            case .pending: return AppLanguage.string(.requestsTargetPending(quality))
            case .failed: return AppLanguage.string(.requestsTargetFailed(quality))
            case .unknown: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The requested qualities, for rows that aren't in flight: "1080p · 4K".
    static func qualities(for targets: [RequestTarget]?) -> String? {
        let qualities = (targets ?? []).compactMap(\.quality).filter { !$0.isEmpty }
        return qualities.isEmpty ? nil : qualities.joined(separator: " · ")
    }
}
