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
    /// A pending or failed request for this title that the signed-in admin
    /// can decide on. Nil for everyone who can't moderate.
    private(set) var moderationRecord: MediaRequest?
    private(set) var isModerating = false
    /// A decision was sent without a usable answer. Moderation is
    /// `non_retryable`, so the buttons stay hidden until a fresh read.
    private(set) var isModerationUnconfirmed = false
    /// Bumped on every accepted admin decision, for the success haptic.
    private(set) var moderatedCount = 0
    var isLoading = false
    var error: ErrorState?
    private(set) var isSubmitting = false
    /// Inline banner near the CTA for a failed create (already requested,
    /// quota, …) — informational, never a blocking alert.
    private(set) var actionErrorMessage: String?
    /// Bumped when the server accepts a new request, for the success haptic.
    private(set) var submittedCount = 0
    /// A create was sent but its outcome is unknown. Create is
    /// `non_retryable`, so the CTA stays held until a fresh detail read
    /// shows whether the request exists.
    private(set) var isSubmissionUnconfirmed = false

    private let api: SiloAPI
    private let cache: RequestDetailCache
    /// In-flight bus-triggered reload; cancelled and replaced on the next
    /// event so a slow earlier response can't overwrite a newer one.
    private var reloadTask: Task<Void, Never>?

    init(
        mediaType: RequestMediaType,
        tmdbId: Int,
        api: SiloAPI = .shared,
        cache: RequestDetailCache = .shared
    ) {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.api = api
        self.cache = cache
        // First frame from what the app already knows — the finished page
        // when this title was read before, the tapped card or record
        // otherwise — and the status from the user's own records. `load()`
        // refreshes all of it in place.
        let key = RequestDetailCache.Key(mediaType: mediaType, tmdbId: tmdbId)
        detail = cache.firstFrameDetail(key)
        record = cache.ownRecord(key)
        moderationRecord = cache.pinnedModerationRecord(key) ?? cache.moderationRecord(key)
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
        // A failed request no longer blocks a new one, so the server calls
        // the title requestable. An admin who can retry it does that instead
        // of starting a second request: the failure is the status, and
        // Retry is the page's one action.
        if let ended = endedRequest, isRetryableByAdmin {
            return .status(RequestDisplayState(record: ended))
        }
        return .request
    }

    /// The request for this title that ended without landing — failed or
    /// declined — when that's the latest word on it: the user's own, or the
    /// one an admin is deciding on. The page shows it as the status; the
    /// requester's one way forward is to request again.
    var endedRequest: MediaRequest? {
        for candidate in [currentOwnRecord, moderationRecord].compactMap({ $0 }) {
            if case .needsAttention = RequestDisplayState(record: candidate) { return candidate }
        }
        return nil
    }

    /// Independent of an action in flight, so the primary action doesn't
    /// flip back to Request while a retry runs.
    private var isRetryableByAdmin: Bool {
        guard let moderationRecord else { return false }
        if case .needsAttention(.failed, _) = RequestDisplayState(record: moderationRecord) { return true }
        return false
    }

    /// Stage-track state for a request that exists: the user's record when
    /// they have one (it carries the finer download phase), an admin's
    /// view of someone else's, otherwise the title annotation. Nil for a
    /// title nobody has requested, including one that can't be requested.
    var progress: RequestProgress? {
        let own = currentOwnRecord
        if own == nil, let moderationRecord {
            return RequestProgress(record: moderationRecord)
        }
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

    /// Recommendations, minus rows the card can't route (unknown types).
    var recommendations: [RequestMediaResult] {
        (detail?.recommendations ?? []).filter { $0.mediaType != .unknown }
    }

    func load() async {
        isLoading = detail == nil
        error = nil
        do {
            let fresh = try await api.requestsDetail(mediaType: mediaType, tmdbId: tmdbId)
            detail = fresh
            hasFreshDetail = true
            cache.store(fresh)
            // Supporting reads run after the title, side by side: each keeps
            // its previous value on failure, so a slow list never blocks
            // the page.
            async let own = loadOwnRecord()
            async let moderationLookup = try? loadModerationRecord()
            record = await own
            if let moderation = await moderationLookup {
                moderationRecord = moderation.record
                isModerationUnconfirmed = false
            }
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

    /// Admins see the decision on the page they open from Approvals.
    /// Throws when the reads fail, so the page keeps what it has; a nil
    /// `record` means nothing for this title awaits a decision.
    private func loadModerationRecord() async throws -> ModerationLookup {
        guard RequestsFeatureStore.shared.canModerate else { return ModerationLookup(record: nil) }
        // Filtered to this title on the server: one short page each, not
        // the whole queue and every failure on record.
        async let pendingRead = api.adminRequests(status: .pending, outcome: .active, mediaType: mediaType, tmdbId: tmdbId)
        async let failedRead = api.adminRequests(outcome: .failed, mediaType: mediaType, tmdbId: tmdbId)
        let (pending, failed) = try await (pendingRead, failedRead)
        let matches = (pending + failed).filter { $0.mediaType == mediaType && $0.tmdbId == tmdbId }
        // Several users can have failed requests for one title: keep the
        // exact request the admin opened, while it still needs a decision.
        if let current = moderationRecord?.id, let same = matches.first(where: { $0.id == current }) {
            return ModerationLookup(record: same)
        }
        return ModerationLookup(record: matches.first)
    }

    private struct ModerationLookup {
        let record: MediaRequest?
    }

    /// The decision the admin can take on `moderationRecord`, if any.
    var moderationActions: [AdminRequestAction] {
        guard let moderationRecord, !isModerating, !isModerationUnconfirmed else { return [] }
        switch RequestDisplayState(record: moderationRecord) {
        case .pending: return [.approve, .decline]
        case .needsAttention(.failed, _): return [.retry]
        default: return []
        }
    }

    func moderate(_ action: AdminRequestAction) async {
        guard let moderationRecord, !isModerating else { return }
        isModerating = true
        actionErrorMessage = nil
        do {
            let updated = try await api.adminRequestAction(id: moderationRecord.id, action: action)
            moderatedCount += 1
            RequestsEventBus.shared.publishModeration(updated)
            await load()
        } catch where RequestMutationFailure.isUncertain(error) {
            // Never resend: hide the decision until a fresh read shows it.
            isModerationUnconfirmed = true
            actionErrorMessage = RequestErrorCopy.unconfirmedModerationMessage
            if !RequestMutationFailure.isOwnerChanged(error) { await load() }
        } catch {
            actionErrorMessage = RequestErrorCopy.message(for: error)
        }
        isModerating = false
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
