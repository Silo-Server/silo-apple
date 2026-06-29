//
//  LiveSubtitleCoordinator.swift
//  Continuum (iOS + tvOS)
//
//  The live AI-subtitle state machine (Milestone 4). Layers a real-time,
//  playhead-first cue experience over the websocket on top of the M3 polling
//  authority:
//
//    started   → snapshot the current subtitle selection; pause if playing
//                (remember `wasPlaying`); install + select a synthetic styled
//                libass track; show "Preparing…"; arm a 30s safety-resume
//                timer (so a job that never streams a cue can't strand the
//                viewer paused).
//    cues      → feed each cue to the live track; on the FIRST batch, cancel
//                the safety timer, hide the overlay, and resume playback
//                (playhead-first) if we paused.
//    completed → hand the persisted subtitle off (via the M3 controller
//                handoff, which the poller may have already performed — the
//                two share ONE terminal action and must not double-register);
//                swap selection from the live track to the persisted one;
//                close the live track.
//    failed    → also fired on the 30s timeout or a socket-lost-with-no-poll-
//                completion: close the live track, restore the prior
//                selection, resume if we paused, surface a soft notice.
//
//  Design contract (matches the spec's Data flow (e)):
//    - The coordinator is the SINGLE owner of pause/resume intent. Nothing
//      else pauses/resumes during a live job; the coordinator tracks
//      `wasPlaying` and resumes exactly once.
//    - It is driver-agnostic: the same transitions run whether the driver is
//      the websocket (premium) or the poller (authority/fallback). The owning
//      controller forwards both.
//    - A monotonically-bumped generation + the active `track_key` guard against
//      stale callbacks: events/cues/timeouts for a torn-down or superseded job
//      are ignored, so a late websocket frame can't reanimate a finished job.
//    - `@MainActor @Observable` so its `phase` binds to UI directly and all
//      mutations stay on main; the sink/controls hop to the player's queues.
//
//  Everything the coordinator touches the player through is behind the
//  ``LivePlaybackControls`` and ``LiveSubtitleSink`` seams, and the safety
//  timer is an injected factory, so the whole machine is unit-tested headless
//  — no libass, no websocket, no player (see `LiveSubtitleCoordinatorTests`).
//

import Foundation
import OSLog

// MARK: - Seams

/// Playback transport the coordinator drives. The coordinator is the only
/// thing that pauses/resumes during a live job — it is pause/resume only, so
/// the seam is just `pause`/`play`/`isPlaying`.
@MainActor
protocol LivePlaybackControls: AnyObject {
    func pause()
    func play()
    var isPlaying: Bool { get }
}

/// The live-track surface the coordinator manipulates: a synthetic libass
/// track, its selection, the persisted-track handoff, and the "Preparing…"
/// notice. Implemented as an adapter over the M2 live-track primitives, the
/// M3 completion handoff, the VM's selection plumbing, and the notice surface.
@MainActor
protocol LiveSubtitleSink: AnyObject {
    /// Open a synthetic styled live track (and add its picker row) for the
    /// given `trackKey`. The ordinal that backs the track id is derived from
    /// the key by the adapter.
    func installLiveTrack(trackKey: String, label: String?, language: String?)
    /// Feed one streamed cue (absolute media-time seconds). The adapter owns
    /// the seconds→milliseconds + transcode-offset conversion and the
    /// M2 `LiveSubtitleTrack` dedupe.
    func feedCue(_ cue: PlaybackRealtimeSubtitleCue)
    /// Select the live track installed for `trackKey`.
    func selectLive(trackKey: String)
    /// Close the synthetic live track for `trackKey` and remove its picker row.
    func closeLiveTrack(trackKey: String)
    /// Restore whatever subtitle selection was active before the live job
    /// began (the snapshot the coordinator captured and passed back here).
    func restorePriorSelection(_ selection: Int64?)
    /// Hand the persisted subtitle off and swap the live selection to it.
    /// Idempotent / shared with the poller — the adapter de-dupes so the
    /// websocket and the poller don't double-register the track.
    func registerPersisted(subtitleId: Int)
    /// Show the "Preparing… subtitles" notice while the first cues arrive.
    func showPreparingNotice()
    /// Surface a soft failure notice (job failed / timed out / gave up).
    func showFailureNotice(_ message: String)
}

/// A cancellable handle for the safety-resume timer.
protocol LiveSubtitleCancellable: AnyObject {
    func cancel()
}

