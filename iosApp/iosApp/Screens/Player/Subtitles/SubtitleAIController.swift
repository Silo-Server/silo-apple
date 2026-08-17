//
//  SubtitleAIController.swift
//  Silo (iOS + tvOS)
//
//  Per-session orchestrator for the in-player AI subtitle suite — translate
//  an existing text track, transcribe audio (Whisper), or transcribe-and-
//  translate. Owned by ``PlayerViewModel`` and constructed/reset alongside
//  the playback session lifecycle.
//
//  Milestone 3 ships the complete feature over **polling**, the same contract
//  the Android client uses:
//    POST /subtitles/ai/translate  →  store the job  →  poll
//    GET  /subtitles/ai/jobs/{id}   until terminal    →  on `completed`,
//    fetch GET /subtitles/{media_file_id}, locate the result subtitle, and
//    register it as a normal downloaded sidecar track (then auto-select it).
//
//  Milestone 4 (now) layers REAL-TIME cue streaming over the websocket on top
//  of that polling authority. The POST now passes `session_id` (the active
//  playback session) so the server streams cues live; a ``LiveSubtitleCoordinator``
//  drives the started→pause→synthetic-track→resume→handoff→fail experience
//  while the poller keeps running underneath as the source of truth for
//  `result_subtitle_id`. The websocket and the poller SHARE ONE terminal
//  action — the persisted-track handoff — guarded by `handoffJobId` so the
//  track is registered exactly once regardless of which path wins. When the
//  socket is unavailable (`PlaybackRealtimeClient.isRealtimeUnavailable`) the
//  controller behaves exactly like M3: poll, no live cues.
//
//  Isolation: `@MainActor @Observable` so the UI binds its state directly and
//  all mutations stay on main. The networking lives behind the ``SiloAI``
//  actor and the ``AIJobPoller`` actor, which hop back to main when delivering
//  snapshots.
//

import Foundation
import OSLog

