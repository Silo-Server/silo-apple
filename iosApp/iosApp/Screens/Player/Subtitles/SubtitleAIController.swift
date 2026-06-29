//
//  SubtitleAIController.swift
//  Continuum (iOS + tvOS)
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
//  all mutations stay on main. The networking lives behind the ``ContinuumAI``
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
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
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

    /// Whether a job is in flight (submitting or polling). The menu disables
    /// re-submission and shows progress/cancel while this is true.
    var isBusy: Bool {
        phase == .submitting || phase == .running
    }

    // MARK: - Injected collaborators

    /// AI endpoints facade.
    private let api: ContinuumAI

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

    /// Context the controller needs to synthesize a completed subtitle's
    /// player descriptor (the server's listing carries no URL/index). Fetched
    /// lazily at handoff time so it always reflects the live session +
    /// current track list. Nil when no session is active (then the handoff is
    /// reported as a soft failure rather than silently dropped).
    ///
    /// Mirrors Android's `SubtitleTrackMerge`: `sessionId` scopes the stream
    /// mount, `baseTrackCount` is `(max(existing non-downloaded index) + 1)`,
    /// and `resolveURL` turns the synthesized API-relative path into an
    /// absolute URL against the active server base.
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

    /// The in-flight Task draining the poller stream. Cancelled on a new
    /// submission, on `cancelActiveJob()`, and on `reset()`.
    private var pollDrainTask: Task<Void, Never>?

    /// Bumped on every `reset()`. Each async step that mutates observable
    /// state after an `await` (poll drain, completion handoff, quota refresh)
    /// captures this before its awaits and discards results when it no longer
    /// matches — so a stale completion from a previous account/session can't
    /// register after a reset. Mirrors ``AICapabilities``'s `generation`.
    private var generation = 0

    /// `nonisolated` so the owning ``PlayerViewModel`` (a Swift-5-mode type
    /// that isn't globally `@MainActor`) can construct this `@MainActor`
    /// controller from its own initializer / lazy property without an
    /// `assumeIsolated` wrapper. The body only stores the injected
    /// collaborators (immutable `let`s) and never touches the `@Observable`
    /// main-actor state, so it is main-safe.
    nonisolated init(
        api: ContinuumAI = .shared,
        poller: AIJobPoller = AIJobPoller(),
        capabilities: AICapabilities = .shared,
        mediaFileId: @escaping @MainActor () -> Int?,
        currentTime: @escaping @MainActor () -> Double,
        sessionId: @escaping @MainActor () -> String? = { nil },
        realtimeUnavailable: @escaping @MainActor () -> Bool = { true },
        liveCoordinator: LiveSubtitleCoordinator? = nil,
        handoffContext: @escaping @MainActor () -> HandoffContext?,
        registerAndSelectDescriptor: @escaping @MainActor (SidecarSubtitleDescriptor) -> Void
    ) {
        self.api = api
        self.poller = poller
        self.capabilities = capabilities
        self.mediaFileIdProvider = mediaFileId
        self.currentTimeProvider = currentTime
        self.sessionIdProvider = sessionId
        self.realtimeUnavailableProvider = realtimeUnavailable
        self.liveCoordinator = liveCoordinator
        self.handoffContextProvider = handoffContext
        self.registerAndSelectDescriptor = registerAndSelectDescriptor
    }

    /// The `track_key` the server uses for `jobId`'s live stream
    /// (`"ai-<jobID>"`). Used to scope forwarded websocket events to the
    /// active job and to address the coordinator's synthetic track.
    static func trackKey(for jobId: String) -> String { "ai-\(jobId)" }

    // MARK: - Quota

    /// Refresh the ASR quota (used by the menu on open). Tolerant of failure.
    func refreshQuota() async {
        await capabilities.refreshQuota()
        quota = capabilities.subtitleQuota
    }

    // MARK: - Commands

    /// Translate an existing text subtitle track into `targetLanguage`.
    ///
    /// `sourceIndex` is the track's combined player subtitle index, which for
    /// sidecar/downloaded tracks is `track.srcId` (equal to
    /// `subtitle_urls[].index`). Embedded-text translation is out of scope for
    /// v1 (the menu only offers "Translate" on tracks with a resolvable
    /// combined index), so a track without a `srcId` is rejected here as a
    /// guard rather than silently sending a wrong index.
    func translateExisting(track: PlayerTrack, to targetLanguage: String) {
        guard let sourceIndex = track.srcId else {
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
        guard let job = activeJob, !job.status.isTerminal else { return }
        let jobId = job.id
        pollDrainTask?.cancel()
        pollDrainTask = nil
        // Tear down any live presentation (restores selection / resumes).
        liveCoordinator?.teardown()
        handoffJobId = nil
        Task { [api, poller] in
            await poller.cancel()
            try? await api.cancelSubtitleJob(id: jobId)
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
        handoffJobId = nil
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
        // Replace any prior in-flight job.
        pollDrainTask?.cancel()
        pollDrainTask = nil
        // Tear down any prior live job before starting a new one, and clear the
        // shared handoff latch so the new job's terminal action can run.
        liveCoordinator?.teardown()
        handoffJobId = nil

        phase = .submitting
        errorMessage = nil
        activeJob = nil

        // M4: pass `session_id` so the server streams cues live over the
        // playback control websocket — UNLESS realtime is unavailable, in which
        // case we omit it and behave exactly like M3 (poll, no live cues). The
        // poller runs regardless and remains the completion authority.
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

        let gen = generation
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
            handleTerminal(job, isASR: job.kind != .translate, generation: generation)
        } else {
            phase = .running
        }
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
            liveCoordinator?.liveDriverDidGiveUp(message: job.errorMessage ?? "Subtitle translation failed.")
            fail(with: job.errorMessage ?? "Subtitle translation failed.")
        case .cancelled:
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
    private func completePersistedHandoff(
        jobId: String,
        mediaFileId: Int,
        resultSubtitleId: Int?,
        generation gen: Int,
        viaWebsocket: Bool
    ) {
        // Latch: only the first driver to reach completion registers the track.
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
        handoffJobId = jobId

        guard let resultId = resultSubtitleId else {
            Self.logger.warning("[AI-SUB] completed job \(jobId, privacy: .public) has no result_subtitle_id")
            // Without the id we can't synthesize the persisted track. Let the
            // coordinator restore the prior selection rather than stranding the
            // synthetic live track selected.
            liveCoordinator?.liveDriverDidGiveUp(message: "Translation finished but the track couldn't be added.")
            fail(with: "Translation finished but the track couldn't be added.")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let downloaded = (try? await self.api.downloadedSubtitles(mediaFileId: mediaFileId)) ?? []
            // A reset while the listing was in flight invalidates this handoff.
            guard gen == self.generation else { return }

            // Match by DB id (Android: `it.id == resultSubtitleId`); the
            // matched entry's position in the listing fixes its combined index.
            guard let position = downloaded.firstIndex(where: { $0.id == resultId }) else {
                Self.logger.warning(
                    "[AI-SUB] result subtitle id=\(resultId, privacy: .public) not found among \(downloaded.count, privacy: .public) downloaded subtitles"
                )
                self.liveCoordinator?.liveDriverDidGiveUp(message: "Translation finished but the track couldn't be added.")
                self.fail(with: "Translation finished but the track couldn't be added.")
                return
            }

            guard let context = self.handoffContextProvider() else {
                Self.logger.warning("[AI-SUB] no active session/track context for completed subtitle id=\(resultId, privacy: .public)")
                self.liveCoordinator?.liveDriverDidGiveUp(message: "Translation finished but the track couldn't be added.")
                self.fail(with: "Translation finished but the track couldn't be added.")
                return
            }

            guard let descriptor = downloaded[position].synthesizedDescriptor(
                sessionId: context.sessionId,
                baseTrackCount: context.baseTrackCount,
                position: position,
                resolveURL: context.resolveURL
            ) else {
                Self.logger.warning("[AI-SUB] could not synthesize stream URL for completed subtitle id=\(resultId, privacy: .public)")
                self.liveCoordinator?.liveDriverDidGiveUp(message: "Translation finished but the track couldn't be added.")
                self.fail(with: "Translation finished but the track couldn't be added.")
                return
            }

            Self.logger.info(
                "[AI-SUB] handing off completed subtitle id=\(resultId, privacy: .public) combinedIndex=\(descriptor.index, privacy: .public) viaWebsocket=\(viaWebsocket, privacy: .public)"
            )
            self.registerAndSelectDescriptor(descriptor)
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
        guard let job = activeJob, Self.trackKey(for: job.id) == trackKey else {
            Self.logger.debug("[AI-LIVE] ignoring event for stale/unknown trackKey=\(trackKey, privacy: .public)")
            return
        }

        liveCoordinator?.handle(event)
    }

    /// Handle a file-scoped `subtitle_ready` broadcast (M5 fleshes this out).
    /// Today: if it carries a usable id and matches the current file, run the
    /// shared handoff so the track becomes selectable — guarded by the latch so
    /// it never collides with a job-driven completion.
    private func handleSubtitleReady(_ ready: PlaybackRealtimeSubtitleEvent.Ready) {
        guard let mediaFileId = mediaFileIdProvider(),
              let fileId = ready.fileId, fileId == mediaFileId,
              let subtitleId = ready.subtitleId else {
            return
        }
        // Only adopt a `ready` that isn't already owned by the active job's
        // completion (that path handles its own handoff + selection).
        if let job = activeJob, job.resultSubtitleId == subtitleId { return }
        Self.logger.info("[AI-LIVE] subtitle_ready broadcast subtitleId=\(subtitleId, privacy: .public) fileId=\(fileId, privacy: .public)")
        // Use a synthetic job key so the latch doesn't clash with a real job.
        completePersistedHandoff(
            jobId: "ready-\(subtitleId)",
            mediaFileId: mediaFileId,
            resultSubtitleId: subtitleId,
            generation: generation,
            viaWebsocket: true
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
    }

    // MARK: - Helpers

    private func fail(with message: String) {
        phase = .failed
        errorMessage = message
    }

    private static func message(for error: Error) -> String {
        // `HTTPError` is a `LocalizedError` whose `errorDescription` already
        // surfaces the server's parsed error message; fall through to it.
        if let http = error as? HTTPError {
            return http.errorDescription ?? "Couldn't start subtitle translation."
        }
        return "Couldn't start subtitle translation."
    }
}