/// Schedules the safety-resume action. Injected so tests drive it
/// deterministically instead of waiting 30 wall-clock seconds. Production
/// uses ``RealLiveSubtitleClock`` (a `Task.sleep`).
@MainActor
protocol LiveSubtitleClock {
    /// Run `action` after `seconds`, unless the returned handle is cancelled
    /// first. The action runs on the main actor.
    func scheduleSafetyResume(
        after seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> LiveSubtitleCancellable
}

/// Production clock: a cancellable `Task.sleep` on the main actor.
@MainActor
final class RealLiveSubtitleClock: LiveSubtitleClock {
    /// `nonisolated` so it can be used as a default-argument value for the
    /// coordinator's (main-actor) initializer — default arguments evaluate in
    /// a nonisolated context. The body stores nothing, so it is main-safe.
    nonisolated init() {}

    func scheduleSafetyResume(
        after seconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> LiveSubtitleCancellable {
        let handle = TaskCancellable()
        handle.task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
        return handle
    }

    private final class TaskCancellable: LiveSubtitleCancellable {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel(); task = nil }
    }
}

// MARK: - Coordinator

/// The live AI-subtitle state machine. See the file header for the transition
/// contract.
@MainActor
@Observable
final class LiveSubtitleCoordinator {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LiveSubtitle"
    )

    /// Safety net: if a started job streams no cue within this window, resume
    /// playback and fail out rather than strand the viewer on a paused frame.
    static let safetyResumeSeconds: TimeInterval = 30

    /// Where the live machine is. The owning controller maps this onto the
    /// "Preparing…" overlay; tests assert on it.
    enum Phase: Equatable {
        /// No live job.
        case idle
        /// `started` received: paused, synthetic track installed + selected,
        /// overlay up, safety timer armed, waiting for the first cue batch.
        case preparing
        /// First cues arrived: resumed, cues rendering live.
        case streaming
        /// `completed`: handed off to the persisted track.
        case completed
        /// `failed` / timed out / gave up: prior selection restored.
        case failed
    }

    private(set) var phase: Phase = .idle

    // MARK: Injected collaborators

    private let controls: LivePlaybackControls
    private let sink: LiveSubtitleSink
    private let clock: LiveSubtitleClock

    /// `nonisolated` so the owning `PlayerViewModel` (Swift-5 mode, not globally
    /// `@MainActor`) can construct this `@MainActor` coordinator from its lazy
    /// `subtitleAI` property initializer without an `assumeIsolated` wrapper —
    /// the same pattern `SubtitleAIController.init` uses. The body only stores
    /// immutable references and never touches `@Observable` main-actor state.
    nonisolated init(
        controls: LivePlaybackControls,
        sink: LiveSubtitleSink,
        clock: LiveSubtitleClock = RealLiveSubtitleClock(),
        selectionSnapshot: (@MainActor () -> Int64?)? = nil
    ) {
        self.controls = controls
        self.sink = sink
        self.clock = clock
        self.selectionSnapshotProvider = selectionSnapshot
    }

    // MARK: Per-job state

    /// The live job's `track_key`. Every callback is matched against this; a
    /// mismatch means the event belongs to a stale / superseded job and is
    /// dropped.
    private var activeTrackKey: String?

    /// Snapshot of the subtitle selection before the live job began, restored
    /// on failure.
    private var priorSelection: Int64?

    /// Whether we paused for this job (so we resume exactly once, and only if
    /// we were the ones who paused).
    private var wasPlaying = false

    /// Set once the first cue batch has been processed for the active job, so
    /// later batches don't re-resume / re-cancel the timer.
    private var didResume = false

    /// The armed safety-resume timer, cancelled on first cues / completion /
    /// teardown.
    private var safetyTimer: LiveSubtitleCancellable?

    /// Bumped on every job start and on `teardown()`. Async/scheduled work
    /// captures it and discards itself when it no longer matches — so a stale
    /// timer or late frame can't act on a finished job.
    private var generation = 0

    /// Optional hook the adapter sets so the coordinator can read the live
    /// `selectedSubtitleId` at `started` time (the snapshot it restores on
    /// failure). Infrastructure, not observable UI state.
    @ObservationIgnored
    var selectionSnapshotProvider: (@MainActor () -> Int64?)?

    // MARK: - Driver entry point

