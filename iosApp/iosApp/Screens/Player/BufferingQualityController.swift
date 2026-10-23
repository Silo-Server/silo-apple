import Foundation

/// Lowers quality when playback keeps buffering. One instance per player, shared
/// by the iOS, iPadOS, tvOS and macOS players.
///
/// The spec is the server repo's `docs/design/2026-10-17-buffering-quality.md`:
/// this type implements its stall tracker and trigger (Terms) and every table
/// under "Behaviour". `BufferingQualityControllerTests` replays the vendored
/// conformance vectors (`Tests/Fixtures/BufferingQuality/vectors.json`) case for
/// case, as web and Android do.
///
/// The player feeds it plan adoptions, media events and the viewer's answers,
/// and acts on what ``onOutput`` emits: replans to send, pills and notices to
/// show, and `plan_summary` events. It performs no I/O itself.
///
/// ### Evaluation
///
/// The trigger is evaluated when a stall ends (``playing()``) and when a stall
/// in progress reaches `LONG_STALL_MS`. While that long stall continues, it is
/// evaluated again when a time-based suppression (cooldown, re-offer) expires
/// or the undo pill leaves the screen (its timer or Back). Starting a wait
/// never evaluates old history, and a suppression that expires while playing
/// offers nothing.
///
/// Until a plan of the attempt has played, the trigger acts only on evidence
/// that the plan's media arrived more slowly than its delivered bitrate
/// (``measuredThroughputKbps``, else ``arrivalLowerBoundKbps``), as a missed
/// start deadline does, and a start wait the first frame ends is a counted
/// stall only with it. A start that
/// cannot begin for another reason, such as a subtitle rendition the server
/// is still extracting, would otherwise lower Auto rung by rung while each
/// lower plan fails the same way, and a slow one would lower at its first
/// frame. Without evidence the start runs on to the player's deadline and
/// failure path.
///
/// ### Timing
///
/// Arithmetic is in integer milliseconds of the clock's elapsed real time
/// (``PlayerPromptClock/elapsedMs``), so the vectors' times compare exactly and
/// a change of the wall clock moves nothing. A pill's timer runs on the same
/// clock, and a pause or a competing pill freezes it.
@MainActor
@Observable
final class BufferingQualityController {
    // MARK: - Spec constants

    /// `STARTUP_GRACE_MS`, from a plan's first wait or, when none came before
    /// it, its first frame (when playback first runs).
    nonisolated static let startupGraceMs = 10_000
    /// `STALL_MIN_MS`: a shorter stall is not a counted stall.
    nonisolated static let stallMinMs = 1_000
    /// `STALLS_BEFORE_TRIGGER` counted stalls ended within `STALL_WINDOW_MS`.
    nonisolated static let stallsBeforeTrigger = 2
    nonisolated static let stallWindowMs = 120_000
    /// `LONG_STALL_MS`: one stall this long triggers on its own.
    nonisolated static let longStallMs = 6_000
    /// `PROMPT_SECONDS`, for both pills.
    nonisolated static let promptSeconds: TimeInterval = 15
    nonisolated static let reofferMinMs = 120_000
    nonisolated static let noLowerCooldownMs = 300_000
    nonisolated static let rearmAfterUnadoptedMs = 60_000
    /// `RENDERER_WAIT_BUFFER_MS`: a wait that begins with more media than this
    /// buffered past the playhead is the renderer's, not a stall
    /// (``WaitCause/renderer``).
    nonisolated static let rendererWaitBufferMs = 1_000
    /// `RENDERER_WAIT_AMPLE_MS` (outside the vectors): on the software route,
    /// a wait that comes to hold more media than this past the playhead is
    /// the renderer's until it ends, however far the buffer then falls. That
    /// route resumes at a 2 s lead, under half of this. AVPlayer has no ample
    /// threshold (``BufferingSignalMapper``).
    nonisolated static let rendererWaitAmpleMs = 5_000
    /// `STEP_DOWN_RATIO`, as the vectors state it. The estimate itself is the
    /// exact integer `delivered × 7 / 10` (``stepDownEstimate(deliveredKbps:)``).
    nonisolated static let stepDownRatio = 0.7
    nonisolated static let minEstimateKbps = 100

    // MARK: - Copy

    nonisolated static let promptTitle = "Playback keeps buffering"
    nonisolated static let lowerAction = "Lower quality"
    nonisolated static let keepAction = "Keep quality"
    nonisolated static let undoCaption = "Quality lowered to stop buffering"
    nonisolated static let undoAction = "Restore quality"
    nonisolated static let loweredNotice = "Quality lowered to stop buffering"
    nonisolated static let cantLowerNotice = "Can't lower quality for this video"

    /// The `quality_preference` / plan quality for Auto.
    nonisolated static let autoQuality = "auto"
    private nonisolated static let promptMs = Int(promptSeconds * 1000)

    // MARK: - Types

    /// One `available_qualities` entry.
    struct QualityRung: Equatable {
        var label: String
        var bitrateKbps: Int
    }

    /// What the controller reads from an adopted playback plan.
    struct Plan: Equatable {
        /// The adoption's identity: every adoption is a new plan, so the host
        /// gives each one a new id, as web's `planRevision` does. The server's
        /// `plan_id` is a hash of the route, so a lowering that comes back
        /// unchanged repeats it, and keying on it would hide that result.
        var id: String
        /// `effective_recipe.bitrate_kbps`, else `source.bitrate_kbps`.
        var deliveredKbps: Int?
        /// `auto`, or the label of the rung the viewer picked.
        var quality: String
        /// The `available_qualities` label the plan names in
        /// `active_quality` (with `plan_active_quality_v1`), or nil when it
        /// names none. Lower quality steps from it, or from the delivered
        /// bitrate when that is lower.
        var activeQuality: String? = nil
        var availableQualities: [QualityRung]
        /// `degradation_warnings` contains `quality_reduction_unavailable`.
        var qualityReductionUnavailable: Bool
        /// The estimate the plan was requested with, for `plan_summary`, when
        /// the host knows it.
        var requestedBandwidthEstimateKbps: Int? = nil

