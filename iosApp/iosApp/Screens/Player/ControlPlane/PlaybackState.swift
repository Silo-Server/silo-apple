import Foundation
import SwiftUI

// The playback control plane as data: one state, the intents the view sends,
// the events the engine/session/transport report, and the effects the session
// actor runs. Every effect carries the identity it is conditional on
// (`LoadID` or `SessionIdentity`), so a late result from a superseded load or
// session is dropped structurally (design §4 I2).
//
// Nothing consumes these types yet — wave 3 moves `PlayerViewModel`'s load,
// replan, seek, scene-phase and recovery code onto them.

// MARK: - State

enum PlaybackState: Equatable {
    /// Nothing loaded (the view model before its first `loadAndPlay`).
    case idle
    /// A load is resolving its session, plan or engine.
    case preparing(Preparing)
    /// An engine load reached `fileLoaded`; `sub` says what is happening to it.
    case playing(Playing)
    /// tvOS background suspend (`suspendedPlayback`): the engine is gone, the
    /// request and resume position are kept for an explicit resume.
    case suspended(SuspendedContext)
    /// Terminal (`finalizeTerminalPlaybackError`). The `LoadID` is the load
    /// that failed, or `nil` when the failure preceded one; the request is the
    /// replay intent `retry()` re-loads (today's `lastLoadRequest`, which the
    /// terminal path deliberately keeps).
    case failed(PlaybackFailure, LoadID?, request: PlayerViewModel.LoadRequest?)
    /// The player was dismissed; nothing may be scheduled any more.
    case disposed

    /// The load the state is currently bound to, if any.
    var loadID: LoadID? {
        switch self {
        case .idle, .suspended, .disposed: return nil
        case .preparing(let preparing): return preparing.loadID
        case .playing(let playing): return playing.loadID
        case .failed(_, let loadID, _): return loadID
        }
    }

    /// The server session the state is currently bound to, if any.
    var identity: SessionIdentity? {
        switch self {
        case .idle, .suspended, .disposed, .failed: return nil
        case .preparing(let preparing): return preparing.identity
        case .playing(let playing): return playing.identity
        }
    }
}

/// A load between `beginFreshLoad` and the engine's first `fileLoaded`.
struct Preparing: Equatable {
    enum Phase: Equatable {
        /// `runStartSession` / `OfflinePlaybackBuilder.loadPreparedPlayback`.
        case resolvingSession
        /// The prepared session is being turned into an `ExecutablePlan`.
        case planning
        /// `loadBackend` was issued; waiting for `fileLoaded`.
        case startingEngine
    }

    let loadID: LoadID
    /// Known once the session (or the offline stand-in) is prepared.
    var identity: SessionIdentity?
    var phase: Phase
    let request: PlayerViewModel.LoadRequest
    let options: LoadOptions
    let adoption: PlaybackAdoption
    /// Known from `.planning` onwards.
    var plan: ExecutablePlan?
}

/// A load whose engine is live.
struct Playing: Equatable {
    /// One transient-inactive interruption (`PlaybackInterruptionState`). It
    /// coexists with a sub-state — the load is still playing (or paused by the
    /// interruption) while it is pending — so it is a field, not a `Sub` case.
    struct Interruption: Equatable {
        var wasPlaying: Bool
        var positionSeconds: Double
        var recoveryDeadline: Date
        var didAutoRecover: Bool
        var isPending: Bool
    }

    let loadID: LoadID
    /// Rewritten in place by a silent source renewal, which keeps the load.
    var identity: SessionIdentity
    let plan: ExecutablePlan
    /// Today's `lastLoadRequest`: the replay intent every recovery path
    /// rebuilds a fresh load from.
    let request: PlayerViewModel.LoadRequest
    let adoption: PlaybackAdoption
    var transport: TransportState
    var sub: Sub
    var interruption: Interruption?
}

/// What is happening to a live load. Exactly one at a time — the mutually
/// exclusive mode bits the view model kept as separate flags
/// (`protocolV3ReplanTask != nil`, `backgroundRenewalSessionId`,
/// `sourceOutageActive`, `hasReachedEndOfFile`, the seek filter pair) become
/// cases here, which is what makes "no second replan while replanning"
/// structural instead of a guard that two pipelines disagreed about.
enum Sub: Equatable {
    case steady
    case recovering(RecoveryStep)
    case replanning(ReplanIntent)
    case seeking(SeekRequest)
    case renewingSource(SourceRenewal)
    case ridingOutOutage(OutageRideThrough)
    case ended
}