    /// Whether a live job is currently in flight (preparing or streaming).
    var isActive: Bool { phase == .preparing || phase == .streaming }

    /// Feed one decoded subtitle event into the machine. The owning controller
    /// forwards both websocket events and poller-derived events here; the
    /// machine itself is driver-agnostic.
    func handle(_ event: PlaybackRealtimeSubtitleEvent) {
        switch event {
        case .started(let started):
            onStarted(started)
        case .cues(let cues):
            onCues(cues)
        case .completed(let completed):
            onCompleted(completed)
        case .failed(let failed):
            onFailed(failed)
        case .ready:
            // `ready` is file-scoped and handled by the controller (append the
            // track so it's selectable), not by the per-job machine.
            break
        }
    }

    // MARK: - Transitions

    private func onStarted(_ started: PlaybackRealtimeSubtitleEvent.Started) {
        // A second `started` for a DIFFERENT job supersedes the current one —
        // tear the old live track down first so we never leave two installed.
        // FIX 8: tear down with `resume: false` — the new job is about to
        // re-pause anyway, so resuming here would cause a resume-then-repause
        // flicker. The new job's own `wasPlaying` snapshot (captured just below,
        // after this teardown restores the prior selection) decides the final
        // play/pause state.
        if let active = activeTrackKey, active != started.trackKey {
            Self.logger.info("[AI-LIVE] superseding active job \(active, privacy: .public) with \(started.trackKey, privacy: .public)")
            teardownActiveTrack(restoreSelection: true, resume: false)
        } else if activeTrackKey == started.trackKey {
            // Duplicate `started` (e.g. websocket replay) — ignore.
            return
        }

        generation &+= 1
        activeTrackKey = started.trackKey
        didResume = false

        // Snapshot selection + pause intent BEFORE we install/select the live
        // track, so the snapshot reflects the user's real prior choice.
        priorSelection = currentSelectionSnapshot()
        wasPlaying = controls.isPlaying
        if wasPlaying {
            controls.pause()
        }

        sink.installLiveTrack(
            trackKey: started.trackKey,
            label: started.label,
            language: started.language
        )
        sink.selectLive(trackKey: started.trackKey)
        sink.showPreparingNotice()
        phase = .preparing

        Self.logger.info(
            "[AI-LIVE] started trackKey=\(started.trackKey, privacy: .public) wasPlaying=\(self.wasPlaying, privacy: .public) totalCues=\(started.totalCues ?? -1, privacy: .public)"
        )

        armSafetyTimer()
    }

    private func onCues(_ batch: PlaybackRealtimeSubtitleEvent.Cues) {
        guard isOwnedAndActive(batch.trackKey) else { return }

        for cue in batch.cues {
            sink.feedCue(cue)
        }

        // First non-empty batch is the resume trigger (playhead-first): cancel
        // the safety timer and resume if we paused. An empty first batch
        // (`done` heartbeat with no cues) does NOT resume — we keep waiting for
        // real cues, still bounded by the safety timer.
        if !didResume, !batch.cues.isEmpty {
            didResume = true
            cancelSafetyTimer()
            phase = .streaming
            if wasPlaying {
                controls.play()
            }
            Self.logger.info(
                "[AI-LIVE] first cues trackKey=\(batch.trackKey, privacy: .public) count=\(batch.cues.count, privacy: .public) resumed=\(self.wasPlaying, privacy: .public)"
            )
        }
    }

    private func onCompleted(_ completed: PlaybackRealtimeSubtitleEvent.Completed) {
        guard isOwnedAndActive(completed.trackKey) else { return }

        cancelSafetyTimer()

        // If completion arrives before any cue (short clip / instant job),
        // make sure we don't leave the viewer paused.
        if !didResume, wasPlaying {
            controls.play()
        }
        didResume = true

        // Hand off to the persisted track. The adapter de-dupes with the
        // poller so the track is registered once; selection swaps live→persisted
        // there. Only attempt when the server actually told us the id.
        if let subtitleId = completed.subtitleId {
            sink.registerPersisted(subtitleId: subtitleId)
        } else {
            Self.logger.warning("[AI-LIVE] completed trackKey=\(completed.trackKey, privacy: .public) carried no subtitle_id; relying on poller handoff")
        }

        // The persisted track now owns the caption; drop the synthetic one.
        sink.closeLiveTrack(trackKey: completed.trackKey)
        phase = .completed
        clearJob()
        Self.logger.info("[AI-LIVE] completed trackKey=\(completed.trackKey, privacy: .public) subtitleId=\(completed.subtitleId ?? -1, privacy: .public)")
    }