        var isAuto: Bool { quality == BufferingQualityController.autoQuality }
    }

    /// Why the player is waiting. Only a `.network` wait can be a stall.
    enum WaitCause: Equatable {
        case network
        case seek
        case pause
        case reload
        /// The wait began with more than `RENDERER_WAIT_BUFFER_MS` of media
        /// buffered past the playhead: the decoder or renderer is behind, not
        /// the network. A `.network` wait that follows means the buffer fell
        /// to the threshold, and the stall begins then.
        case renderer
    }

    /// The fields of a replan for the host to send: the controller's own
    /// `quality_change`, or one the player sends for its own reasons
    /// (``clientReplan(operation:)``).
    struct ReplanRequest: Equatable {
        var operation: String = PlaybackProtocolV3.ReplanOperation.qualityChange
        var qualityPreference: String
        var bandwidthEstimateKbps: Int? = nil
        /// `observed_rebuffer`. Only sent to a server that advertises
        /// `buffering_quality_v1`.
        var bandwidthEstimateSource: String? = nil
        /// `clear`. Only sent to a server that advertises `buffering_quality_v1`.
        var learnedLimit: String? = nil
        /// What the plan's media measurably arrived at, the evidence an
        /// automatic lowering before anything of the attempt played, or at a
        /// missed start deadline, rested on; sent as `observed_throughput_kbps`.
        /// Nil on every other replan: the player adds the playing plan's own
        /// figure.
        var observedThroughputKbps: Int? = nil

        /// **Restore quality**: Auto with no estimate. Every lowering on Auto
        /// carries an estimate, and one on a picked quality names a rung.
        var isRestore: Bool {
            qualityPreference == BufferingQualityController.autoQuality && bandwidthEstimateKbps == nil
        }
    }

    /// A display-only notice.
    enum Notice: Equatable {
        /// An accepted lowering came back lower.
        case lowered
        /// No lower rung (once per title), or a lowering that came back no lower.
        case cantLower

        var text: String {
            switch self {
            case .lowered: return BufferingQualityController.loweredNotice
            case .cantLower: return BufferingQualityController.cantLowerNotice
            }
        }
    }

    enum PillKind: Equatable {
        /// "Playback keeps buffering": Lower quality / Keep quality.
        case prompt
        /// "Quality lowered to stop buffering": Restore quality.
        case undo
    }

    struct Pill: Equatable {
        let kind: PillKind
        /// When the timer runs out; nil while a pause holds it.
        let deadline: Date?
        /// Seconds left as of the last arm or freeze.
        let remaining: TimeInterval
        /// Where a fresh timer starts, for drawing progress against it.
        let total: TimeInterval
    }

    /// `buffering_action`: the last action on a plan.
    enum Action: String, Equatable, Sendable {
        case none
        /// A trigger in `never`.
        case ignored
        /// Lowered automatically.
        case lowered
        case restored
        case accepted
        case kept
        case timedOut = "timed_out"
        case cantLower = "cant_lower"
    }

    /// The `plan_summary` route event, for a plan that stopped being the
    /// playing plan.
    struct PlanSummary: Equatable, Sendable {
        var planId: String
        var playedMs: Int
        var stallCount: Int
        /// Stall time with startup grace and outages excluded.
        var stallTotalMs: Int
        var stallLongestMs: Int
        var deliveredKbps: Int?
        var mode: BufferingQualityMode
        var action: Action
        var bandwidthEstimateKbps: Int?
        /// The rate the plan's media requests received data, which the
        /// player measures and adds to a summary it sends at once.
        var throughputKbps: Int? = nil
    }

    enum Output: Equatable {
        case replan(ReplanRequest)
        /// A pill came on screen: first, or again after a higher-priority pill
        /// hid. The vectors' `prompt_shown` and `undo_shown`.
        case pillShown(PillKind)
        case notice(Notice)
        case planSummary(PlanSummary)
    }

    // MARK: - State