/// The multi-step in-route recoveries that own the load while they run.
/// Single-shot actions (nudge, reassert, reanchor, producer restart) leave the
/// sub-state `.steady`, exactly as the backend ladders do today.
enum RecoveryStep: Equatable {
    case reloadingItem
    case rebuildingLocalSession
    case switchingRoute
    case recoveringFromServerOutage
    case waitingForServerReady
}

/// tvOS background suspend context (`SuspendedPlaybackContext`).
struct SuspendedContext: Equatable {
    let request: PlayerViewModel.LoadRequest
    let resumePosition: Double
}

/// The live transport facts the control plane tracks. The view model keeps
/// projecting them; the reducer needs them for the seek filter, the near-end
/// rule and `publish`.
struct TransportState: Equatable {
    var isPaused: Bool = false
    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
    var isBuffering: Bool = false
    var bufferedAheadSeconds: Double = 0
    var runwaySeconds: Double = 0
    var stats: PlaybackStats?
    /// `AVPlayerBackend.isExternalPlaybackActive` (AirPlay). The iOS
    /// background rule exempts it.
    var isExternalPlaybackActive: Bool = false
    /// The backend's `isPictureInPictureActiveProvider` fact. The iOS
    /// background rule exempts it too.
    var isPictureInPictureActive: Bool = false
}

// MARK: - Load inputs

/// Where a load came from. Mirrors `PlayerViewModel.LoadOrigin` (private
/// there); wave 3 deletes that copy.
enum LoadOrigin: Equatable {
    /// User picked an item — unbounded start, full-screen error on failure.
    case userInitiated
    /// Next Up hand-off — timeout-bounded, failures restore the postroll.
    case autoplay
    /// Automatic recovery (interruption, stale session, server outage).
    case recovery
}

/// The `beginFreshLoad` parameters that are not part of `LoadRequest`.
/// Carried on the intent and on `Effect.startSession` so the load is one
/// self-contained value instead of seven positional arguments.
struct LoadOptions: Equatable {
    /// `progressPosition` — reported (or finalized) against the *outgoing*
    /// session before the new one starts. `nil` reports nothing.
    var progressPosition: Double?
    /// `finalizeCurrentSession` — stop the outgoing session instead of only
    /// reporting progress against it.
    var finalizeCurrentSession: Bool
    /// `resumePositionOverride` — where the new session should start.
    var resumePosition: Double?
    /// `allowNearEndResume`.
    var allowNearEndResume: Bool
    /// `preserveInterruptionState` — keeps the tvOS interruption timer alive
    /// across the load.
    var preserveInterruptionState: Bool

    init(
        progressPosition: Double? = nil,
        finalizeCurrentSession: Bool = false,
        resumePosition: Double? = nil,
        allowNearEndResume: Bool = false,
        preserveInterruptionState: Bool = false
    ) {
        self.progressPosition = progressPosition
        self.finalizeCurrentSession = finalizeCurrentSession
        self.resumePosition = resumePosition
        self.allowNearEndResume = allowNearEndResume
        self.preserveInterruptionState = preserveInterruptionState
    }

    static let userLoad = LoadOptions()
}

/// Which pipeline produced the engine load. Mirrors the parts of
/// `PlayerViewModel.PlaybackAdoptionOrigin` the control plane decides with —
/// its other payloads (subtitle snapshots, sidecar fallbacks) are track-half
/// state and stay with the track coordinator.
enum PlaybackAdoption: Equatable {
    case freshLoad(LoadOrigin)
    case replan(ReplanIntent.Kind)

    /// `PlaybackAdoptionOrigin.reusesActiveEngine`: only a live V3 server
    /// replan keeps the outgoing `AVPlayerBackend` (audio session + identical
    /// tvOS display criteria, no HDMI renegotiation).
    var reusesActiveEngine: Bool {
        if case .replan(.serverReplan) = self { return true }
        return false
    }

    /// `adoptPreparedPlayback`'s per-origin report: a fresh load and a V3
    /// replan report plan execution, the in-place transcode restart
    /// deliberately never has.
    var reportsPlanExecutionStarted: Bool {
        switch self {
        case .freshLoad: return true
        case .replan(.serverReplan): return true
        case .replan(.transcodeRestart): return false
        }
    }
}

