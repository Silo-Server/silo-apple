import Foundation
import os

/// Drives the manual "Find Trailers" action for a single item.
///
/// The server has no job id for this flow: you `POST
/// /items/{id}/trailers/refresh` and then observe completion by re-fetching
/// item detail until trailers show up or a window lapses — the same
/// request-then-poll shape `PersonDetailViewModel` uses for person metadata,
/// with its policy (3s cadence, 120s window, settled-poll counter) carried
/// over. Two of the three server outcomes never poll at all: `cooldown` (the
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
/// stopped mid-poll (the user opened the movie while the fetch was running)
/// can be picked back up with ``resumeIfInterrupted()`` on the next appear,
/// without spending another server-side cooldown slot.
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
        /// Trailers (or new extras) arrived; the owner has been asked to
        /// refresh.
        case found
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
    /// Hard cap on the poll loop.
    static let defaultWindowSeconds: TimeInterval = 120
    /// Consecutive polls in which nothing about the item changed after which
    /// the refresh is treated as settled — the server ran and this is all it
    /// found. Any observed change (new artwork, a rewritten overview, a
    /// rating) resets the counter, because it means the refresh is still
    /// landing writes and the videos may yet follow.
    static let defaultSettledPollCount = 5

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

    private var task: Task<Void, Never>?
    private var activeRunID: UUID?
    /// Set for the lifetime of the poll loop, so ``stop()`` can hand an
    /// interrupted poll to ``resumeIfInterrupted()``.
    private var pollContext: PollContext?
    /// A poll ``stop()`` cancelled before it reached any outcome. Consumed
    /// (once) by ``resumeIfInterrupted()``.
    private var interruptedPoll: PollContext?

    /// The three policy knobs are `nil`-defaulted and resolved in the body
    /// rather than defaulted to `Self.default…` in the signature: a default
    /// argument is evaluated in the caller's context, and these constants
    /// live on a `@MainActor` type. Tests pass a millisecond cadence.
    init(
        request: @MainActor @escaping () async throws -> TrailerRefreshResponse,
        fetchDetail: @MainActor @escaping () async throws -> ItemDetail,
        pollInterval: Duration? = nil,
        windowSeconds: TimeInterval? = nil,
        settledPollCount: Int? = nil
    ) {
        self.request = request
        self.fetchDetail = fetchDetail
        self.pollInterval = pollInterval ?? Self.defaultPollInterval
        self.windowSeconds = windowSeconds ?? Self.defaultWindowSeconds
        self.settledPollCount = settledPollCount ?? Self.defaultSettledPollCount
    }

    // MARK: - Lifecycle

    /// Request a trailer refresh and, if the server queued one, poll until
    /// it lands.
    ///
    /// - Parameters:
    ///   - baseline: the detail on screen when the user tapped. Both counts
    ///     are taken from it so "found" means *new* entries appeared, not
    ///     merely that the item has some — an item that already had trailers
    ///     would otherwise report success on the first poll tick, before the
    ///     server refresh had a chance to run, and burn the weekly slot for
    ///     nothing.
    ///   - onFound: invoked once, on the main actor, when trailers arrive —
    ///     the owner re-runs its own load so the response cache is rewritten.
    ///     No-op if a run is already in flight.
    func start(
        baseline: ItemDetail?,
        onFound: (@MainActor () async -> Void)? = nil
    ) {
        guard task == nil else { return }
        let context = PollContext(
            baselineVideoCount: TrailerRail.supportedVideos(baseline?.videos).count,
            baselineExtraCount: baseline?.extras?.count ?? 0,
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
    /// A poll cancelled before reaching any outcome is instead remembered
    /// for ``resumeIfInterrupted()``.
    func stop() {
        if phase == .polling, let pollContext {
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

    /// Pick a poll back up after the page came back — e.g. the user played
    /// the movie (or one of its extras) while the refresh was still running,
    /// which cancelled the poll through ``stop()``.
    ///
    /// The refresh was already queued server-side and the weekly slot is
    /// already spent, so this deliberately does **not** re-POST; it only
    /// resumes observing. The poll window restarts rather than carrying the
    /// original deadline: a lapsed deadline would report "No trailers found"
    /// without a single fetch, even though the refresh very likely landed
    /// while the player was open. The settle counter still ends a resumed
    /// poll within a few seconds when nothing is changing.
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
        let baselineVideoCount: Int
        let baselineExtraCount: Int
        let onFound: (@MainActor () async -> Void)?
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
        // Both entry points (``start(baseline:onFound:)`` and
        // ``resumeIfInterrupted()``) publish `pollContext` synchronously, so
        // it is already in place for a `stop()` that lands here.
        defer {
            if activeRunID == runID {
                activeRunID = nil
                task = nil
                pollContext = nil
            }
        }

        let deadline = Date.now.addingTimeInterval(windowSeconds)
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

            if Self.isFound(
                detail: detail,
                baselineVideoCount: context.baselineVideoCount,
                baselineExtraCount: context.baselineExtraCount
            ) {
                Self.logger.debug("trailerFetchFound")
                phase = .found
                await context.onFound?()
                return
            }

            let current = DetailSignature(detail)
            if current == signature {
                settledPolls += 1
                if settledPolls >= settledPollCount {
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

    /// The refresh delivered something worth showing: a remote video or a
    /// local extra that wasn't there before the request.
    ///
    /// Both sides are baseline-relative — an item that already had trailers
    /// must not "find" them again on the first tick — and remote videos are
    /// counted through ``TrailerRail/supportedVideos(_:)`` so a provider
    /// result the rails cannot render (a Vimeo link) never passes for a
    /// visible one.
    static func isFound(
        detail: ItemDetail,
        baselineVideoCount: Int,
        baselineExtraCount: Int
    ) -> Bool {
        if TrailerRail.supportedVideos(detail.videos).count > baselineVideoCount { return true }
        return (detail.extras?.count ?? 0) > baselineExtraCount
    }

    /// The cheap "did anything about this item change" probe behind the
    /// settle counter. `ItemDetail` is not `Equatable`, and comparing it
    /// whole would be the wrong test anyway — this covers the fields a
    /// metadata refresh rewrites as it progresses.
    private struct DetailSignature: Equatable {
        let videoCount: Int
        let extraCount: Int
        let overview: String?
        let tagline: String?
        let posterUrl: String?
        let backdropUrl: String?
        let ratingTmdb: Double?
        let ratingImdb: Double?

        init(_ detail: ItemDetail) {
            videoCount = detail.videos?.count ?? 0
            extraCount = detail.extras?.count ?? 0
            overview = detail.overview
            tagline = detail.tagline
            posterUrl = detail.posterUrl
            backdropUrl = detail.backdropUrl
            ratingTmdb = detail.ratingTmdb
            ratingImdb = detail.ratingImdb
        }
    }
}
