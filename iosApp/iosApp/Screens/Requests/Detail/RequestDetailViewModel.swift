import Foundation

/// The single primary action on a request detail page, computed fresh from
/// server state on every access so the button can never disagree with the
/// server after a refresh. The view renders exactly ONE button whose
/// label/action vary by case — never two swapped `Button` identities,
/// which would drop tvOS focus mid-morph.
enum RequestPrimaryAction: Equatable {
    case loading
    /// The one-tap request CTA.
    case request
    /// Submit in flight — same button, relabeled and disabled.
    case submitting
    /// A request exists (or the title is blocked); non-interactive.
    case status(RequestDisplayState)
    /// Already in the library — the button becomes a door to the item.
    case openInLibrary(contentId: String)

    var isInteractive: Bool {
        switch self {
        case .request, .openInLibrary: true
        case .loading, .submitting, .status: false
        }
    }
}

@Observable
@MainActor
final class RequestDetailViewModel {
    let mediaType: RequestMediaType
    let tmdbId: Int

    private(set) var detail: RequestMediaDetail?
    var isLoading = false
    var error: ErrorState?
    private(set) var isSubmitting = false
    /// Inline banner near the CTA for a failed create (already requested,
    /// quota, …) — informational, never a blocking alert.
    private(set) var actionErrorMessage: String?

    private let api: ContinuumAPI
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?

    init(mediaType: RequestMediaType, tmdbId: Int, api: ContinuumAPI = .shared) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.api = api
    }

    var primaryAction: RequestPrimaryAction {
        guard let detail else { return .loading }
        if detail.availability == .available, let contentId = detail.libraryContentId {
            return .openInLibrary(contentId: contentId)
        }
        if isSubmitting { return .submitting }
        if let state = RequestDisplayState(availability: detail.availability, request: detail.request) {
            if case .inLibrary = state, let contentId = detail.libraryContentId {
                return .openInLibrary(contentId: contentId)
            }
            return .status(state)
        }
        return .request
    }

    /// Recommendations, minus rows the card can't route (unknown types).
    var recommendations: [RequestMediaResult] {
        (detail?.recommendations ?? []).filter { $0.mediaType != .unknown }
    }

    func load() async {
        isLoading = detail == nil
        error = nil
        do {
            detail = try await api.requestsDetail(mediaType: mediaType, tmdbId: tmdbId)
        } catch {
            if detail == nil {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// One tap, no confirmation dialog — the button is the confirmation.
    func submitRequest() async {
        guard let detail, !isSubmitting, primaryAction == .request else { return }
        isSubmitting = true
        actionErrorMessage = nil
        do {
            let record = try await api.createRequest(CreateRequestInput(
                mediaType: detail.mediaType,
                tmdbId: detail.tmdbId,
                tvdbId: detail.tvdbId,
                imdbId: detail.imdbId,
                title: detail.title,
                year: detail.year,
                overview: detail.overview,
                posterPath: detail.posterPath,
                backdropPath: detail.backdropPath
            ))
            RequestsEventBus.shared.publish(record)
            // Re-fetch so `request` reflects authoritative server state
            // (id, status, quota effects) rather than a local guess.
            await load()
        } catch {
            actionErrorMessage = RequestErrorCopy.message(for: error)
        }
        isSubmitting = false
    }

    /// Bus consumer: another surface mutated this title (e.g. cancel from
    /// My Requests while this page sits in the nav stack).
    func applyRequestUpdate(_ record: MediaRequest) {
        guard let detail,
              record.mediaType == detail.mediaType,
              record.tmdbId == detail.tmdbId,
              !isSubmitting else { return }
        reloadTask?.cancel()
        reloadTask = Task { await load() }
    }
}