// MARK: - Replan

/// One intent for both replan pipelines. `attemptProtocolV3Replan` and
/// `restartCurrentTranscodeHLS` take the same server call with different
/// arguments and different in-flight slots today, which is why a quality
/// restart could start while a replan was running.
struct ReplanIntent: Equatable {
    enum Kind: Equatable {
        /// `attemptProtocolV3Replan` — may keep the live engine.
        case serverReplan
        /// `restartCurrentTranscodeHLS` — always reloads the engine.
        case transcodeRestart(TranscodeRestartOrigin)
    }

    let kind: Kind
    /// The replan position (`position:` / the restart's `target`).
    let position: Double
    let classification: String
    let message: String
    /// `PlaybackProtocolV3.ReplanOperation` token, when the caller pins one.
    let operation: String?
    let qualityPreference: String?
    /// Clears `isQualitySwitching` when the replan settles.
    let completesQualitySwitch: Bool
    let outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot?
    /// The combined V3 subtitle ordinal the track half asks the server for.
    let subtitleIndex: Int?

    init(
        kind: Kind,
        position: Double,
        classification: String,
        message: String,
        operation: String? = nil,
        qualityPreference: String? = nil,
        completesQualitySwitch: Bool = false,
        outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot? = nil,
        subtitleIndex: Int? = nil
    ) {
        self.kind = kind
        self.position = position
        self.classification = classification
        self.message = message
        self.operation = operation
        self.qualityPreference = qualityPreference
        self.completesQualitySwitch = completesQualitySwitch
        self.outputRouteSnapshot = outputRouteSnapshot
        self.subtitleIndex = subtitleIndex
    }
}

/// Why an in-place transcode restart was requested (`source:` today).
enum TranscodeRestartOrigin: Equatable {
    case qualityChange(qualityId: String)
    /// Requires the server's `seek_reanchor` feature.
    case seekReanchor(origin: Double)
}

/// A silent direct-session renewal in flight (`attemptBackgroundSessionRenewal`).
/// The sub-state *is* the single-flight guard the two `*SessionId` echoes
/// provided.
struct SourceRenewal: Equatable {
    let reason: String
    let observedPosition: Double
    let startedAt: Date
}

/// An origin-outage ride-through in flight (`handleOriginOutageChanged`).
struct OutageRideThrough: Equatable {
    let startedAt: Date
    /// The next `probeServerHealthOnce` delay (1 → ×2 → capped).
    let nextProbeDelay: Duration
    /// Whether the "Reconnecting" notice has already been shown.
    let noticeShown: Bool
}

// MARK: - Seeking

struct SeekRequest: Equatable {
    let id: UUID
    /// The pre-seek position (`seekOriginTime`) — the filter needs it to tell
    /// a stale drainage frame from a landed one.
    let fromSeconds: Double
    /// `seekTargetTime`.
    let targetSeconds: Double
    let origin: SeekOrigin
    /// Every seek has one (design §4 I5); mirrors the backend's
    /// `seekCompletionDeadlineSeconds`.
    let deadline: Date
}

enum SeekOrigin: Equatable {
    case user
    case scrub
    case skip
    case chapter
    case intro
    case credits
    case nextUpKeepWatching
    case recovery(String)
    /// A stream rebuild anchored at a new position: the UI filter is armed
    /// without the 5 s safety timeout (`beginReanchorSeekUI`).
    case reanchor
}

// MARK: - Intents

/// What the view (or the platform) asks for. The reducer is the only place
/// these turn into effects.
enum PlayerIntent: Equatable {
    case load(PlayerViewModel.LoadRequest, origin: LoadOrigin, options: LoadOptions)
    case play
    case pause
    case togglePlayPause
    case seek(targetSeconds: Double, origin: SeekOrigin)
    case changeQuality(String)
    case outputRouteChanged(ApplePlaybackV3CapabilitySnapshot)
    case scenePhase(ScenePhase)
    case resumeSuspended
    case retry
    case dismiss
}

// MARK: - Events

/// What happened, stamped with the identity it happened for.
enum PlayerEvent: Equatable {
    case engine(EngineEvent, LoadID)
    case session(SessionEvent, SessionIdentity)
    case transport(TransportEvent, LoadID)
    /// The action `RecoveryPolicy` decided for an observation the actor
    /// collected. The reducer maps it to state + effects; it never decides.
    case recovery(RecoveryAction, LoadID)
    case timer(TimerID, LoadID)
}