    @ObservationIgnored var mode: BufferingQualityMode = .default
    /// The server advertises `buffering_quality_v1`. Without it the replans are
    /// the same, minus `bandwidth_estimate_source` and `learned_limit`.
    @ObservationIgnored var sendsBufferingQualityFields = false
    /// Inside a Watch Party room the room's own offer applies: no trigger acts
    /// and no pill shows, while stall stats are still recorded. Leaving the
    /// room starts trigger history fresh, with the grace over.
    @ObservationIgnored var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended { withdrawPill() } else { clearHistory(at: nowMs) }
        }
    }
    @ObservationIgnored var onOutput: ((Output) -> Void)?
    /// What the playing plan's media has measurably arrived at so far, in
    /// kbps, or nil when the player has no figure for it. Read when a
    /// lowering needs evidence that the link is too slow for the plan, and
    /// sent with it as `observed_throughput_kbps`.
    @ObservationIgnored var measuredThroughputKbps: () -> Int? = { nil }
    /// A lower bound on what the plan's media arrived at, for evidence only
    /// when ``measuredThroughputKbps`` has no figure: the counted reader's
    /// rate while another reader of the source, such as an embedded
    /// subtitle's prefetch, may have shared the link. Its share reads low,
    /// so it is never sent or learned as a limit, but a plan waiting for
    /// media while its reader gets less than the delivered bitrate is still
    /// starved by the link.
    @ObservationIgnored var arrivalLowerBoundKbps: () -> Int? = { nil }
    /// What the link delivered while the plan's media arrived, every reader
    /// of a shared link included: what a lowering sends as
    /// `observed_throughput_kbps`, else ``measuredThroughputKbps``.
    @ObservationIgnored var linkThroughputKbps: () -> Int? = { nil }

    /// The actionable pill on screen, or nil.
    private(set) var pill: Pill?

    /// The step-down estimate of the latest Auto lowering, from when its
    /// replan is sent until **Restore quality**, a quality change this
    /// controller did not send, or a new attempt. The player's own later Auto
    /// replans repeat it without a source (``clientReplan(operation:)``), so a
    /// lowering holds where no learned limit applies. It is never stored.
    @ObservationIgnored private(set) var keptEstimateKbps: Int?

    @ObservationIgnored private let clock: PlayerPromptClock
    @ObservationIgnored private var current: PlanState?

    // The player, across plans.
    /// When the playing state began; nil while not playing.
    @ObservationIgnored private var playingSince: Int?
    @ObservationIgnored private var isPaused = false
    /// The player waits on the renderer, not the network.
    @ObservationIgnored private var rendererWaiting = false
    @ObservationIgnored private var transportTrouble = false
    /// When the last transport trouble ended.
    @ObservationIgnored private var transportTroubleEndedAt: Int?
    @ObservationIgnored private var competingPillVisible = false

    /// How far the current attempt has got. A plan adopted before any of
    /// its plans played continues the attempt's start.
    @ObservationIgnored private var attemptStage = AttemptStage.new

    // The title, across plans.
    @ObservationIgnored private var answered = false
    @ObservationIgnored private var noLowerRungNoticeShown = false
    /// When a prompt that timed out first reached the screen. Only a timeout
    /// starts the re-offer wait; a quality change or new content ends it.
    @ObservationIgnored private var lastOfferAt: Int?
    /// The replan this controller sent, until the next plan settles it.
    @ObservationIgnored private var pendingReplan: PendingReplan?
    /// The viewer's quality pick is sent and its plan not yet adopted.
    @ObservationIgnored private var pickPending = false

    @ObservationIgnored private var presented: PresentedPill?

    @ObservationIgnored private var longStallTimer: PlayerPromptTimer?
    @ObservationIgnored private var suppressionTimer: PlayerPromptTimer?
    @ObservationIgnored private var rearmTimer: PlayerPromptTimer?
    @ObservationIgnored private var pillTimer: PlayerPromptTimer?

    init(clock: PlayerPromptClock? = nil) {
        self.clock = clock ?? LivePlayerPromptClock()
    }

    // MARK: - Plans

    /// A plan became the playing plan.
    ///
    /// It ends the outgoing plan (emitting its summary), takes down any pill,
    /// and starts fresh history. A plan that answers this controller's pending
    /// replan settles it: a lower plan shows the undo pill (automatic) or the
    /// lowered notice (accepted); one that is no lower, or carries
    /// `quality_reduction_unavailable`, shows the can't-lower notice and starts
    /// `NO_LOWER_COOLDOWN_MS`. While the viewer's pick is pending, neither
    /// pill nor notice shows. Pass `controllerInitiated: false` for a plan
    /// that answers a replan the controller did not send; it settles nothing.
    ///
    /// A plan adopted before any plan of the attempt played, such as a
    /// failure recovery before the first frame or a lowering made during the
    /// start wait, continues the attempt's start: it has no grace of its own
    /// and keeps the one the start began. A plan adopted after one played,
    /// such as a lowering, a pick or a track change, replaces a source that
    /// played: until it plays, its loading is a source reload, never a
    /// stall, and only a missed start deadline (``startDeadlinePassed()``)
    /// lowers it.
    func planAdopted(_ plan: Plan, controllerInitiated: Bool = true) {
        let now = nowMs
        // During the start, a stall in progress carries over as the new
        // plan's first wait, so a start that never begins is still caught.
        let wasStalled = current?.stall != nil
        let startGrace = attemptStage == .adopted ? current?.graceEndsAt : nil
        endPlan(at: now)
        let pending = controllerInitiated ? pendingReplan : nil
        pendingReplan = nil
        var state = PlanState(plan: plan)
        state.graceEndsAt = startGrace
        // A plan adopted while playing has its first frame now, and its
        // startup grace counts from there.
        if playingSince != nil {
            playingSince = now
            state.graceEndsAt = now + Self.startupGraceMs
        } else {
            state.reloading = attemptStage == .played
        }
        if attemptStage == .new { attemptStage = .adopted }
        current = state
        if wasStalled, !state.reloading { beginStall(at: now) }
        if let pending { settle(pending, at: now) }
    }

    /// The playing plan's summary as if it ended now, without ending it: what
    /// the player keeps on the device in case the app never gets to end it.
    var runningSummary: PlanSummary? {
        current.map { summary(closing: $0, at: nowMs) }
    }

    /// The plan stopped or failed with no successor: emits its summary.
    func planEnded() {
        endPlan(at: nowMs)
        pendingReplan = nil
        playingSince = nil
    }

    /// The player starts a new playback attempt of the title: the kept
    /// estimate belonged to the one that lowered, and its first plan starts
    /// afresh.
    func newAttempt() {
        attemptStage = .new
        keptEstimateKbps = nil
        pendingReplan?.priorKeptEstimateKbps = nil
    }

    /// New content: emits the current plan's summary and forgets every
    /// decision, including the answer, the once-per-title notice and the kept
    /// estimate. The host's ongoing conditions (mode, suspension, transport
    /// trouble, a competing pill) carry over.
    func reset() {
        planEnded()
        newAttempt()
        isPaused = false
        answered = false
        noLowerRungNoticeShown = false
        lastOfferAt = nil
        pickPending = false
    }

    // MARK: - Media events

    func playing() {
        let now = nowMs
        isPaused = false
        rendererWaiting = false
        // The plan ran again: a reload that ended its stall did not end it.
        current?.stallEndedByReload = false
        current?.reloading = false
        if playingSince == nil {
            playingSince = now
            if current != nil, current?.graceEndsAt == nil { current?.graceEndsAt = now + Self.startupGraceMs }
        }
        // The start wait the first frame ends counts only on evidence.
        let counts = attemptStage == .played || current.map { arrivesSlowly($0.plan) } == true
        if current != nil { attemptStage = .played }
        endStall(at: now, resumed: counts)
        refreshPill()
        evaluate(at: now)
    }

    /// The player is waiting. A `.network` wait is a stall, except while a
    /// replacement of a plan that played loads; any other cause ends a stall
    /// in progress without counting it. A `.network` or `.renderer` wait
    /// means playback wants to run, so a paused pill's timer resumes.
    ///
    /// `startedAgoMs` back-dates a wait the host noticed late, such as a
    /// frozen playhead it sees only after a threshold. It never reaches back
    /// past the start of the current playing state.
    func waiting(cause: WaitCause = .network, startedAgoMs: Int = 0) {
        let now = nowMs
        rendererWaiting = cause == .renderer
        // Backdated no further than playback last ran: a wait noticed late
        // after a pause began when playback resumed, not inside the pause.
        let began = playingSince.map { max($0, now - max(0, startedAgoMs)) } ?? now
        leavePlaying(at: began)
        guard cause == .network else {
            endStall(at: now, resumed: false, byReload: cause == .reload)
            if cause == .renderer {
                isPaused = false
                refreshPill()
            }
            return
        }
        isPaused = false
        if let state = current, state.stall == nil, !state.reloading { beginStall(at: began) }
        refreshPill()
    }

    func paused() {
        let now = nowMs
        rendererWaiting = false
        leavePlaying(at: now)
        endStall(at: now, resumed: false)
        isPaused = true
        refreshPill()
    }

    func seeked() {
        endStall(at: nowMs, resumed: false)
    }

    /// Media requests are failing or the device is offline. A stall that runs
    /// into trouble drops its time so far, and stall time during trouble never
    /// counts; a stall still in progress when the trouble ends is timed from
    /// then.
    func transportTroubleChanged(_ trouble: Bool) {
        guard trouble != transportTrouble else { return }
        transportTrouble = trouble
        let now = nowMs
        if !trouble { transportTroubleEndedAt = now }
        guard let state = current, var stall = state.stall else { return }
        if trouble {
            stall.measuredFrom = nil
            stall.timedFrom = nil
            cancelStallTimers()
        } else {
            let from = max(now, state.graceEndsAt ?? now)
            stall.timedFrom = from
            stall.measuredFrom = from
        }
        current?.stall = stall
        if !trouble { scheduleLongStallTimer() }
    }

    /// The replan this controller sent failed. The plan keeps playing and is
    /// watched again at the rearm counted from the send.
    func replanFailed() {
        pendingReplan = nil
    }

    /// The player could not send this controller's replan at all. It fails
    /// and rearms like ``replanFailed()``, and a lowering it never sent leaves
    /// no kept estimate: the one from before it stays.
    func replanRefused() {
        if let pending = pendingReplan {
            keptEstimateKbps = pending.priorKeptEstimateKbps
        }
        pendingReplan = nil
    }

    /// The plan failed before its first frame because the player's own start
    /// deadline passed: the attempt's first plan or a replacement, even one whose
    /// loading is a source reload and so never a stall. On Auto in `always`, when
    /// ``measuredThroughputKbps`` shows the plan's media arriving below its
    /// delivered bitrate, it lowers as a long stall would: a `quality_change`
    /// with the step-down estimate, `observed_rebuffer` and that figure. True
    /// when that replan was sent. False leaves the failure to the player's usual
    /// recovery, whose `failure_recovery` keeps the server's exclusion of the
    /// failed route: no measurement (nothing arrived, or the player cannot
    /// measure it), media that arrived at or above the bitrate (the stream fails
    /// for another reason, such as one the device cannot play), `ask` or `never`,
    /// a title the viewer answered (Keep or Restore), a picked quality, a Watch
    /// Party, an outage or one that ended less than `LONG_STALL_MS` ago (the
    /// start never had a fair run), a renderer wait, a pick pending, a lowering
    /// pending or that no plan answered, no lower rung, or a plan a lowering was
    /// refused for or already got back no lower.
    func startDeadlinePassed() -> Bool {
        guard mode == .always, !answered, !isSuspended, !transportTrouble,
              transportTroubleEndedAt.map({ nowMs - $0 >= Self.longStallMs }) ?? true,
              !rendererWaiting, !pickPending, rearmTimer == nil,
              let state = current, state.plan.isAuto, !state.plan.qualityReductionUnavailable,
              let delivered = state.plan.deliveredKbps, arrivesSlowly(state.plan),
              state.cooldownUntil == nil, Self.lowerRung(in: state.plan) != nil,
              let estimate = Self.stepDownEstimate(deliveredKbps: delivered) else { return false }
        withdrawPill()
        sendReplan(
            .lowered, qualityPreference: Self.autoQuality, estimateKbps: estimate, fromKbps: delivered,
            observedThroughputKbps: observedThroughputKbps(of: state.plan)
        )
        return true
    }

    // MARK: - Pill answers

    /// **Lower quality** on the prompt.
    func selectLower() {
        guard pill?.kind == .prompt, let plan = current?.plan else { return }
        withdrawPill()
        guard let rung = Self.lowerRung(in: plan) else { cantLower(); return }
        if plan.isAuto {
            guard let estimate = Self.stepDownEstimate(deliveredKbps: plan.deliveredKbps) else {
                cantLower()
                return
            }
            sendReplan(.accepted, qualityPreference: Self.autoQuality, estimateKbps: estimate, fromKbps: plan.deliveredKbps)
        } else {
            // This playback only: the saved preference does not change.
            sendReplan(
                .accepted,
                qualityPreference: rung.label,
                fromKbps: plan.deliveredKbps ?? Self.activeBitrate(of: plan)
            )
        }
    }

    /// **Keep quality** on the prompt: answers the title at this quality.
    func selectKeep() {
        guard pill?.kind == .prompt else { return }
        withdrawPill()
        answered = true
        current?.action = .kept
    }

    /// **Restore quality** on the undo pill: answers the title and clears the
    /// learned limit.
    func selectRestore() {
        guard pill?.kind == .undo, current != nil else { return }
        withdrawPill()
        answered = true
        keptEstimateKbps = nil
        sendReplan(.restored, qualityPreference: Self.autoQuality, learnedLimit: PlaybackProtocolV3.LearnedLimit.clear)
    }

    /// Back / Menu / Escape. On the prompt it answers like Keep; on the undo pill
    /// it only hides it, as its timer ending does, so a stall in progress that
    /// has reached `LONG_STALL_MS` is evaluated at once. True when a visible
    /// pill consumed the press, so a second Back behaves normally.
    @discardableResult
    func back() -> Bool {
        switch pill?.kind {
        case .prompt:
            selectKeep()
            return true
        case .undo:
            withdrawPill()
            evaluateLongStall()
            return true
        case nil:
            return false
        }
    }

    /// Select at the player root: the visible pill's primary action.
    func selectPrimary() {
        switch pill?.kind {
        case .prompt: selectLower()
        case .undo: selectRestore()
        case nil: break
        }
    }

    // MARK: - Host inputs

    /// A quality change this controller did not send: the viewer's pick, or
    /// the switch between the Wi-Fi and cellular qualities. Any pill hides,
    /// history clears, the title is no longer answered, and the kept estimate
    /// goes. The re-offer wait ends with it, since the next offer would be
    /// about a different quality, and a pending controller replan is dropped
    /// so the new plan is not read as its result. Call it only once the
    /// player has accepted the change; for a pick, as its plan is adopted,
    /// just before ``planAdopted(_:controllerInitiated:)``.
    func qualityChanged() {
        pickPending = false
        keptEstimateKbps = nil
        answered = false
        lastOfferAt = nil
        pendingReplan = nil
        rearmTimer?.cancel()
        rearmTimer = nil
        withdrawPill()
        clearHistory(at: nowMs)
    }

    /// The viewer picked a quality from the menu and the player sent it. Any
    /// pill hides, and nothing prompts or lowers while the pick is pending.
    /// The answer, history and kept estimate change only when its plan is
    /// adopted (``qualityChanged()``), and not at all if it is refused
    /// (``pickRefused()``).
    func pickSent() {
        pickPending = true
        withdrawPill()
    }

    /// The pick from ``pickSent()`` never became a plan. Nothing else
    /// changes, and a long stall in progress is evaluated at once.
    func pickRefused() {
        guard pickPending else { return }
        pickPending = false
        evaluateLongStall()
    }

    /// A replan the player sends for its own reasons: a track change, seek
    /// reanchor, seek failure recovery, failure recovery or output change.
    /// It asks for the adopted plan's quality and, on Auto, carries the kept
    /// estimate without a source: it repeats an earlier observation rather
    /// than reporting a new one. The player adds its other request fields.
    /// Nil before a plan is adopted.
    func clientReplan(operation: String) -> ReplanRequest? {
        guard let plan = current?.plan else { return nil }
        return ReplanRequest(
            operation: operation,
            qualityPreference: plan.quality,
            bandwidthEstimateKbps: plan.isAuto ? keptEstimateKbps : nil
        )
    }

    /// The intro-skip, segment-skip or Next Up pill is showing, or the player
    /// cannot show pills at all (picture in picture, the app in the
    /// background, a minimized window). At most one actionable pill shows: a
    /// buffering pill that would appear now waits, and one already up hides
    /// with its timer frozen. Either shows when the other pill hides or the
    /// full player returns, if the plan has not changed.
    func setCompetingPillVisible(_ visible: Bool) {
        guard visible != competingPillVisible else { return }
        competingPillVisible = visible
        refreshPill()
    }

    // MARK: - Trigger

    private func evaluate(at now: Int) {
        guard !isSuspended, !isPaused, !transportTrouble, let state = current else { return }
        current?.endedStalls.removeAll { now - $0.at >= Self.stallWindowMs }
        guard Self.triggered(state, at: now) else { return }
        // Before anything of the attempt played, the wait is the network's
        // only on evidence; without it, as if nothing triggered.
        guard attemptStage == .played || arrivesSlowly(state.plan) else { return }
        let evidenceKbps = attemptStage == .played ? nil : observedThroughputKbps(of: state.plan)

        // A suppressed trigger leaves history intact for a later evaluation.
        if answered || pickPending || rearmTimer != nil || presented != nil { return }
        if let until = state.cooldownUntil, now < until {
            watchStall(until: until)
            return
        }
        guard mode != .never else {
            current?.action = .ignored
            return
        }

        let plan = state.plan
        guard Self.lowerRung(in: plan) != nil else { cantLower(); return }
        if plan.isAuto {
            // Auto without a usable step-down estimate (no delivered bitrate,
            // or under MIN_ESTIMATE_KBPS) has no lower rung.
            guard let estimate = Self.stepDownEstimate(deliveredKbps: plan.deliveredKbps) else {
                cantLower()
                return
            }
            if mode == .always {
                sendReplan(
                    .lowered, qualityPreference: Self.autoQuality, estimateKbps: estimate, fromKbps: plan.deliveredKbps,
                    observedThroughputKbps: evidenceKbps
                )
                return
            }
        }
        if let lastOfferAt, now - lastOfferAt < Self.reofferMinMs {
            watchStall(until: lastOfferAt + Self.reofferMinMs)
            return
        }
        present(.prompt)
    }

    private static func triggered(_ state: PlanState, at now: Int) -> Bool {
        if let from = state.stall?.timedFrom, now - from >= longStallMs { return true }
        let recent = state.endedStalls.filter { now - $0.at < stallWindowMs }
        return recent.contains(where: \.long) || recent.count >= stallsBeforeTrigger
    }

    /// Keeps watching a long stall that a time-based suppression held back:
    /// evaluates again when it expires, if the stall is still in progress.
    private func watchStall(until deadline: Int) {
        suppressionTimer?.cancel()
        suppressionTimer = nil
        guard current?.stall != nil else { return }
        suppressionTimer = schedule(at: deadline) { controller in
            controller.suppressionTimer = nil
            controller.evaluateLongStall()
        }
    }

    /// Evaluates only if a stall in progress has reached `LONG_STALL_MS`.
    private func evaluateLongStall() {
        let now = nowMs
        guard let from = current?.stall?.timedFrom, now - from >= Self.longStallMs else { return }
        evaluate(at: now)
    }

    /// Evidence the plan's media arrives too slowly: its measured throughput,
    /// else the lower bound of a shared link, below its delivered bitrate.
    /// No figure, or one at or above the bitrate, is no evidence.
    private func arrivesSlowly(_ plan: Plan) -> Bool {
        guard let delivered = plan.deliveredKbps,
              let measured = measuredThroughputKbps() ?? arrivalLowerBoundKbps() else { return false }
        return measured < delivered
    }

    /// The figure a lowering sends as `observed_throughput_kbps`: what the
    /// link delivered to the plan when it is below its delivered bitrate.
    private func observedThroughputKbps(of plan: Plan) -> Int? {
        guard let delivered = plan.deliveredKbps, let measured = linkThroughputKbps() ?? measuredThroughputKbps(),
              measured < delivered else { return nil }
        return measured
    }

    /// No lower rung: the display-only notice, once per title.
    private func cantLower() {
        current?.action = .cantLower
        guard !noLowerRungNoticeShown else { return }
        noLowerRungNoticeShown = true
        notify(.cantLower)
    }

    /// The spec's lower rung: the highest real rung below the lower of the
    /// named rung's bitrate and the delivered bitrate, or below the delivered
    /// bitrate when the plan names no rung or one that matches no entry.
    /// Equal bitrates resolve to the earlier entry, as on web.
    nonisolated static func lowerRung(in plan: Plan) -> QualityRung? {
        guard let ceiling = activeBitrate(of: plan) else { return nil }
        return plan.availableQualities
            .filter { $0.label != autoQuality && $0.bitrateKbps > 0 && $0.bitrateKbps < ceiling }
            .max { $0.bitrateKbps < $1.bitrateKbps }
    }

    /// `floor(delivered × 7 / 10)` in integer arithmetic, or nil below
    /// `MIN_ESTIMATE_KBPS`. Multiplying by the Double 0.7 would floor 22120 to
    /// 15483 instead of the spec's 15484.
    nonisolated static func stepDownEstimate(deliveredKbps: Int?) -> Int? {
        guard let deliveredKbps, deliveredKbps > 0 else { return nil }
        let estimate = deliveredKbps * 7 / 10
        return estimate >= minEstimateKbps ? estimate : nil
    }

    private nonisolated static func activeBitrate(of plan: Plan) -> Int? {
        guard let named = plan.activeQuality,
              let rung = plan.availableQualities.first(where: { $0.label == named && $0.bitrateKbps > 0 }) else {
            return plan.deliveredKbps
        }
        // A cap that keeps the rung's resolution can deliver below its bitrate.
        return min(rung.bitrateKbps, plan.deliveredKbps ?? rung.bitrateKbps)
    }

    // MARK: - Replans

    /// Sends the replan for `action`, which becomes the plan's
    /// `buffering_action`.
    private func sendReplan(
        _ action: Action,
        qualityPreference: String,
        estimateKbps: Int? = nil,
        learnedLimit: String? = nil,
        fromKbps: Int? = nil,
        observedThroughputKbps: Int? = nil
    ) {
        let now = nowMs
        current?.action = action
        var request = ReplanRequest(qualityPreference: qualityPreference, bandwidthEstimateKbps: estimateKbps)
        if sendsBufferingQualityFields {
            request.bandwidthEstimateSource = estimateKbps == nil ? nil : PlaybackProtocolV3.BandwidthEstimateSource.observedRebuffer
            request.learnedLimit = learnedLimit
            request.observedThroughputKbps = observedThroughputKbps
        }
        // Only an Auto lowering sends an estimate; the next one replaces it.
        let priorKept = keptEstimateKbps
        if let estimateKbps { keptEstimateKbps = estimateKbps }
        // A Restore's plan settles nothing.
        pendingReplan = action == .restored ? nil : PendingReplan(
            automatic: action == .lowered, fromKbps: fromKbps, priorKeptEstimateKbps: priorKept
        )
        // Triggers on this plan wait for the adoption, or for the rearm if the
        // replan fails or its plan never arrives.
        suppressionTimer?.cancel()
        suppressionTimer = nil
        rearmTimer?.cancel()
        rearmTimer = schedule(at: now + Self.rearmAfterUnadoptedMs) { $0.rearm() }
        emit(.replan(request))
    }

    private func rearm() {
        rearmTimer = nil
        pendingReplan = nil
        clearHistory(at: nowMs)
    }

    private func settle(_ pending: PendingReplan, at now: Int) {
        guard let plan = current?.plan else { return }
        let lower: Bool
        if plan.qualityReductionUnavailable {
            lower = false
        } else if let from = pending.fromKbps {
            // A result with no delivered bitrate counts as lower, as the
            // vectors' `delivered_kbps: 0` encodes it.
            lower = (plan.deliveredKbps ?? 0) < from
        } else {
            return
        }
        // The viewer's pending pick replaces this plan, so its result shows
        // nothing; its action and cooldown still stand.
        if lower {
            guard !pickPending else { return }
            if pending.automatic { present(.undo) } else { notify(.lowered) }
        } else {
            current?.cooldownUntil = now + Self.noLowerCooldownMs
            guard !isSuspended else { return }
            current?.action = .cantLower
            guard !pickPending else { return }
            // The viewer has now seen this copy for the title.
            noLowerRungNoticeShown = true
            notify(.cantLower)
        }
    }

    // MARK: - Stall tracker

    private func beginStall(at now: Int) {
        guard var state = current else { return }
        state.stallEndedByReload = false
        // The plan's first wait, when it comes before a frame, starts the grace.
        let graceEnd = state.graceEndsAt ?? now + Self.startupGraceMs
        state.graceEndsAt = graceEnd
        var stall = Stall()
        if !transportTrouble {
            // A stall that begins in the grace counts from its end.
            let from = max(now, graceEnd)
            stall.timedFrom = from
            stall.measuredFrom = from
        }
        state.stall = stall
        current = state
        scheduleLongStallTimer()
    }

    /// Ends a stall in progress. Only one that playback `resumed` from, outside
    /// transport trouble, can be a counted stall; its time feeds the summary
    /// either way. One that a source reload ended `byReload` counts in the
    /// summary as one still in progress at the plan's end would, if the plan
    /// ends before it runs again: the swap to the plan that replaces it,
    /// such as the lowering that stall triggered.
    private func endStall(at now: Int, resumed: Bool, byReload: Bool = false) {
        guard var state = current, let stall = state.stall else { return }
        state.stall = nil
        state.recordStall(measuredMs: stall.measured(at: now))
        if let from = stall.timedFrom, !transportTrouble, now - from >= Self.stallMinMs {
            if resumed {
                state.endedStalls.append(EndedStall(at: now, long: now - from >= Self.longStallMs))
                state.stallCount += 1
            } else if byReload {
                state.stallEndedByReload = true
            }
        }
        current = state
        cancelStallTimers()
    }

    /// Prompt timeout, rearm, or a quality change: history clears with startup
    /// grace already over, and a stall in progress is timed again from now.
    private func clearHistory(at now: Int) {
        guard current != nil else { return }
        current?.endedStalls.removeAll()
        current?.graceEndsAt = now
        if current?.stall?.timedFrom != nil { current?.stall?.timedFrom = now }
        suppressionTimer?.cancel()
        suppressionTimer = nil
        scheduleLongStallTimer()
    }

    private func scheduleLongStallTimer() {
        longStallTimer?.cancel()
        longStallTimer = nil
        guard let from = current?.stall?.timedFrom else { return }
        longStallTimer = schedule(at: from + Self.longStallMs) { controller in
            controller.longStallTimer = nil
            controller.longStallTimerFired()
        }
    }

    private func longStallTimerFired() {
        guard let from = current?.stall?.timedFrom else { return }
        // A timer can fire a little early against the clock; wait out the
        // rest rather than miss the threshold.
        guard nowMs - from >= Self.longStallMs else {
            scheduleLongStallTimer()
            return
        }
        evaluate(at: nowMs)
    }

    private func cancelStallTimers() {
        longStallTimer?.cancel()
        longStallTimer = nil
        suppressionTimer?.cancel()
        suppressionTimer = nil
    }

    private func leavePlaying(at now: Int) {
        guard let since = playingSince else { return }
        current?.playedMs += now - since
        playingSince = nil
    }

    /// Closes the playing plan's books, takes down its pill and timers, and
    /// emits its summary.
    private func endPlan(at now: Int) {
        guard let state = current else { return }
        let summary = summary(closing: state, at: now)
        current = nil
        cancelStallTimers()
        rearmTimer?.cancel()
        rearmTimer = nil
        withdrawPill()
        emit(.planSummary(summary))
    }

    /// `state`'s books closed at `now`.
    private func summary(closing state: PlanState, at now: Int) -> PlanSummary {
        var state = state
        if let since = playingSince {
            state.playedMs += now - since
        }
        if let stall = state.stall {
            // A stall still running when its plan ends ends with it, and it
            // counts if it reached STALL_MIN_MS outside trouble.
            state.recordStall(measuredMs: stall.measured(at: now))
            if !transportTrouble, let from = stall.timedFrom, now - from >= Self.stallMinMs {
                state.stallCount += 1
            }
        } else if state.stallEndedByReload {
            state.stallCount += 1
        }
        return PlanSummary(
            planId: state.plan.id,
            playedMs: state.playedMs,
            stallCount: state.stallCount,
            stallTotalMs: state.stallTotalMs,
            stallLongestMs: state.stallLongestMs,
            deliveredKbps: state.plan.deliveredKbps,
            mode: mode,
            action: state.action,
            bandwidthEstimateKbps: state.plan.requestedBandwidthEstimateKbps
        )
    }

    // MARK: - Pill

    private func present(_ kind: PillKind) {
        guard !isSuspended else { return }
        presented = PresentedPill(kind: kind, remainingMs: Self.promptMs)
        refreshPill()
    }

    private func withdrawPill() {
        presented = nil
        refreshPill()
    }

    /// Shows, hides, runs or freezes the pill to match the player. Its timer
    /// runs only while it is on screen and playback is not paused. It counts
    /// as shown each time it reaches the screen, and the prompt as offered the
    /// first time.
    private func refreshPill() {
        guard var shown = presented else {
            pillTimer?.cancel()
            pillTimer = nil
            if pill != nil { pill = nil }
            return
        }
        let now = nowMs
        let visible = !competingPillVisible
        let running = visible && !isPaused
        if !running, let deadline = shown.deadlineMs {
            shown.remainingMs = max(0, deadline - now)
            shown.deadlineMs = nil
            pillTimer?.cancel()
            pillTimer = nil
        } else if running, shown.deadlineMs == nil {
            let deadline = now + shown.remainingMs
            shown.deadlineMs = deadline
            pillTimer = schedule(at: deadline) { $0.pillExpired() }
        }
        let appearing = visible && !shown.isOnScreen
        if appearing, shown.firstShownAt == nil { shown.firstShownAt = now }
        shown.isOnScreen = visible
        presented = shown
        let next = visible ? Pill(
            kind: shown.kind,
            deadline: shown.deadlineMs.map(date),
            remaining: TimeInterval(shown.remainingMs) / 1000,
            total: Self.promptSeconds
        ) : nil
        if pill != next { pill = next }
        if appearing { emit(.pillShown(shown.kind)) }
    }

    /// The prompt's timeout leaves the title unanswered, clears history and
    /// starts the re-offer wait; the undo's only hides it, the lower plan
    /// playing on.
    private func pillExpired() {
        pillTimer = nil
        guard let expired = presented else { return }
        withdrawPill()
        switch expired.kind {
        case .prompt:
            current?.action = .timedOut
            // The re-offer wait counts from the prompt's first display.
            lastOfferAt = expired.firstShownAt
            clearHistory(at: nowMs)
        case .undo:
            evaluateLongStall()
        }
    }

    // MARK: - Helpers

    private var nowMs: Int { clock.elapsedMs }

    /// The wall-clock date of `ms` on the elapsed clock, for drawing a pill's
    /// progress against the display's own date.
    private func date(_ ms: Int) -> Date {
        clock.now.addingTimeInterval(TimeInterval(ms - nowMs) / 1000)
    }

    private func schedule(
        at deadline: Int,
        _ action: @escaping @MainActor (BufferingQualityController) -> Void
    ) -> PlayerPromptTimer {
        clock.schedule(after: TimeInterval(max(0, deadline - nowMs)) / 1000) { [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    private func notify(_ notice: Notice) {
        guard !isSuspended else { return }
        emit(.notice(notice))
    }

    private func emit(_ output: Output) {
        onOutput?(output)
    }

    // MARK: - Internal types

    private struct PlanState {
        var plan: Plan
        var action: Action = .none

        /// When startup grace ends: `STARTUP_GRACE_MS` after the plan's first
        /// wait or, when none came before it, its first frame. A history clear
        /// ends it then.
        var graceEndsAt: Int?
        var stall: Stall?
        var endedStalls: [EndedStall] = []

        var cooldownUntil: Int?
        /// Replaced a plan after the attempt had played and has not played
        /// itself: its loading is a source reload, so a wait begins no stall.
        var reloading = false

        var playedMs = 0
        var stallCount = 0
        /// A source reload ended a stall that had reached `STALL_MIN_MS`, and
        /// the plan has not run since.
        var stallEndedByReload = false
        var stallTotalMs = 0
        var stallLongestMs = 0

        mutating func recordStall(measuredMs: Int) {
            guard measuredMs > 0 else { return }
            stallTotalMs += measuredMs
            stallLongestMs = max(stallLongestMs, measuredMs)
        }
    }

    private struct Stall {
        /// Where the trigger times this stall from; nil during transport
        /// trouble. Ahead of now while startup grace runs.
        var timedFrom: Int?
        /// The summary's timing, which a history clear does not re-time:
        /// the start of the current segment outside grace and trouble.
        var measuredFrom: Int?

        func measured(at now: Int) -> Int {
            measuredFrom.map { max(0, now - $0) } ?? 0
        }
    }

    private struct EndedStall {
        let at: Int
        let long: Bool
    }

    private enum AttemptStage {
        case new
        /// A plan was adopted and none has played yet.
        case adopted
        case played
    }

    private struct PendingReplan {
        /// `always` on Auto, whose lower result shows the undo pill; otherwise
        /// **Lower quality** on the prompt, whose lower result is a notice.
        let automatic: Bool
        /// The delivered bitrate the replan left; a lower result is below it.
        let fromKbps: Int?
        /// The kept estimate before this replan, for one the player refuses.
        /// A new attempt discards it with the kept estimate.
        var priorKeptEstimateKbps: Int?
    }

    private struct PresentedPill {
        let kind: PillKind
        /// Left as of the last arm or freeze.
        var remainingMs: Int
        /// Set while the timer runs.
        var deadlineMs: Int?
        /// When it first reached the screen.
        var firstShownAt: Int?
        var isOnScreen = false
    }
}
