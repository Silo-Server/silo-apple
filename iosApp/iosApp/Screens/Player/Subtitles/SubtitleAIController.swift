//
//  SubtitleAIController.swift
//  Continuum (iOS + tvOS)
//
//  Per-session orchestrator for the in-player AI subtitle suite — translate
//  an existing text track, transcribe audio (Whisper), or transcribe-and-
//  translate. Owned by ``PlayerViewModel`` and constructed/reset alongside
//  the playback session lifecycle.
//
//  Milestone 3 (this file) ships the complete feature over **polling**, the
//  same contract the Android client uses:
//    POST /subtitles/ai/translate  →  store the job  →  poll
//    GET  /subtitles/ai/jobs/{id}   until terminal    →  on `completed`,
//    fetch GET /subtitles/{media_file_id}, locate the result subtitle, and
//    register it as a normal downloaded sidecar track (then auto-select it).
//
//  The POST deliberately **omits `session_id`** in M3: passing it would make
//  the server stream cues over the playback websocket, which this milestone
//  can't consume yet. M4 adds `session_id` + a live cue driver layered on top
//  of this controller — the job lifecycle + completion handoff here stay the
//  authority underneath, so a socket drop always degrades to polling.
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
        handoffContext: @escaping @MainActor () -> HandoffContext?,
        registerAndSelectDescriptor: @escaping @MainActor (SidecarSubtitleDescriptor) -> Void
    ) {
        self.api = api
        self.poller = poller
        self.capabilities = capabilities
        self.mediaFileIdProvider = mediaFileId
        self.currentTimeProvider = currentTime
        self.handoffContextProvider = handoffContext
        self.registerAndSelectDescriptor = registerAndSelectDescriptor
    }

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

        phase = .submitting
        errorMessage = nil
        activeJob = nil

        // OMIT session_id in M3 (poll-only). start_position is still sent so
        // the watched region translates first.
        let body = TranslateSubtitleBody(
            mediaFileId: mediaFileId,
            kind: kind,
            sourceIndex: sourceIndex,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sessionId: nil,
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
            performCompletionHandoff(for: job, generation: gen)
        case .failed:
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

    /// On `completed`, fetch the file's downloaded subtitles, find the entry
    /// whose **`id`** equals the job's `result_subtitle_id`, synthesize its
    /// player descriptor (URL + combined index — the listing carries neither),
    /// and hand it to the VM to register + auto-select via the existing
    /// sidecar path.
    ///
    /// The listing (`GET /subtitles/{media_file_id}`) returns the server's
    /// `DownloadedSubtitle` shape: a DB `id` plus metadata, **no** stream
    /// `url` and **no** combined player index. We therefore synthesize the
    /// descriptor exactly like Android's `SubtitleTrackMerge` (combined index
    /// past the existing external+embedded+downloaded tracks; stream URL on
    /// the session-scoped `/stream/{session}/subtitles/{combined-index}<ext>`
    /// mount, which keys on the combined index — verified server-side).
    ///
    /// `generation` is the value captured at submit time; a reset mid-fetch
    /// invalidates the handoff so a stale completion can't land on the next
    /// account/session.
    private func performCompletionHandoff(for job: SubtitleJob, generation gen: Int) {
        guard let resultId = job.resultSubtitleId else {
            Self.logger.warning("[AI-SUB] completed job \(job.id, privacy: .public) has no result_subtitle_id")
            fail(with: "Translation finished but the track couldn't be added.")
            return
        }
        let mediaFileId = job.mediaFileId
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
                self.fail(with: "Translation finished but the track couldn't be added.")
                return
            }

            guard let context = self.handoffContextProvider() else {
                Self.logger.warning("[AI-SUB] no active session/track context for completed subtitle id=\(resultId, privacy: .public)")
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
                self.fail(with: "Translation finished but the track couldn't be added.")
                return
            }

            Self.logger.info(
                "[AI-SUB] handing off completed subtitle id=\(resultId, privacy: .public) combinedIndex=\(descriptor.index, privacy: .public)"
            )
            self.registerAndSelectDescriptor(descriptor)
        }
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