/// Backend → control plane. The recovery *observations* the backend also
/// emits go to `RecoveryPolicy`, not through the reducer.
enum EngineEvent: Equatable {
    case fileLoaded(reason: String)
    case firstFrame(ms: Int)
    case time(seconds: Double)
    case duration(seconds: Double)
    case pauseChanged(Bool)
    case buffering(Bool)
    case bufferedAhead(PlaybackBufferedAhead)
    case stats(PlaybackStats)
    case tracks([PlayerTrack])
    case chapters([PlayerChapterInfo])
    case timelineOffset(Double)
    case endOfFile
    case failed(PlaybackFailure)
    case externalPlayback(active: Bool)
    case externalPlaybackAllowed(Bool)
    case externalPlaybackUnavailable
    case sidecarTracksRegistered([SidecarSubtitleDescriptor])
}

/// `PlaybackSessionBridge` → control plane. The `ExecutablePlan` travels with
/// the prepared session because resolving it runs the route planner and the V3
/// adapter (`makeExecutionPlan`), which is not reducer work.
enum SessionEvent: Equatable {
    /// Carries the `LoadID` it answers: a fresh prepare mints a brand-new
    /// `SessionIdentity`, so there is nothing else to match it against.
    case prepared(PreparedPlaybackRef, ExecutablePlan, for: LoadID)
    /// Matched on the session it replaced (`SessionIdentity` keeps the server
    /// session and playback attempt across a replan; only the plan attempt
    /// changes).
    case replanned(PreparedPlaybackRef, ExecutablePlan)
    /// The server declined to replace the plan in place (`replan` → `nil`).
    case replanUnavailable
    case terminal(PlaybackV3TerminalFailure)
    case sessionMissing
    case renewed(PreparedPlaybackRef)
    case renewalFailed(transient: Bool)
}

/// `PlaybackSourceProxy` → control plane.
enum TransportEvent: Equatable {
    case sessionMissing
    case sourceInterrupted(reason: String)
    case originOutage(active: Bool)
}

/// The control-plane keys of `PlayerTaskRegistry.Key`. UI timers
/// (hideControls, noticeDismiss, skipDebounce, holdSeek*, nextUp*,
/// autoSkipIntro) stay on the presentation model.
enum TimerID: Equatable, Hashable, CaseIterable {
    case freshLoad
    case protocolV3Replan
    case staleSessionRecovery
    case backgroundRenewal
    case sourceOutageRideThrough
    case serverOutageRecovery
    case interruptionRecovery
    case seekFilterTimeout
    case progress
}

// MARK: - Effects

/// What the session actor runs. Every case carries the identity it is
/// conditional on, so the actor can drop a result whose load or session was
/// superseded without consulting any counter.
enum Effect: Equatable {
    /// `runStartSession` or `OfflinePlaybackBuilder.loadPreparedPlayback` →
    /// `.session(.prepared)`.
    case startSession(PlayerViewModel.LoadRequest, LoadOptions, LoadID)
    case stopSession(SessionIdentity, position: Double?, isPaused: Bool)
    /// `reuseEngine == true` is today's `prepareBackend(for:)` path: the live
    /// `AVPlayerBackend` survives, its callbacks re-bind to the new `LoadID`.
    case loadEngine(ExecutablePlan, LoadID, reuseEngine: Bool)
    case disposeEngine(LoadID)
    case seek(SeekRequest, LoadID)
    /// `replanProtocolV3` → `.session(.replanned | .replanUnavailable | .terminal | .sessionMissing)`.
    case replan(ReplanIntent, SessionIdentity)
    /// `renewDirectSession` + `PlaybackSourceProxy.retargetOrigin`.
    case renewSource(SourceRenewal, SessionIdentity)
    /// Engine-session-level recovery (nudge / reload / reanchor / rebuild /
    /// reassert / route switch).
    case runRecovery(RecoveryAction, LoadID)
    /// `probeServerHealthOnce` after a delay → `.recovery` again.
    case pollServerHealth(TimerID, after: Duration, LoadID)
    case schedule(TimerID, after: Duration, LoadID)
    case cancelTimer(TimerID)
    case reportProgress(SessionIdentity, position: Double, isPaused: Bool)
    case reportFirstFrame(SessionIdentity, ms: Int)
    case reportPlanExecutionStarted(SessionIdentity)
    /// Transport commands the view asked for (`play` / `pause`).
    case transport(TransportCommand, LoadID)
    /// The only path to UI state.
    case publish(Presentation)
}

