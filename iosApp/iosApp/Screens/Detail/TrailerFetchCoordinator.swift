import Foundation
import os

/// Drives the manual "Find Trailers" action for a single item.
///
/// The server has no job id for this flow: you `POST
/// /items/{id}/trailers/refresh` and then observe completion by re-fetching
/// item detail until trailers show up or a window lapses — the same
/// request-then-poll shape `PersonDetailViewModel` uses for person metadata,
/// with its policy (3s cadence, 120s window, settled-poll counter) carried
/// over — plus a floor under the settle counter, because an item refresh can
/// sit on a slow provider far longer than a person refresh does. Two of the
/// three server outcomes never poll at all: `cooldown` (the
/// item was checked within the last week) and `disabled` (every library
/// holding it has remote videos switched off) resolve immediately.
///
/// Both dependencies are injected closures rather than `ContinuumAPI.shared`
/// so the whole state machine is testable headless with scripted responses
/// (the `AIJobPoller` precedent). ``statusMessage`` carries the user-facing
/// copy so iOS and tvOS render identical strings.
///
/// One run at a time; call ``stop()`` when the page leaves the nav stack —
/// this task is not owned by SwiftUI's `.task` lifetime and would otherwise
/// keep polling (and retaining the view model) after the route pops. A run
/// stopped before it reached an outcome (the user opened the movie while the
/// fetch was running) can be picked back up with ``resumeIfInterrupted()``
/// on the next appear, without spending another server-side cooldown slot.
@MainActor
@Observable
final class TrailerFetchCoordinator {
    enum Phase: Equatable {
        case idle
        /// The POST is in flight.
        case requesting
        /// Queued server-side; re-fetching detail until trailers land.
        case polling
        /// Checked too recently. The associated value is when it may be
        /// retried, when the server told us.
        case cooldown(Date?)
        /// Remote videos are switched off for every library holding the item.
        case disabled
        /// Trailers (or new extras) arrived; the owner has been handed the
        /// detail they arrived in.
        case found
        /// The refresh did return new remote videos, but this platform can't
        /// play them — tvOS without the YouTube app installed, where the rail
        /// drops every remote card. Distinct from ``found`` (nothing would
        /// appear on screen, so clearing the status would leave the tap
        /// looking unanswered) and from ``exhausted`` (the server did find
        /// trailers; "No trailers found" would be wrong).
        case foundUnplayable
        /// The window (or the settle counter) lapsed without anything new.
        case exhausted
        /// The POST itself never came back with an answer — a timeout, a
        /// transport failure, or the per-user rate limiter. Distinct from
        /// ``exhausted`` because the server may well have consumed the
        /// weekly slot anyway, so "No trailers found" would be a lie: the
        /// very next tap would say "Trailers were checked recently".
        case requestFailed(rateLimited: Bool)
    }

    private(set) var phase: Phase = .idle

    /// Copy for the status pill. `nil` while idle and once the refreshed
    /// detail has been handed back — at that point the new rail is the
    /// feedback.
    var statusMessage: String? {
        switch phase {
        case .idle, .found: return nil
        case .requesting, .polling: return "Finding trailers…"
        case .cooldown: return "Trailers were checked recently"
        case .disabled: return "Trailers are disabled for this library"
        case .foundUnplayable: return "No playable trailers here"
        case .exhausted: return "No trailers found"
        case .requestFailed(let rateLimited):
            return rateLimited
                ? "Please wait a moment and try again"
                : "Couldn't reach the server — try again"
        }
    }

    /// True while the request or the poll loop is running, i.e. while the
    /// pill should show a spinner rather than a terminal message.
    var isFetching: Bool {
        phase == .requesting || phase == .polling
    }

    // MARK: - Policy