/// Drives a single AI subtitle job from submission to completion and owns
/// the user-visible state the translate menu binds to.
@MainActor
@Observable
final class SubtitleAIController {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "SubtitleAI"
    )

    /// Where the controller is in the job lifecycle. The menu maps this to
    /// its in-progress / cancel / error affordances.
    enum Phase: Equatable {
        /// No job in flight.
        case idle
        /// POST sent, waiting for the server to return the job.
        case submitting
        /// Job accepted and polling; `activeJob.progress` drives the bar.
        case running
        /// Job reached `completed` and the result handed off to the player.
        case completed
        /// Job `failed` / `cancelled`, the POST threw, or the handoff failed.
        /// `errorMessage` carries the reason.
        case failed
    }

    // MARK: - Observable state (menu binds to these)

    /// Current ASR quota, refreshed when the menu opens and after an ASR job
    /// completes. Nil until first fetched.
    private(set) var quota: SubtitleAIQuota?

    /// The job currently being polled, or the last terminal job. Nil before
    /// the first submission and after `reset()`.
    private(set) var activeJob: SubtitleJob?

    /// Coarse lifecycle phase for the UI.
    private(set) var phase: Phase = .idle

    /// Human-readable failure reason when `phase == .failed`.
    private(set) var errorMessage: String?

    /// True while the AI subtitle job owns the player-surface preparing/live
    /// presentation. This starts immediately on submit so the menu can hand off
    /// to the same pause/notice flow on iOS and tvOS; later websocket events
    /// attach the synthetic live track and cues to that presentation.
    private(set) var livePresentationActive = false

    /// Whether a job is in flight (submitting or polling). The menu disables
    /// re-submission and shows progress/cancel while this is true.
    var isBusy: Bool {
        phase == .submitting || phase == .running
    }

    // MARK: - Injected collaborators

    /// AI endpoints facade.
    private let api: SiloAI

    /// Job poller (authority for `result_subtitle_id`).
    private let poller: AIJobPoller

    /// Capability/quota cache, refreshed after ASR completes.
    private let capabilities: AICapabilities

    /// Accessors the controller reads at submit time. Injected as closures so
    /// the controller stays decoupled from `PlayerViewModel`'s private state
    /// and is unit-testable.
    private let mediaFileIdProvider: @MainActor () -> Int?
    private let currentTimeProvider: @MainActor () -> Double

    /// The active playback session id. M4 passes this in the translate POST so
    /// the server streams cues live over the playback control websocket. Nil
    /// when no session is bound (then the POST omits `session_id` and the job
    /// runs poll-only, exactly like M3).
    private let sessionIdProvider: @MainActor () -> String?

    /// Whether the realtime websocket is currently unavailable (circuit broken
    /// / never connected). When true the controller does not arm the live
    /// coordinator and relies purely on the poller.
    private let realtimeUnavailableProvider: @MainActor () -> Bool

    /// The live cue state machine. Driven by the 5 websocket events the VM
    /// forwards (and, on the shared terminal action, by the poller). Optional
    /// so unit tests that only exercise the M3 polling path can omit it.
    private let liveCoordinator: LiveSubtitleCoordinator?

    /// The job id whose persisted-track handoff has been (or is being)
    /// performed. The websocket-`completed` path and the poller-terminal path
    /// both route through `completePersistedHandoff` and check this latch, so
    /// the track is registered exactly once even when both fire. Cleared on a
    /// new submission and on `reset()`.
    private var handoffJobId: String?

    /// The `result_subtitle_id` of the OWNED job whose persisted-track handoff
    /// this controller just registered (set the moment the owned handoff lands
    /// its descriptor, on either the websocket or the poller path). The
    /// websocket `completed` path registers the track WITHOUT writing
    /// `activeJob.resultSubtitleId`, so the back-to-back `subtitle_ready`
    /// broadcast for the SAME id wouldn't be recognized by the
    /// `activeJob.resultSubtitleId` guard alone — `handleSubtitleReady`
    /// short-circuits on this id too, avoiding a redundant second listing fetch
    /// + register. Cleared on a new submission and on `reset()`.
    private var ownedHandoffSubtitleId: Int?

    /// Context the controller needs to synthesize a completed subtitle's
    /// player descriptor (the server's listing carries no URL/index). Fetched
    /// lazily at handoff time so it always reflects the live session +
    /// current track list. Nil when no session is active (then the handoff is
    /// reported as a soft failure rather than silently dropped).
    ///
    /// `sessionId` scopes the stream mount, `baseTrackCount` is the combined
    /// ordinal the first downloaded track occupies (the count of non-downloaded
    /// entries in the plan's authoritative subtitle inventory), and
    /// `resolveURL` turns the synthesized API-relative path into an absolute
    /// URL against the active server base.
    struct HandoffContext {
        let sessionId: String
        let baseTrackCount: Int
        let resolveURL: (String) -> URL?
    }
    private let handoffContextProvider: @MainActor () -> HandoffContext?

    /// Completion handoff: hand the synthesized descriptor to the VM, which
    /// registers it through the existing sidecar path and auto-selects the
    /// resulting track. Kept as a closure so this controller never imports the
    /// player backends.
    private let registerAndSelectDescriptor: @MainActor (SidecarSubtitleDescriptor) -> Void

    /// Register a synthesized descriptor in the picker WITHOUT selecting it.
    /// Used for the `subtitle_ready` broadcast (M5): a translation finished
    /// elsewhere (or on another device) should become selectable, but must not
    /// hijack the current viewer's subtitle choice. Defaults to the selecting
    /// closure when not injected (older call sites / tests).
    private let registerDescriptorWithoutSelecting: @MainActor (SidecarSubtitleDescriptor) -> Void

    /// The in-flight Task draining the poller stream. Cancelled on a new
    /// submission, on `cancelActiveJob()`, and on `reset()`.
    private var pollDrainTask: Task<Void, Never>?

    // MARK: - Early-frame buffer (M5)
    //
    // The server dispatches the translate job on a background goroutine and can
    // emit `subtitle_translation_started`/`_cues` over the websocket BEFORE the
    // HTTP 202 returns the job id — i.e. before `activeJob` (and thus the
    // `track_key` we match on) is known. On a fast LAN those early frames would
    // otherwise be dropped in `handle(_:)`, and the live cue experience could
    // fail to engage on the very first job. To avoid that we stash the racing
    // `started`/`cues`/`completed`/`failed` frames ONLY while a submit is in
    // flight (`phase == .submitting`), capped, then replay the ones whose
    // `track_key` matches the landed job once the 202 sets `activeJob`.

    /// Frames received during the in-flight submit window, awaiting the 202.
    /// Bounded by `Self.earlyFrameBufferCap`; oldest dropped on overflow.
    private var earlyFrameBuffer: [PlaybackRealtimeSubtitleEvent] = []

    /// Hard cap on buffered early frames. A `started` plus a few opening cue
    /// batches is all that can realistically beat the 202 on a fast LAN; the
    /// cap bounds memory if the server ever streams ahead unexpectedly. Old
    /// frames are dropped first so the freshest cues survive.
    private static let earlyFrameBufferCap = 32

    /// Drop any buffered early frames and stop buffering. Called once the
    /// buffered frames have been replayed (or discarded) and on submit-failure
    /// / reset so a later job never inherits this one's racing frames.
    private func clearEarlyFrameBuffer() {
        earlyFrameBuffer.removeAll(keepingCapacity: false)
    }

    /// Bumped on every `reset()`. Each async step that mutates observable
    /// state after an `await` (poll drain, completion handoff, quota refresh)
    /// captures this before its awaits and discards results when it no longer
    /// matches — so a stale completion from a previous account/session can't
    /// register after a reset. Mirrors ``AICapabilities``'s `generation`.
    private var generation = 0

    /// `@MainActor`-isolated (the type default). The owning ``PlayerViewModel``
    /// is a Swift-5-mode type that isn't globally `@MainActor`, so it builds
    /// this controller inside a `MainActor.assumeIsolated` block in its lazy
    /// `subtitleAI` initializer — `subtitleAI` is documented to be accessed
    /// only on the main actor (player UI, job commands, `cleanup()`). Isolating
    /// the init (rather than marking it `nonisolated` and assigning to
    /// main-actor `let`s from a nonisolated context) is what keeps the
    /// Swift-6 actor-isolation warnings off this initializer.
    init(
        api: SiloAI = .shared,
        poller: AIJobPoller = AIJobPoller(),
        // `nil` default rather than `.shared`: the shared capabilities holder is
        // `@MainActor`-isolated, and default arguments evaluate in a nonisolated
        // context, so it is resolved inside this (main-actor) init body instead.
        capabilities: AICapabilities? = nil,
        mediaFileId: @escaping @MainActor () -> Int?,
        currentTime: @escaping @MainActor () -> Double,
        sessionId: @escaping @MainActor () -> String? = { nil },
        realtimeUnavailable: @escaping @MainActor () -> Bool = { true },
        liveCoordinator: LiveSubtitleCoordinator? = nil,
        handoffContext: @escaping @MainActor () -> HandoffContext?,
        registerAndSelectDescriptor: @escaping @MainActor (SidecarSubtitleDescriptor) -> Void,
        // M5: register-only (no auto-select) for the `subtitle_ready` broadcast.
        // Falls back to the selecting closure when omitted.
        registerDescriptorWithoutSelecting: (@MainActor (SidecarSubtitleDescriptor) -> Void)? = nil,
        // Test seam for the handoff listing fetch. Nil in production → the call
        // site uses `api.downloadedSubtitles`. Injected by unit tests so the
        // poller-vs-websocket handoff race can be exercised without the network.
        downloadedSubtitlesFetch: (@Sendable (Int) async throws -> [DownloadedSubtitle])? = nil
    ) {
        self.api = api
        self.poller = poller
        self.capabilities = capabilities ?? .shared
        self.mediaFileIdProvider = mediaFileId
        self.currentTimeProvider = currentTime
        self.sessionIdProvider = sessionId
        self.realtimeUnavailableProvider = realtimeUnavailable
        self.liveCoordinator = liveCoordinator
        self.handoffContextProvider = handoffContext
        self.registerAndSelectDescriptor = registerAndSelectDescriptor
        self.registerDescriptorWithoutSelecting = registerDescriptorWithoutSelecting ?? registerAndSelectDescriptor
        self.downloadedSubtitlesFetch = downloadedSubtitlesFetch
    }

    /// See the `downloadedSubtitlesFetch` init parameter.
    private let downloadedSubtitlesFetch: (@Sendable (Int) async throws -> [DownloadedSubtitle])?

    /// The `track_key` the server uses for `jobId`'s live stream
    /// (`"ai-<jobID>"`). Used to scope forwarded websocket events to the
    /// active job and to address the coordinator's synthetic track.
    static func trackKey(for jobId: String) -> String { "ai-\(jobId)" }

    // MARK: - Quota

    /// Refresh the ASR quota (used by the menu on open). Tolerant of failure.
    func refreshQuota() async {
        let gen = generation
        await capabilities.refreshQuota()
        guard gen == generation else { return }
        quota = capabilities.subtitleQuota
    }

    // MARK: - Commands

    /// The server's **combined** subtitle index to translate `track` with, or
    /// `nil` when the track carries no combined index and therefore can't be
    /// used as a translation source.
    ///
    /// `PlayerTrack.srcId` is overloaded across the track partitions, so it is
    /// only a combined index for one of them:
    ///   - **sidecar** (`SubtitleTrackIdSpace.sidecarBase`): `srcId` *is* the
    ///     combined index (`subtitle_urls[].index`) — pass it through.
    ///   - **embedded** (`avPlayerEmbeddedBase`): `srcId` is the FFmpeg stream
    ///     index, a different index space entirely. Translating it to the
    ///     combined index needs the version's subtitle inventory (see
    ///     ``ApplePlaybackV3PlanAdapter/serverCombinedSubtitleIndex(ffmpegStreamIndex:in:)``),
    ///     which this controller is not given, so embedded tracks are refused
    ///     rather than silently sending a wrong index.
    ///   - **AI-live** and AVFoundation rows carry no `srcId` at all.
    nonisolated static func translationSourceIndex(for track: PlayerTrack) -> Int? {
        guard SubtitleTrackIdSpace.isSidecar(track.trackId) else { return nil }
        return track.srcId
    }

    /// Translate an existing text subtitle track into `targetLanguage`.
    ///
    /// The wire `source_index` is the server's combined subtitle index, which
    /// only sidecar/downloaded tracks carry (see ``translationSourceIndex(for:)``).
    /// Embedded-text translation is out of scope for v1, so an embedded track
    /// is rejected here as a guard rather than sending its FFmpeg stream index
    /// as though it were a combined index.
    func translateExisting(track: PlayerTrack, to targetLanguage: String) {
        guard let sourceIndex = Self.translationSourceIndex(for: track) else {
            Self.logger.warning(
                "[AI-SUB] refusing to translate track without combined index trackId=\(track.trackId, privacy: .public)"
            )
            fail(with: "This subtitle track can't be translated.")
            return
        }
        submit(
            kind: .translate,
            sourceIndex: sourceIndex,
            sourceLanguage: track.normalizedLanguageCode,
            targetLanguage: targetLanguage
        )
    }

    /// Transcribe an audio track to subtitles, optionally translating the
    /// transcript into `translateTo`.
    ///
    /// `audioIndex` is the audio track index (`-1` = server default). When
    /// `translateTo` is non-nil the job is `transcribe_translate`; otherwise
    /// plain `transcribe`.
    func transcribe(audioIndex: Int, translateTo: String?) {
        let kind: SubtitleAIKind = (translateTo == nil) ? .transcribe : .transcribeTranslate
        submit(
            kind: kind,
            sourceIndex: audioIndex,
            sourceLanguage: nil,
            targetLanguage: translateTo
        )
    }

    /// Cancel the in-flight job (best-effort) and return to idle.
    func cancelActiveJob() {
        let job = activeJob
        guard phase == .submitting || job?.status.isTerminal == false else { return }
        generation &+= 1
        let jobId = job?.id
        pollDrainTask?.cancel()
        pollDrainTask = nil
        // Tear down any live presentation (restores selection / resumes). This
        // also covers a cancel while the initial POST is still in flight, before
        // `activeJob` is known.
        liveCoordinator?.cancelActivePresentation()
        livePresentationActive = false
        handoffJobId = nil
        ownedHandoffSubtitleId = nil
        clearEarlyFrameBuffer()
        Task { [api, poller] in
            await poller.cancel()
            if let jobId {
                try? await api.cancelSubtitleJob(id: jobId)
            }
        }
        phase = .idle
        activeJob = nil
        errorMessage = nil
    }

    /// Tear down on session end / controller replacement. Stops polling and
    /// clears state so a later session never inherits this one's job. Bumps
    /// `generation` first so any in-flight poll/handoff/quota that finishes
    /// after this reset discards its results instead of landing on the next
    /// account's player.
    func reset() {
        generation &+= 1
        pollDrainTask?.cancel()
        pollDrainTask = nil
        let poller = self.poller
        Task { await poller.cancel() }
        liveCoordinator?.teardown()
        livePresentationActive = false
        handoffJobId = nil
        ownedHandoffSubtitleId = nil
        clearEarlyFrameBuffer()
        activeJob = nil
        phase = .idle
        errorMessage = nil
        quota = nil
    }

    // MARK: - Submit + poll

    private func submit(
        kind: SubtitleAIKind,
        sourceIndex: Int,
        sourceLanguage: String?,
        targetLanguage: String?
    ) {
        guard let mediaFileId = mediaFileIdProvider() else {
            fail(with: "Playback isn't ready yet.")
            return
        }
        generation &+= 1
        let gen = generation
        // Replace any prior in-flight job.
        pollDrainTask?.cancel()
        pollDrainTask = nil
        // Tear down any prior live job before starting a new one, and clear the
        // shared handoff latch so the new job's terminal action can run.
        liveCoordinator?.teardown()
        livePresentationActive = false
        handoffJobId = nil
        ownedHandoffSubtitleId = nil
        // Discard any frames left buffered from a previous submit window before
        // opening this one (so a superseded job's racing cues can't replay into
        // the new job).
        clearEarlyFrameBuffer()

        phase = .submitting
        errorMessage = nil
        activeJob = nil
        liveCoordinator?.beginPreparing()
        refreshLivePresentationState()

        // M4: pass `session_id` so the server streams cues live over the
        // playback control websocket — UNLESS realtime is not live-ready, in
        // which case we omit it and behave exactly like M3 (poll, no live
        // cues). The poller runs regardless and remains the completion
        // authority.
        let liveSessionId = realtimeUnavailableProvider() ? nil : sessionIdProvider()
        let body = TranslateSubtitleBody(
            mediaFileId: mediaFileId,
            kind: kind,
            sourceIndex: sourceIndex,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sessionId: liveSessionId,
            startPosition: currentTimeProvider()
        )

        Self.logger.info(
            "[AI-SUB] submit kind=\(kind.rawValue, privacy: .public) mediaFileId=\(mediaFileId, privacy: .public) sourceIndex=\(sourceIndex, privacy: .public) target=\(targetLanguage ?? "nil", privacy: .public)"
        )

        pollDrainTask = Task { [weak self] in
            guard let self else { return }
            do {
                let job = try await self.api.translateSubtitle(body)
                // A reset (sign-out / profile or session switch) while the POST
                // was in flight invalidates this submission.
                guard gen == self.generation else { return }
                self.onJobAccepted(job)
                await self.drainPoll(jobId: job.id, isASR: kind != .translate, generation: gen)
            } catch {
                if Task.isCancelled { return }
                guard gen == self.generation else { return }
                self.fail(with: Self.message(for: error))
            }
        }
    }

    private func onJobAccepted(_ job: SubtitleJob) {
        activeJob = job
        if job.status.isTerminal {
            // A job that's already terminal at accept time never streams live;
            // its buffered frames (if any) are irrelevant — discard them.
            clearEarlyFrameBuffer()
            handleTerminal(job, isASR: job.kind != .translate, generation: generation)
        } else {
            phase = .running
            // M5 — replay the early frames that beat the 202. Only the frames
            // for THIS job's `track_key` (in arrival order); anything else
            // buffered (a stale racing job) is discarded with the buffer.
            replayEarlyFrames(for: job)
        }
    }

    /// Replay buffered early frames whose `track_key` matches the now-landed
    /// `job`, in arrival order, through the normal coordinator path — so a
    /// `started`/`cues` pair that beat the 202 still engages the live cue
    /// experience. Frames for any other key are dropped. The buffer is cleared
    /// afterwards (the in-flight window is over; subsequent frames route live).
    private func replayEarlyFrames(for job: SubtitleJob) {
        guard !earlyFrameBuffer.isEmpty else { return }
        let trackKey = Self.trackKey(for: job.id)
        let matching = earlyFrameBuffer.filter { $0.trackKey == trackKey }
        clearEarlyFrameBuffer()
        guard !matching.isEmpty else { return }
        Self.logger.info("[AI-LIVE] replaying \(matching.count, privacy: .public) buffered early frame(s) for trackKey=\(trackKey, privacy: .public)")
        for event in matching {
            liveCoordinator?.handle(event)
        }
        refreshLivePresentationState()
    }

    // MARK: - Test seams
    //
    // These mirror the two ways a job's `activeJob` is set + completed in
    // production (the 202 accept and a poller-terminal snapshot) WITHOUT the
    // network, so `SubtitleAIControllerTests` can exercise the poller-vs-
    // websocket completion race headless. They are not called in production
    // (the real paths run through `submit`/`drainPoll`); kept internal so
    // `@testable import` reaches them.

    /// Enter the in-flight submit window (`phase == .submitting`, no
    /// `activeJob`) without the network, so `SubtitleAIControllerTests` can
    /// exercise the M5 early-frame buffer: frames delivered after this and
    /// before `seedAcceptedJobForTesting` are buffered and then replayed.
    /// Test-only.
    func beginSubmitWindowForTesting() {
        pollDrainTask?.cancel()
        pollDrainTask = nil
        liveCoordinator?.teardown()
        livePresentationActive = false
        generation &+= 1
        handoffJobId = nil
        ownedHandoffSubtitleId = nil
        clearEarlyFrameBuffer()
        phase = .submitting
        errorMessage = nil
        activeJob = nil
        liveCoordinator?.beginPreparing()
        refreshLivePresentationState()
    }

    /// Seed `activeJob` as if the 202 accept landed (non-terminal), without
    /// hitting the network. Test-only.
    func seedAcceptedJobForTesting(_ job: SubtitleJob) {
        onJobAccepted(job)
    }

    /// The number of frames currently buffered in the in-flight window
    /// (test-only assertion hook for the early-frame buffer).
    var bufferedEarlyFrameCountForTesting: Int { earlyFrameBuffer.count }

    /// Drive a poller-terminal snapshot through the real terminal handler,
    /// exactly as `drainPoll` would on a terminal poll. Test-only.
    func deliverPollerTerminalForTesting(_ job: SubtitleJob) {
        activeJob = job
        handleTerminal(job, isASR: job.kind != .translate, generation: generation)
    }

    /// Drain the poller stream, updating `activeJob` per snapshot and acting
    /// on the terminal snapshot. `generation` is the value captured at submit
    /// time; a reset mid-poll invalidates the remaining snapshots.
    private func drainPoll(jobId: String, isASR: Bool, generation gen: Int) async {
        let api = self.api
        let stream = await poller.poll(jobId: jobId) { id in
            try await api.subtitleJob(id: id)
        }
        for await snapshot in stream {
            guard gen == self.generation else { return }
            activeJob = snapshot
            if snapshot.status.isTerminal {
                handleTerminal(snapshot, isASR: isASR, generation: gen)
                break
            } else {
                phase = .running
            }
        }
    }

    private func handleTerminal(_ job: SubtitleJob, isASR: Bool, generation gen: Int) {
        switch job.status {
        case .completed:
            phase = .completed
            errorMessage = nil
            // Poller-as-authority terminal handoff. Shares the `handoffJobId`
            // latch with the websocket `completed` path so the persisted track
            // is registered exactly once. If the websocket already handed off,
            // this no-ops (and just tells the coordinator the poller authority
            // closed things, in case the socket dropped before `completed`).
            completePersistedHandoff(
                jobId: job.id,
                mediaFileId: job.mediaFileId,
                resultSubtitleId: job.resultSubtitleId,
                generation: gen,
                viaWebsocket: false
            )
        case .failed:
            // Tear the live track down on a poller-observed failure too.
            failHandoff(job.errorMessage ?? "Subtitle translation failed.")
        case .cancelled:
            liveCoordinator?.cancelActivePresentation()
            refreshLivePresentationState()
            phase = .idle
            activeJob = nil
            errorMessage = nil
        case .pending, .running:
            // Not actually terminal — defensive no-op.
            break
        }

        // An ASR job consumes quota; refresh the gauge afterwards regardless
        // of outcome so the menu reflects the new balance. Skip if a reset
        // happened so a stale balance can't repopulate the next account's menu.
        if isASR {
            Task { [weak self] in
                guard let self, gen == self.generation else { return }
                await self.refreshQuota()
            }
        }
    }

    // MARK: - Completion handoff

    /// The single terminal action shared by the poller-authority path and the
    /// live websocket `completed` path: fetch the file's downloaded subtitles,
    /// find the entry whose **`id`** equals `resultSubtitleId`, synthesize its
    /// player descriptor (URL + combined index — the listing carries neither),
    /// and hand it to the VM to register + auto-select via the existing sidecar
    /// path.
    ///
    /// Whichever driver reaches completion first claims the `handoffJobId`
    /// latch and performs the registration; the other call no-ops the
    /// registration (so the track is never double-registered) but, when it is
    /// the poller learning the socket already finished, tells the coordinator
    /// the authority closed out so a dropped socket never leaves a stuck live
    /// track.
    ///
    /// The listing (`GET /subtitles/{media_file_id}`) returns the server's
    /// `DownloadedSubtitle` shape: a DB `id` plus metadata, **no** stream
    /// `url` and **no** combined player index. We synthesize the descriptor
    /// exactly like Android's `SubtitleTrackMerge` (combined index past the
    /// existing external+embedded+downloaded tracks; stream URL on the
    /// session-scoped `/stream/{session}/subtitles/{combined-index}<ext>`
    /// mount, which keys on the combined index — verified server-side).
    ///
    /// `generation` is the value captured at submit time; a reset mid-fetch
    /// invalidates the handoff so a stale completion can't land on the next
    /// account/session.
    /// - Parameter autoSelect: when `true` (a job this client owns) the handed-off
    ///   track is registered AND selected; when `false` (a `subtitle_ready`
    ///   broadcast) it is registered only — it becomes selectable without
    ///   hijacking the viewer's current choice — and a not-found / unresolvable
    ///   result is treated as a silent no-op rather than a user-facing failure.
    private func completePersistedHandoff(
        jobId: String,
        mediaFileId: Int,
        resultSubtitleId: Int?,
        generation gen: Int,
        viaWebsocket: Bool,
        autoSelect: Bool = true
    ) {
        // Latch: only the first driver to reach completion registers the track.
        // The latch is claimed after the downloaded listing and descriptor are
        // ready so a transient listing miss doesn't permanently block the other
        // completion path from retrying the same job.
        guard handoffJobId != jobId else {
            // The other driver already (is) handling it. If this is the poller
            // arriving after the websocket, nothing more to do — the websocket
            // path also closed the live track. If this is the websocket
            // arriving after the poller, let the coordinator close cleanly.
            if !viaWebsocket {
                liveCoordinator?.persistedHandoffAlreadyDone(trackKey: Self.trackKey(for: jobId))
            }
            return
        }

        guard let resultId = resultSubtitleId else {
            Self.logger.warning("[AI-SUB] completed job \(jobId, privacy: .public) has no result_subtitle_id")
            // Without the id we can't synthesize the persisted track. For a job
            // we own, let the coordinator restore the prior selection rather than
            // stranding the synthetic live track selected; for a `ready`
            // broadcast there's nothing to do.
            if autoSelect { failHandoff("Translation finished but the track couldn't be added.") }
            return
        }

        let fetch = self.downloadedSubtitlesFetch
        let api = self.api
        Task { [weak self] in
            guard let self else { return }
            let downloaded: [DownloadedSubtitle]
            if let fetch {
                downloaded = (try? await fetch(mediaFileId)) ?? []
            } else {
                downloaded = (try? await api.downloadedSubtitles(mediaFileId: mediaFileId)) ?? []
            }
            // A reset while the listing was in flight invalidates this handoff.
            guard gen == self.generation else { return }

            // A handoff failure for an owned job surfaces a soft notice +
            // restores selection; for a `ready` broadcast (register-only) it is
            // a silent no-op (nothing was selected, nothing to restore).
            let softFail: (String) -> Void = { [weak self] message in
                if autoSelect { self?.failHandoff(message) }
            }

            // Match by DB id (Android: `it.id == resultSubtitleId`); the
            // matched entry's position in the listing fixes its combined index.
            guard let position = downloaded.firstIndex(where: { $0.id == resultId }) else {
                Self.logger.warning(
                    "[AI-SUB] result subtitle id=\(resultId, privacy: .public) not found among \(downloaded.count, privacy: .public) downloaded subtitles"
                )
                softFail("Translation finished but the track couldn't be added.")
                return
            }

            guard let context = self.handoffContextProvider() else {
                Self.logger.warning("[AI-SUB] no active session/track context for completed subtitle id=\(resultId, privacy: .public)")
                softFail("Translation finished but the track couldn't be added.")
                return
            }

            guard let descriptor = downloaded[position].synthesizedDescriptor(
                sessionId: context.sessionId,
                baseTrackCount: context.baseTrackCount,
                position: position,
                resolveURL: context.resolveURL
            ) else {
                Self.logger.warning("[AI-SUB] could not synthesize stream URL for completed subtitle id=\(resultId, privacy: .public)")
                softFail("Translation finished but the track couldn't be added.")
                return
            }

            guard self.handoffJobId != jobId else {
                if !viaWebsocket {
                    self.liveCoordinator?.persistedHandoffAlreadyDone(trackKey: Self.trackKey(for: jobId))
                    self.refreshLivePresentationState()
                }
                return
            }
            self.handoffJobId = jobId

            Self.logger.info(
                "[AI-SUB] handing off subtitle id=\(resultId, privacy: .public) combinedIndex=\(descriptor.index, privacy: .public) viaWebsocket=\(viaWebsocket, privacy: .public) autoSelect=\(autoSelect, privacy: .public)"
            )
            if autoSelect {
                // Record the OWNED handoff's subtitle id so a back-to-back
                // `subtitle_ready` broadcast for this same id is recognized as a
                // self-handoff and skipped (the websocket `completed` path never
                // writes `activeJob.resultSubtitleId`, so that guard alone misses
                // it). Register-only (`ready`) handoffs don't set this — they
                // aren't this viewer's owned job.
                self.ownedHandoffSubtitleId = resultId
                self.registerAndSelectDescriptor(descriptor)
            } else {
                self.registerDescriptorWithoutSelecting(descriptor)
            }

            // When the POLLER is first to complete (the websocket's
            // `completed` frame was lost — e.g. a transient socket drop with no
            // server replay), the coordinator is still in `.streaming` with the
            // synthetic live row in the picker. Now that the persisted track is
            // registered + selected, tell the coordinator the authority closed
            // out so it closes the live track and reaches `.completed`. The
            // websocket path drives the coordinator itself (`onCompleted`), so
            // only do this on the poller path. Safe if no live job is active
            // (the coordinator guards on `isActive`).
            if !viaWebsocket {
                self.liveCoordinator?.persistedHandoffAlreadyDone(
                    trackKey: Self.trackKey(for: jobId)
                )
                self.refreshLivePresentationState()
            }
        }
    }

    // MARK: - Live websocket events (M4)

    /// Route a decoded subtitle event from the playback websocket. Track-scoped
    /// events (`started`/`cues`/`completed`/`failed`) for the active job drive
    /// the ``LiveSubtitleCoordinator``; `ready` is file-scoped and handled here.
    ///
    /// The completion path is special: the live `completed` event must run the
    /// SAME shared handoff the poller uses, so it is intercepted here and
    /// routed through `completePersistedHandoff` (which the coordinator's
    /// `registerPersisted` sink call also reaches) — the latch keeps it to one
    /// registration.
    func handle(_ event: PlaybackRealtimeSubtitleEvent) {
        switch event {
        case .ready(let ready):
            handleSubtitleReady(ready)
            return
        case .started, .cues, .completed, .failed:
            break
        }

        // Scope track-keyed events to the active job. A late frame for a job
        // we've already torn down (or never started) is ignored.
        guard let trackKey = event.trackKey else { return }

        // M5 — early-frame buffering: while a submit is in flight the 202 hasn't
        // set `activeJob` yet, so we can't know the job's `track_key`. Stash the
        // racing frame (bounded) instead of dropping it; `onJobAccepted` replays
        // the ones that match the landed job. Only buffer during this in-flight
        // window — once `activeJob` is set, the match below handles routing and
        // a stale-key frame is correctly ignored.
        if activeJob == nil, phase == .submitting {
            earlyFrameBuffer.append(event)
            if earlyFrameBuffer.count > Self.earlyFrameBufferCap {
                earlyFrameBuffer.removeFirst(earlyFrameBuffer.count - Self.earlyFrameBufferCap)
            }
            Self.logger.debug("[AI-LIVE] buffering early frame trackKey=\(trackKey, privacy: .public) buffered=\(self.earlyFrameBuffer.count, privacy: .public)")
            return
        }

        guard let job = activeJob, Self.trackKey(for: job.id) == trackKey else {
            Self.logger.debug("[AI-LIVE] ignoring event for stale/unknown trackKey=\(trackKey, privacy: .public)")
            return
        }

        liveCoordinator?.handle(event)
        refreshLivePresentationState()
    }

    /// Handle a file-scoped `subtitle_ready` broadcast (M5).
    ///
    /// The server broadcasts `subtitle_ready` to **any** active session of a
    /// file when a downloaded subtitle becomes available — including a
    /// translation started elsewhere or on another device. If it matches the
    /// CURRENT file and isn't already the active job's result, register the
    /// downloaded track so it becomes selectable in the picker — **without**
    /// auto-selecting it (it isn't this viewer's choice).
    ///
    /// Latch-safe two ways: (1) a `ready` whose id equals the active job's
    /// `resultSubtitleId` is ignored (that job's own completion handoff registers
    /// + selects it), and (2) the per-id `ready-<id>` latch key means a repeated
    /// broadcast registers the track at most once.
    private func handleSubtitleReady(_ ready: PlaybackRealtimeSubtitleEvent.Ready) {
        guard let mediaFileId = mediaFileIdProvider(),
              let fileId = ready.fileId, fileId == mediaFileId,
              let subtitleId = ready.subtitleId else {
            return
        }
        // Don't double-handle the active job's own result — its completion path
        // owns that track's registration + selection. Two checks, because the
        // websocket `completed` path registers the persisted track WITHOUT
        // populating `activeJob.resultSubtitleId`: (1) the poller eventually sets
        // `resultSubtitleId`, and (2) the owned handoff records
        // `ownedHandoffSubtitleId` the moment it registers — so the back-to-back
        // `subtitle_ready` broadcast for the just-completed id is recognized
        // immediately, before the ~1.5s poller snapshot, and skips a redundant
        // downloaded-subtitles fetch + register.
        if let job = activeJob, job.resultSubtitleId == subtitleId { return }
        if ownedHandoffSubtitleId == subtitleId { return }
        Self.logger.info("[AI-LIVE] subtitle_ready broadcast subtitleId=\(subtitleId, privacy: .public) fileId=\(fileId, privacy: .public)")
        // A per-id synthetic latch key so a repeated broadcast registers once
        // and never clashes with a real job's `ai-<jobID>` key. Register-only
        // (`autoSelect: false`): make it selectable, don't hijack the selection.
        completePersistedHandoff(
            jobId: "ready-\(subtitleId)",
            mediaFileId: mediaFileId,
            resultSubtitleId: subtitleId,
            generation: generation,
            viaWebsocket: true,
            autoSelect: false
        )
    }

    /// Bridge for the coordinator's `registerPersisted` sink call: the live
    /// `completed` event tells the coordinator the persisted id, the coordinator
    /// asks its sink to register it, and the sink routes back here so the
    /// SHARED latched handoff runs (never a second registration path).
    func completeLivePersistedHandoff(subtitleId: Int) {
        guard let job = activeJob else { return }
        completePersistedHandoff(
            jobId: job.id,
            mediaFileId: job.mediaFileId,
            resultSubtitleId: subtitleId,
            generation: generation,
            viaWebsocket: true
        )
    }

    /// Called by the VM when the realtime socket's availability flips to
    /// unavailable mid-job. If a live job is in flight, the coordinator gives
    /// up the live presentation and the poller (still running) completes the
    /// handoff.
    func realtimeDidBecomeUnavailable() {
        liveCoordinator?.liveDriverDidGiveUp()
        refreshLivePresentationState()
    }

    // MARK: - Helpers

    private func refreshLivePresentationState() {
        livePresentationActive = liveCoordinator?.isActive ?? false
    }

    private func fail(with message: String) {
        // A submit that fails (incl. the 202 never returning) ends the in-flight
        // window — discard any frames that were buffered waiting for it.
        clearEarlyFrameBuffer()
        liveCoordinator?.liveDriverDidGiveUp(message: message)
        refreshLivePresentationState()
        phase = .failed
        errorMessage = message
    }

    /// Fail a job over BOTH surfaces with the same message. This dual surfacing
    /// is intentional: `liveDriverDidGiveUp` closes/restores the live
    /// presentation and shows the soft notice (covers the dismissed-menu case),
    /// while `fail` sets `errorMessage`/`.failed` for the open translate menu.
    /// Extracted so the message literal lives in one place.
    private func failHandoff(_ message: String) {
        liveCoordinator?.liveDriverDidGiveUp(message: message)
        fail(with: message)
    }

    private static func message(for error: Error) -> String {
        if let http = error as? HTTPError {
            // 503 from the AI endpoints means the feature is configured but the
            // AI service is unreachable right now — give a clearer line than the
            // generic "Server returned status 503". A server-supplied message (if
            // any) still wins via `errorDescription`.
            if http.statusCode == 503, Self.parsedServerMessage(http) == nil {
                return "AI subtitles aren't available right now. Try again later."
            }
            // `HTTPError` is a `LocalizedError` whose `errorDescription` already
            // surfaces the server's parsed error message; fall through to it.
            return http.errorDescription ?? "Couldn't start subtitle translation."
        }
        return "Couldn't start subtitle translation."
    }

    /// True-ish helper: whether the server attached a human message to the
    /// error body (so we prefer it over our generic 503 copy).
    private static func parsedServerMessage(_ http: HTTPError) -> String? {
        guard case .http = http else { return nil }
        // `errorDescription` returns the parsed server message when present,
        // otherwise the "Server returned status N" fallback — detect the latter.
        let description = http.errorDescription ?? ""
        return description.hasPrefix("Server returned status") ? nil : description
    }
}