enum TransportCommand: Equatable {
    case play
    case pause
}

// MARK: - Presentation

/// The stored projections the control plane owns. View-local state
/// (showControls, scrubbing, hold-seek, HUD, next-up, notices, sleep timer)
/// stays view-model-owned, so it is deliberately absent here.
struct Presentation: Equatable {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isLoading: Bool = false
    var isBuffering: Bool = false
    /// Today's `error` string (the view renders the full-screen failure).
    var error: String?
    /// Set while the server-outage recovery owns the load — today's 90 s
    /// "Reconnecting" notice is raised by the view model from this state.
    var isReconnecting: Bool = false
    var activeQualityId: String?
    var isQualitySwitching: Bool = false
    var bufferedAheadSeconds: Double = 0
    var playbackRunwaySeconds: Double = 0
    var playbackStats: PlaybackStats?
    var metadata: PlayerMetadata?

    init(
        isPlaying: Bool = false,
        currentTime: Double = 0,
        duration: Double = 0,
        isLoading: Bool = false,
        isBuffering: Bool = false,
        error: String? = nil,
        isReconnecting: Bool = false,
        activeQualityId: String? = nil,
        isQualitySwitching: Bool = false,
        bufferedAheadSeconds: Double = 0,
        playbackRunwaySeconds: Double = 0,
        playbackStats: PlaybackStats? = nil,
        metadata: PlayerMetadata? = nil
    ) {
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.isLoading = isLoading
        self.isBuffering = isBuffering
        self.error = error
        self.isReconnecting = isReconnecting
        self.activeQualityId = activeQualityId
        self.isQualitySwitching = isQualitySwitching
        self.bufferedAheadSeconds = bufferedAheadSeconds
        self.playbackRunwaySeconds = playbackRunwaySeconds
        self.playbackStats = playbackStats
        self.metadata = metadata
    }
}

// MARK: - Boxed payloads

/// `PreparedPlayback` carries three server response models with no `Equatable`
/// conformance, so the event that delivers it compares by the identity keys
/// that decide whether two prepares are the same one: the server session id,
/// the adopted V3 attempt (itself `Equatable`), the content and file it
/// resolved to, and the quality it was prepared at.
struct PreparedPlaybackRef: Equatable {
    let value: PreparedPlayback

    init(_ value: PreparedPlayback) {
        self.value = value
    }

    static func == (lhs: PreparedPlaybackRef, rhs: PreparedPlaybackRef) -> Bool {
        lhs.value.session.sessionId == rhs.value.session.sessionId
            && lhs.value.activeQualityId == rhs.value.activeQualityId
            && lhs.value.watchDetail.contentId == rhs.value.watchDetail.contentId
            && lhs.value.selectedVersion.fileId == rhs.value.selectedVersion.fileId
            && lhs.value.protocolV3 == rhs.value.protocolV3
    }
}

/// `LoadRequest` is declared inside `PlayerViewModel` (wave 3 moves it out),
/// so `Equatable` cannot be synthesized from here. The comparison covers every
/// stored property; `PlaybackReducerTests.testLoadRequestEqualityCoversEveryStoredProperty`
/// fails if one is added.
extension PlayerViewModel.LoadRequest: Equatable {
    static func == (lhs: PlayerViewModel.LoadRequest, rhs: PlayerViewModel.LoadRequest) -> Bool {
        lhs.contentId == rhs.contentId
            && lhs.preferredFileId == rhs.preferredFileId
            && lhs.preferredAudioTrackIndex == rhs.preferredAudioTrackIndex
            && lhs.preferredSubtitleTrackIndex == rhs.preferredSubtitleTrackIndex
            && lhs.preferredSidecarSubtitleTrackId == rhs.preferredSidecarSubtitleTrackId
            && lhs.startFromBeginning == rhs.startFromBeginning
            && lhs.preferredProtocolV3SubtitleIndex == rhs.preferredProtocolV3SubtitleIndex
            && lhs.offlineDownloadId == rhs.offlineDownloadId
            && lhs.preferredQualityOverride == rhs.preferredQualityOverride
    }
}