    private func onFailed(_ failed: PlaybackRealtimeSubtitleEvent.Failed) {
        guard isOwnedAndActive(failed.trackKey) else { return }
        failOut(message: failed.message ?? "Subtitle translation failed.")
    }

    // MARK: - Failure / timeout (shared terminal path)

    private func armSafetyTimer() {
        let gen = generation
        safetyTimer?.cancel()
        safetyTimer = clock.scheduleSafetyResume(after: Self.safetyResumeSeconds) { [weak self] in
            guard let self, gen == self.generation else { return }
            guard self.phase == .preparing else { return }
            Self.logger.warning("[AI-LIVE] safety timeout — no cues within \(Self.safetyResumeSeconds, privacy: .public)s, resuming")
            self.failOut(message: "Couldn't start live subtitles. Try again.")
        }
    }

    /// Terminal failure path shared by the `failed` event, the safety timeout,
    /// and a socket-lost-with-no-poll-completion give-up: close the live
    /// track, restore the prior selection, resume if we paused, soft notice.
    private func failOut(message: String) {
        guard activeTrackKey != nil else { return }
        teardownActiveTrack(restoreSelection: true, resume: true)
        phase = .failed
        sink.showFailureNotice(message)
    }

    /// Called by the controller when the live driver gives up (socket lost and
    /// the poller never reached completion). Same terminal path as `failed`.
    func liveDriverDidGiveUp(message: String = "Live subtitles were interrupted.") {
        guard isActive else { return }
        failOut(message: message)
    }

    /// Called by the controller when the poller has already completed the
    /// handoff for the active job (poller-as-authority won the race). Swap off
    /// the live track and close it WITHOUT re-registering — the persisted track
    /// is already in the list.
    func persistedHandoffAlreadyDone(trackKey: String?) {
        // If the completion is for the active job (or the controller couldn't
        // resolve a key but a job is active), finish cleanly.
        guard isActive else { return }
        if let trackKey, let active = activeTrackKey, trackKey != active { return }
        cancelSafetyTimer()
        if !didResume, wasPlaying {
            controls.play()
        }
        didResume = true
        if let active = activeTrackKey {
            sink.closeLiveTrack(trackKey: active)
        }
        phase = .completed
        clearJob()
        Self.logger.info("[AI-LIVE] poller authority completed handoff; closed live track")
    }

    // MARK: - Teardown

    /// Full teardown (controller reset / session end). Cancels the timer,
    /// restores selection if a job is live, and bumps the generation so any
    /// outstanding scheduled work no-ops.
    func teardown() {
        generation &+= 1
        if activeTrackKey != nil {
            teardownActiveTrack(restoreSelection: true, resume: false)
        }
        cancelSafetyTimer()
        phase = .idle
    }

    private func teardownActiveTrack(restoreSelection: Bool, resume: Bool) {
        cancelSafetyTimer()
        let key = activeTrackKey
        if resume, !didResume, wasPlaying {
            controls.play()
        }
        if let key {
            sink.closeLiveTrack(trackKey: key)
        }
        if restoreSelection {
            sink.restorePriorSelection(priorSelection)
        }
        clearJob()
    }

    private func clearJob() {
        activeTrackKey = nil
        priorSelection = nil
        wasPlaying = false
        didResume = false
        generation &+= 1
    }

    // MARK: - Guards / helpers

    /// True when `trackKey` belongs to the active live job and that job is
    /// still preparing/streaming. Stale or unknown keys are rejected.
    private func isOwnedAndActive(_ trackKey: String) -> Bool {
        guard let active = activeTrackKey, active == trackKey else { return false }
        return phase == .preparing || phase == .streaming
    }

    private func cancelSafetyTimer() {
        safetyTimer?.cancel()
        safetyTimer = nil
    }

    private func currentSelectionSnapshot() -> Int64? {
        // The sink protocol is action-only; the adapter exposes the VM's live
        // `selectedSubtitleId` through `selectionSnapshotProvider` so the
        // coordinator can snapshot it at `started` time and hand it back on
        // `restorePriorSelection`. Modelled as a closure (rather than a
        // returning sink method) so the fake in tests scripts it trivially.
        selectionSnapshotProvider?()
    }
}
