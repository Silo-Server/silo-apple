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
    /// False while the page shows a cached or provisional first frame; the
    /// view animates the swap to the server's answer.
    private(set) var hasFreshDetail = false
    /// The signed-in user's own record for this title, when there is one:
    /// the stage timestamps, per-quality targets, and the id to cancel.
    private(set) var record: MediaRequest?
    private(set) var isCancelling = false
    /// A cancel was sent without a usable answer. Cancel is
    /// `non_retryable`, so it stays hidden until a successful read of the
    /// user's requests shows the result.
    private(set) var isCancelUnconfirmed = false
    var isLoading = false
    var error: ErrorState?
    private(set) var isSubmitting = false
    /// Inline banner near the CTA for a failed create (already requested,
    /// quota, …) — informational, never a blocking alert.
    private(set) var actionErrorMessage: String?
    /// Bumped when the server accepts a new request, for the success haptic.
    private(set) var submittedCount = 0
    /// A follow or unfollow is in flight. The button stays enabled and
    /// focusable (tvOS keeps focus on it); `toggleFollow` ignores presses.
    private(set) var isTogglingFollow = false
    /// Confirms the last follow toggle under the button; cleared by the next
    /// action.
    private(set) var followNotice: String?
    /// Bumped on every accepted follow toggle, for the success haptic.
    private(set) var followToggledCount = 0
    /// A create was sent but its outcome is unknown. Create is
    /// `non_retryable`, so the CTA stays held until a fresh detail read
    /// shows whether the request exists.
    private(set) var isSubmissionUnconfirmed = false

    private let api: SiloAPI
    private let cache: RequestDetailCache
    private let features: RequestsFeatureStore
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?
    /// Bumped when a follow toggle settles or another page's toggle arrives.
    /// A detail read that started before the bump may predate the change,
    /// so `load()` reads again instead of installing it.
    private var titleStateRevision = 0

    init(
        mediaType: RequestMediaType,
        tmdbId: Int,
        api: SiloAPI = .shared,
        cache: RequestDetailCache? = nil,
        features: RequestsFeatureStore? = nil
    ) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.api = api
        let cache = cache ?? .shared
        self.cache = cache
        self.features = features ?? .shared
        // First frame from what the app already knows — the finished page
        // when this title was read before, the tapped card or record
        // otherwise — and the status from the user's own records. `load()`
        // refreshes all of it in place.
        let key = RequestDetailCache.Key(mediaType: mediaType, tmdbId: tmdbId)
        detail = cache.firstFrameDetail(key)
        record = cache.ownRecord(key)
    }

    var primaryAction: RequestPrimaryAction {
        guard let detail else { return .loading }
        // The same state as the title's card: a title in the library opens
        // it only when no active request says otherwise (missing seasons on
        // their way, a failure).
        let state = RequestDisplayState(availability: detail.availability, request: detail.request)
        if let contentId = state?.libraryItemToOpen(contentId: detail.libraryContentId) {
            return .openInLibrary(contentId: contentId)
        }
        if isSubmitting { return .submitting }
        if isSubmissionUnconfirmed { return .status(.unavailable(reason: RequestErrorCopy.unconfirmedToken)) }
        if let state { return .status(state) }
        // The title annotation drops a request whose download finished but
        // hasn't reached the library, and would offer a duplicate request;
        // the user's own record still knows it's on the way.
        if let recordState = activeRecordState { return .status(recordState) }
        return .request
    }

    /// The user's own request for this title that ended without landing —
    /// failed or declined — when that's the latest word on it. The page
    /// shows it as the status; the requester's one way forward is to
    /// request again.
    var endedRequest: MediaRequest? {
        guard let own = currentOwnRecord else { return nil }
        if case .needsAttention = RequestDisplayState(record: own) { return own }
        return nil
    }

    /// Stage-track state for a request that exists: the user's record when
    /// they have one (it carries the finer download phase), otherwise the
    /// title annotation. Nil for a title nobody has requested, including one
    /// that can't be requested.
    var progress: RequestProgress? {
        let own = currentOwnRecord
        if let own,
           activeRecordState != nil || endedRequest?.id == own.id || detail?.request.requestId == own.id {
            return RequestProgress(record: own)
        }
        guard let detail,
              let progress = RequestProgress(availability: detail.availability, request: detail.request)
        else { return nil }
        if case .unavailable = progress.display { return nil }
        return progress
    }

    /// The request whose steps and timestamps the page shows.
    var displayedRecord: MediaRequest? { record }

    /// Cancel is offered on the page while the request is still pending.
    var canCancel: Bool {
        guard let record, !isCancelling, !isCancelUnconfirmed else { return false }
        return RequestDisplayState(record: record).isCancelable
    }

    /// The user's record while it's still the latest word on the title. A
    /// failed or declined one stops counting once the title is in the
    /// library or another request for it is under way.
    private var currentOwnRecord: MediaRequest? {
        guard let record else { return nil }
        guard record.outcome != .active, let detail else { return record }
        if RequestDisplayState(availability: detail.availability, request: detail.request) == .inLibrary {
            return nil
        }
        if let current = detail.request.requestId, current != record.id { return nil }
        return record
    }

    private var activeRecordState: RequestDisplayState? {
        guard let record, record.outcome == .active else { return nil }
        let state = RequestDisplayState(record: record)
        switch state {
        case .pending, .onTheWay: return state
        default: return nil
        }
    }

    // MARK: Follow

    /// "Notify Me" applies to a title someone else already requested: its
    /// request reads as pending or on the way (the same state the primary
    /// action shows), and the viewer didn't make that request. Independent
    /// of `isFollowing`, so the button stays on screen (and focused on tvOS)
    /// while its label flips.
    var canFollow: Bool {
        guard features.followSupported, let detail else { return false }
        let request = detail.request
        // `requested_by_viewer` must be present and false: a page built
        // from a card or record without it waits for the server's answer.
        guard request.reason == "already_requested", request.requestedByViewer == false else { return false }
        // Not `record`: `/requests/mine` lists the whole account, so another
        // profile's request would hide the button from a profile the server
        // lets follow. `requested_by_viewer` is per profile.
        switch RequestDisplayState(availability: detail.availability, request: request) {
        case .pending, .onTheWay: return true
        default: return false
        }
    }

    var isFollowing: Bool { detail?.request.following == true }

    static let followedNotice = "We'll let you know when it's available."
    static let unfollowedNotice = "Notification turned off."

    /// Follows or unfollows the title. Both are naturally idempotent, so a
    /// failure leaves the button as it was for another try. An uncertain
    /// outcome may have landed: the button stays held until a re-read shows
    /// the server's state.
    func toggleFollow() async {
        guard canFollow, let detail, !isTogglingFollow else { return }
        let follow = !isFollowing
        isTogglingFollow = true
        defer { isTogglingFollow = false }
        actionErrorMessage = nil
        followNotice = nil
        do {
            let state: RequestState
            if follow {
                state = try await api.followRequestMedia(mediaType: detail.mediaType, tmdbId: detail.tmdbId)
            } else {
                // 204: nothing comes back but the change itself.
                try await api.unfollowRequestMedia(mediaType: detail.mediaType, tmdbId: detail.tmdbId)
                // From the page as it is now: a read may have refreshed it
                // while the call ran.
                var unfollowed = self.detail?.request ?? detail.request
                unfollowed.following = false
                state = unfollowed
            }
            titleStateRevision &+= 1
            applyTitleState(state)
            confirmFollowToggle(follow, state: state)
        } catch {
            titleStateRevision &+= 1
            if RequestMutationFailure.isUncertain(error) {
                // It may have landed. A read under a replaced owner says
                // nothing about this toggle.
                if !RequestMutationFailure.isOwnerChanged(error) {
                    await load()
                    // It landed: confirm it like any other toggle rather
                    // than showing an error under the new label.
                    if let landed = self.detail?.request, landed.following == follow {
                        confirmFollowToggle(follow, state: landed)
                        return
                    }
                }
                actionErrorMessage = RequestErrorCopy.message(for: error)
                return
            }
            actionErrorMessage = RequestErrorCopy.message(for: error)
            if Self.isCapabilityProblem(error) {
                // Requests or following went away: let entry points and this
                // button follow the server.
                await features.refresh()
            } else if case APIv2Error.problem = error {
                // The request may have landed or been cancelled meanwhile.
                await load()
            }
        }
    }

    private func applyTitleState(_ state: RequestState) {
        detail?.request = state
        if let detail { cache.store(detail) }
    }

    /// Tells the user, and every card, about a toggle the server accepted.
    private func confirmFollowToggle(_ follow: Bool, state: RequestState) {
        RequestsEventBus.shared.publishTitleState(
            RequestTitleStateUpdate(mediaType: mediaType, tmdbId: tmdbId, request: state))
        followNotice = follow ? Self.followedNotice : Self.unfollowedNotice
        followToggledCount += 1
    }

    private static func isCapabilityProblem(_ error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        return problem.identifier.hasPrefix("capability_")
    }

    /// Bus consumer: the title was followed or unfollowed on another page.
    func applyTitleStateUpdate(_ update: RequestTitleStateUpdate) {
        guard update.mediaType == mediaType, update.tmdbId == tmdbId,
              !isTogglingFollow, detail?.request != update.request else { return }
        titleStateRevision &+= 1
        detail?.request = update.request
    }

    /// Recommendations, minus rows the card can't route (unknown types).
    var recommendations: [RequestMediaResult] {
        (detail?.recommendations ?? []).filter { $0.mediaType != .unknown }
    }

    func load() async {
        isLoading = detail == nil
        error = nil
        do {
            let fresh = try await readDetail()
            detail = fresh
            hasFreshDetail = true
            cache.store(fresh)
            // The user's records follow the title; a failed read keeps the
            // previous value, so a slow list never blocks the page.
            record = await loadOwnRecord()
            // The server's answer now decides the CTA; release the hold.
            if isSubmissionUnconfirmed {
                isSubmissionUnconfirmed = false
                actionErrorMessage = nil
            }
        } catch {
            if detail == nil {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// The title's detail, read again when a follow toggle settled while the
    /// read ran: that answer may predate the toggle.
    private func readDetail() async throws -> RequestMediaDetail {
        while true {
            let revision = titleStateRevision
            let fresh = try await api.requestsDetail(mediaType: mediaType, tmdbId: tmdbId)
            if revision == titleStateRevision { return fresh }
            try Task.checkCancellation()
        }
    }

    /// The user's current request for this title (see
    /// `RequestDetailCache.currentRecord`). A failed read keeps what the
    /// page has.
    private func loadOwnRecord() async -> MediaRequest? {
        guard let mine = try? await api.myRequests() else { return record }
        cache.storeOwnRecords(mine)
        // The list now shows what the held cancel did.
        if isCancelUnconfirmed {
            isCancelUnconfirmed = false
            if actionErrorMessage == RequestErrorCopy.unconfirmedCancelMessage { actionErrorMessage = nil }
        }
        return RequestDetailCache.currentRecord(among: mine.filter { $0.mediaType == mediaType && $0.tmdbId == tmdbId })
    }

    func cancel() async {
        guard let record, canCancel else { return }
        isCancelling = true
        actionErrorMessage = nil
        do {
            let updated = try await api.cancelRequest(id: record.id)
            RequestsEventBus.shared.publish(updated)
            await load()
        } catch where RequestMutationFailure.isUncertain(error) {
            // Never resend: hold Cancel until a fresh read shows the result.
            isCancelUnconfirmed = true
            actionErrorMessage = RequestErrorCopy.unconfirmedCancelMessage
            if !RequestMutationFailure.isOwnerChanged(error) { await load() }
        } catch {
            actionErrorMessage = RequestErrorCopy.message(for: error)
        }
        isCancelling = false
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
            submittedCount += 1
            // Re-fetch so `request` reflects authoritative server state
            // (id, status, quota effects) rather than a local guess.
            await load()
        } catch where RequestMutationFailure.isUncertain(error) {
            // Never resend: hold the CTA and let a fresh read show whether
            // the server created the request.
            isSubmissionUnconfirmed = true
            isSubmitting = false
            // A read under a replaced owner says nothing about this create.
            if !RequestMutationFailure.isOwnerChanged(error) {
                await load()
            }
            if isSubmissionUnconfirmed {
                actionErrorMessage = RequestErrorCopy.unconfirmedSubmitMessage
            }
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