    /// Gap between detail re-fetches once the refresh is queued.
    static let defaultPollInterval: Duration = .seconds(3)
    /// Hard cap on the poll loop. Matches the server's own hard cap on an
    /// on-demand refresh (`metadataOnDemandRefreshTimeout`, 2 minutes), so
    /// the client stops looking exactly when the job it is waiting for can
    /// no longer produce anything.
    static let defaultWindowSeconds: TimeInterval = 120
    /// Consecutive polls in which nothing about the item changed after which
    /// the refresh is treated as settled — the server ran and this is all it
    /// found. Any observed change (new artwork, a rewritten overview, a
    /// rating) resets the counter, because it means the refresh is still
    /// landing writes and the videos may yet follow.
    static let defaultSettledPollCount = 5
    /// How long the poll loop observes before the settle counter is allowed
    /// to end a run.
    ///
    /// There is no completion signal for this job: the server answers 202 and
    /// runs the refresh detached, so "nothing changed five times in a row" is
    /// evidence the *provider* has been quiet, not that the job is done. At a
    /// 3s cadence the bare counter fires ~18s in, while the refresh may
    /// legitimately still be waiting on a slow provider — and reporting "No
    /// trailers found" there is doubly wrong, because the weekly cooldown
    /// slot is already spent, so the retry that would have shown the result
    /// can only answer "checked recently".
    ///
    /// So the counter only applies once the job has plausibly had time to
    /// finish. Under that floor an unchanged item just keeps polling; the
    /// 120s window still bounds the run. Nothing here delays a *result*: a
    /// found payload ends the run on the tick it appears, which is the case
    /// the fast path actually matters for.
    static let defaultMinimumObservationSeconds: TimeInterval = 60

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TrailerFetch"
    )

    /// `@MainActor` on both closures so a caller can read main-actor state
    /// (the owning view model's current `contentId`) inside them without
    /// hopping; the awaited work itself still happens on the API actor.
    private let request: @MainActor () async throws -> TrailerRefreshResponse
    private let fetchDetail: @MainActor () async throws -> ItemDetail
    private let pollInterval: Duration
    private let windowSeconds: TimeInterval
    private let settledPollCount: Int
    private let minimumObservationSeconds: TimeInterval

    private var task: Task<Void, Never>?
    private var activeRunID: UUID?
    /// Set for the lifetime of a run — from the POST through the poll loop —
    /// so ``stop()`` can hand an interrupted run to
    /// ``resumeIfInterrupted()``.
    private var pollContext: PollContext?
    /// A run ``stop()`` cancelled before it reached any outcome. Consumed
    /// (once) by ``resumeIfInterrupted()``.
    private var interruptedPoll: PollContext?

    /// The policy knobs are `nil`-defaulted and resolved in the body rather
    /// than defaulted to `Self.default…` in the signature: a default argument
    /// is evaluated in the caller's context, and these constants live on a
    /// `@MainActor` type. Tests pass a millisecond cadence.
    init(
        request: @MainActor @escaping () async throws -> TrailerRefreshResponse,
        fetchDetail: @MainActor @escaping () async throws -> ItemDetail,
        pollInterval: Duration? = nil,
        windowSeconds: TimeInterval? = nil,
        settledPollCount: Int? = nil,
        minimumObservationSeconds: TimeInterval? = nil
    ) {
        self.request = request
        self.fetchDetail = fetchDetail
        self.pollInterval = pollInterval ?? Self.defaultPollInterval
        self.windowSeconds = windowSeconds ?? Self.defaultWindowSeconds
        self.settledPollCount = settledPollCount ?? Self.defaultSettledPollCount
        self.minimumObservationSeconds =
            minimumObservationSeconds ?? Self.defaultMinimumObservationSeconds
    }

    // MARK: - Lifecycle

    /// Request a trailer refresh and, if the server queued one, poll until
    /// it lands.
    ///
    /// - Parameters:
    ///   - baseline: the detail on screen when the user tapped. The identity
    ///     of every entry it already had is taken from it so "found" means a
    ///     *new* entry appeared, not merely that the item has some — an item
    ///     that already had trailers would otherwise report success on the
    ///     first poll tick, before the server refresh had a chance to run,
    ///     and burn the weekly slot for nothing.
    ///   - remoteVideosDisplayable: whether this platform can actually show
    ///     a remote (YouTube) card. False on tvOS without the YouTube app,
    ///     where the rail drops every remote entry: new remote videos then
    ///     end the run as ``Phase/foundUnplayable`` rather than as a
    ///     ``Phase/found`` that clears the status over an unchanged rail.
    ///   - onFound: invoked once, on the main actor, with the detail the
    ///     trailers were observed in, so the owner can apply that payload
    ///     directly rather than spending a second round trip on it.
    ///     No-op if a run is already in flight.
    func start(
        baseline: ItemDetail?,
        remoteVideosDisplayable: Bool = true,
        onFound: (@MainActor (ItemDetail) async -> Void)? = nil
    ) {
        guard task == nil else { return }
        let context = PollContext(
            baselineVideoKeys: Self.videoIdentities(baseline?.videos),
            baselineExtraIds: Self.extraIdentities(baseline?.extras),
            remoteVideosDisplayable: remoteVideosDisplayable,
            onFound: onFound
        )
        // A fresh run supersedes anything left over from an earlier one.
        interruptedPoll = nil
        // Assigned here rather than inside the task so a `stop()` landing
        // before the task body first runs still sees it.
        pollContext = context
        phase = .requesting
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.run(runID: runID, context: context)
        }
    }

    /// Cancel an in-flight run and drop back to idle. Safe to call when
    /// nothing is running; safe to call from `onDisappear`.
    ///
    /// Leaving the page also *acknowledges* a terminal outcome: the pill's
    /// dismiss timer dies with the view, so a phase kept across navigation
    /// would replay its message for three seconds on a visit minutes later.
    /// A run cancelled before reaching any outcome is instead remembered for
    /// ``resumeIfInterrupted()``.
    ///
    /// `.requesting` counts as interrupted as much as `.polling` does: the
    /// server may already have accepted the POST — and spent the item's
    /// weekly slot — before the connection was abandoned, so dropping the
    /// run here would leave the only route back to those trailers a retry
    /// that can answer nothing but "checked recently". The baselines were
    /// captured before the POST went out, so the resumed poll is measured
    /// against the same starting point either way; if the request never
    /// actually reached the server the poll simply settles quietly.
    func stop() {
        if phase == .requesting || phase == .polling, let pollContext {
            interruptedPoll = pollContext
        }
        if task != nil {
            Self.logger.debug("stopTrailerFetch phase=\(String(describing: self.phase), privacy: .public)")
            activeRunID = nil
            task?.cancel()
            task = nil
        }
        pollContext = nil
        phase = .idle
    }

    /// Pick a run back up after the page came back — e.g. the user played
    /// the movie (or one of its extras) while the refresh was still running,
    /// which cancelled it through ``stop()``.
    ///
    /// The refresh was already queued server-side and the weekly slot is
    /// already spent, so this deliberately does **not** re-POST; it only
    /// resumes observing. That holds for a run interrupted during the POST
    /// too: re-sending would either duplicate work the server already
    /// accepted or come straight back as `cooldown`, whereas polling on a
    /// request that genuinely never landed costs a few detail fetches and
    /// then settles. The poll window restarts rather than carrying the
    /// original deadline: a lapsed deadline would report "No trailers found"
    /// without a single fetch, even though the refresh very likely landed
    /// while the player was open. A resumed poll that observes nothing ends
    /// on the settle counter once its minimum observation time has passed,
    /// and on the window otherwise.
    ///
    /// No-op when idle, when a run is already going, or when the previous
    /// run reached an outcome — a terminal phase is acknowledged by
    /// ``stop()`` and is never resurrected here.
    func resumeIfInterrupted() {
        guard task == nil, phase == .idle, let context = interruptedPoll else { return }
        interruptedPoll = nil
        Self.logger.debug("resumeTrailerFetch")
        pollContext = context
        phase = .polling
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.poll(runID: runID, context: context)
        }
    }

    /// Clear a terminal message once the UI has shown it long enough.
    /// Leaves an in-flight run alone.
    func acknowledge() {
        guard !isFetching else { return }
        phase = .idle
    }

    // MARK: - Run

    /// Everything the poll loop needs, so a run interrupted mid-poll can be
    /// resumed without repeating the request that started it.
    private struct PollContext {
        /// Identities, not counts: a refresh that *replaces* a stale trailer
        /// with a current one leaves the count alone, and treating that as
        /// "nothing changed" would strand the new trailer — the polled
        /// payload is only published on ``Outcome/found``.
        let baselineVideoKeys: Set<String>
        let baselineExtraIds: Set<String>
        let remoteVideosDisplayable: Bool
        let onFound: (@MainActor (ItemDetail) async -> Void)?
    }

    private func run(runID: UUID, context: PollContext) async {
        defer {
            if activeRunID == runID {
                activeRunID = nil
                task = nil
                pollContext = nil
            }
        }

        let response: TrailerRefreshResponse
        do {
            response = try await request()
        } catch {
            guard isCurrentRun(runID) else { return }
            // The POST never came back with an answer. The server may still
            // have consumed the weekly slot before the connection died, so
            // this must not be reported as "No trailers found" — the next
            // tap would contradict it with "checked recently".
            let rateLimited = (error as? HTTPError)?.statusCode == 429
            Self.logger.debug("trailerFetchRequestFailed rateLimited=\(rateLimited, privacy: .public)")
            phase = .requestFailed(rateLimited: rateLimited)
            return
        }
        guard isCurrentRun(runID) else { return }

        switch response.status {
        case "queued":
            break
        case "cooldown":
            phase = .cooldown(response.nextAllowedAt)
            return
        case "disabled":
            phase = .disabled
            return
        default:
            // An unknown status is not something to poll on.
            Self.logger.debug("trailerFetchUnknownStatus status=\(response.status, privacy: .public)")
            phase = .exhausted
            return
        }

        phase = .polling
        await poll(runID: runID, context: context)
    }

    /// The observe half of the run: re-fetch detail until something new
    /// shows up or the window / settle counter ends it. Split out of
    /// ``run(runID:context:)`` so ``resumeIfInterrupted()`` can re-enter it
    /// without re-POSTing.
    private func poll(runID: UUID, context: PollContext) async {
        // Both entry points (``start(baseline:remoteVideosDisplayable:onFound:)``
        // and ``resumeIfInterrupted()``) publish `pollContext` synchronously,
        // so it is already in place for a `stop()` that lands here.
        defer {
            if activeRunID == runID {
                activeRunID = nil
                task = nil
                pollContext = nil
            }
        }

        let startedAt = Date.now
        let deadline = startedAt.addingTimeInterval(windowSeconds)
        // Before this the settle counter is not trusted to mean "the job
        // finished" — see `defaultMinimumObservationSeconds`. Clamped to the
        // window so a misconfigured floor can never outlive the hard cap.
        let settleAllowedAt = startedAt.addingTimeInterval(
            min(minimumObservationSeconds, windowSeconds)
        )
        var settledPolls = 0
        var signature: DetailSignature?

        while isCurrentRun(runID), Date.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
            guard isCurrentRun(runID) else { return }

            guard let detail = try? await fetchDetail() else {
                // A transient fetch failure says nothing about the refresh;
                // don't let it advance the settle counter.
                continue
            }
            guard isCurrentRun(runID) else { return }

            switch Self.outcome(
                detail: detail,
                baselineVideoKeys: context.baselineVideoKeys,
                baselineExtraIds: context.baselineExtraIds,
                remoteVideosDisplayable: context.remoteVideosDisplayable
            ) {
            case .found:
                Self.logger.debug("trailerFetchFound")
                phase = .found
                // Hand the payload the trailers were observed in straight to
                // the owner. Re-fetching instead would risk a transient
                // failure (or a stale replica) leaving the page showing the
                // old detail while this run has already reported success and
                // cleared its status.
                await context.onFound?(detail)
                return
            case .unplayable:
                // Only non-displayable remote videos arrived; the rail will
                // look exactly as it did. Say so rather than claiming a find.
                Self.logger.debug("trailerFetchFoundUnplayable")
                phase = .foundUnplayable
                return
            case .nothing:
                break
            }

            let current = DetailSignature(detail)
            if current == signature {
                settledPolls += 1
                // A quiet item only ends the run once the queued job has had
                // time to finish. Until then the counter keeps climbing but
                // cannot conclude anything.
                if settledPolls >= settledPollCount, Date.now >= settleAllowedAt {
                    Self.logger.debug("trailerFetchSettled")
                    phase = .exhausted
                    return
                }
            } else {
                settledPolls = 0
                signature = current
            }
        }

        guard isCurrentRun(runID) else { return }
        phase = .exhausted
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID && !Task.isCancelled
    }

    /// What a polled detail means for the run.
    enum Outcome: Equatable {
        /// Something the rail will render appeared.
        case found
        /// Remote videos appeared, but this platform hides them.
        case unplayable
        /// Nothing new: keep polling.
        case nothing
    }

    /// The identity of every remote video a rail would render, as the rail
    /// itself keys them (site + site key). Non-displayable sites are filtered
    /// out first — through the same ``TrailerRail/supportedVideos(_:)`` the
    /// rails use — so a provider result the clients cannot play (a Vimeo
    /// link) never passes for a visible one, on either side of the compare.
    nonisolated static func videoIdentities(_ videos: [ItemVideo]?) -> Set<String> {
        Set(TrailerRail.supportedVideos(videos).map { "\($0.site.lowercased()):\($0.siteKey)" })
    }

    /// The identity of every local extra: its own `contentId`, which is what
    /// the rail plays.
    nonisolated static func extraIdentities(_ extras: [ItemExtra]?) -> Set<String> {
        Set((extras ?? []).map(\.contentId))
    }

    /// Classify a polled detail against the baseline the run started from.
    ///
    /// Compares *identities*, not cardinality. A refresh that replaces a
    /// stale YouTube key with a current one holds the array at 1 → 1, and
    /// counting would call that "nothing" — leaving the working trailer
    /// unpublished (only ``Outcome/found`` hands the payload back) and the
    /// run to end on "No trailers found" with the weekly slot already spent.
    /// Both sides are baseline-relative — an item that already had trailers
    /// must not "find" them again on the first tick — so a set that merely
    /// arrives in a different order is correctly no change.
    ///
    /// `remoteVideosDisplayable` is the platform's own answer to "would a
    /// YouTube card even appear": false on tvOS without the YouTube app,
    /// where `TrailerRail.entries(…, allowRemote: false)` drops them. New
    /// remote videos alone are then a real server-side result that the user
    /// cannot see, which is neither ``Outcome/found`` nor ``Outcome/nothing``.
    /// Local extras always count — they play natively everywhere.
    static func outcome(
        detail: ItemDetail,
        baselineVideoKeys: Set<String>,
        baselineExtraIds: Set<String>,
        remoteVideosDisplayable: Bool = true
    ) -> Outcome {
        if !extraIdentities(detail.extras).isSubset(of: baselineExtraIds) { return .found }
        guard !videoIdentities(detail.videos).isSubset(of: baselineVideoKeys) else {
            return .nothing
        }
        return remoteVideosDisplayable ? .found : .unplayable
    }

    /// The cheap "did anything about this item change" probe behind the
    /// settle counter. `ItemDetail` is not `Equatable`, and comparing it
    /// whole would be the wrong test anyway — this covers the fields a
    /// metadata refresh rewrites as it progresses.
    private struct DetailSignature: Equatable {
        /// Identities rather than counts, for the same reason ``outcome``
        /// compares them: a swapped-out video leaves the count untouched, and
        /// a signature that missed that would settle the run on a poll where
        /// the refresh was demonstrably still writing. Unsupported sites are
        /// deliberately included here — this probe only asks "did the server
        /// touch this item", not "would the user see it".
        let videoKeys: Set<String>
        let extraIds: Set<String>
        let overview: String?
        let tagline: String?
        let posterUrl: String?
        let backdropUrl: String?
        let ratingTmdb: Double?
        let ratingImdb: Double?

        init(_ detail: ItemDetail) {
            videoKeys = Set((detail.videos ?? []).map { "\($0.site.lowercased()):\($0.siteKey)" })
            extraIds = Set((detail.extras ?? []).map(\.contentId))
            overview = detail.overview
            tagline = detail.tagline
            posterUrl = detail.posterUrl
            backdropUrl = detail.backdropUrl
            ratingTmdb = detail.ratingTmdb
            ratingImdb = detail.ratingImdb
        }
    }
}
