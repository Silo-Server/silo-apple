import Foundation
import SwiftUI

// The playback control plane as data: one state, the intents the view sends,
// the events the engine/session/transport report, and the effects the session
// actor runs. Every effect carries the identity it is conditional on
// (`LoadID` or `SessionIdentity`), so a late result from a superseded load or
// session is dropped structurally (design §4 I2).

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
    ///
    /// `position` is the playhead the failure happened at.
    /// `finalizeTerminalPlaybackError` deliberately does not
    /// reset `currentTime`, which is what lets `retry()` pass
    /// `progressPosition: currentTime` / `resumePositionOverride: currentTime`
    /// and resume where playback died; without it here, Retry would restart
    /// the title from the beginning.
    ///
    /// Only the playhead is carried, not the whole `TransportState`: the
    /// error screen and the tvOS suspend that can follow it read the position
    /// (Retry, `SuspendedContext.resumePosition`) and the message, and the
    /// duration the view model keeps across a failure is re-established by the
    /// next load's adopt before the transport UI comes back. `selections` is
    /// carried because the suspend that can follow *does* consume it (see
    /// `TrackResumeSelections`).
    ///
    /// `identity` is the server session the failed load was bound to. The
    /// terminal path itself deliberately does **not** stop it —
    /// `finalizeTerminalPlaybackError` only drops the view
    /// model's active-session-id mirror and lets the session lapse —
    /// but the bridge is still holding it, and the two things that can happen
    /// *next* on the error screen do reach it: `cleanup()`
    /// stops it whenever the load was not offline, and `retry()`
    /// reports `currentTime` against it before the
    /// replacement session starts. Dropping the identity here made both of
    /// those unrepresentable.
    case failed(
        PlaybackFailure,
        LoadID?,
        identity: SessionIdentity?,
        request: LoadRequest?,
        position: Double,
        selections: TrackResumeSelections
    )
    /// The player was dismissed; nothing may be scheduled any more.
    case disposed

    /// The load the state is currently bound to, if any.
    var loadID: LoadID? {
        switch self {
        case .idle, .suspended, .disposed: return nil
        case .preparing(let preparing): return preparing.loadID
        case .playing(let playing): return playing.loadID
        case .failed(_, let loadID, _, _, _, _): return loadID
        }
    }

    /// The server session the state is currently bound to, if any.
    var identity: SessionIdentity? {
        switch self {
        case .idle, .suspended, .disposed: return nil
        case .preparing(let preparing): return preparing.identity
        case .playing(let playing): return playing.identity
        // The failure did not stop the session; `dismiss` and the retry's
        // progress report still reach it (see `.failed`).
        case .failed(_, _, let identity, _, _, _): return identity
        }
    }
}

/// A load between `beginFreshLoad` and the engine's first `fileLoaded`.
struct Preparing: Equatable {
    enum Phase: Equatable {
        /// `runStartSession` / `OfflinePlaybackBuilder.loadPreparedPlayback`.
        case resolvingSession
        /// The engine load was issued; waiting for `fileLoaded`.
        case startingEngine
    }

    let loadID: LoadID
    /// Known once the session (or the offline stand-in) is prepared.
    var identity: SessionIdentity?
    var phase: Phase
    /// Today's `lastLoadRequest`, and **mutable for the same reason it is a
    /// `var` there**: every adopt rewrites it from the plan the server just
    /// authorised (`adoptProtocolV3RenewalIntent` →
    /// `LoadRequest.adoptingProtocolV3Intent`), and
    /// `attemptProtocolV3Replan` latches the user's quality choice onto it
    /// first, as does `restartCurrentTranscodeHLS`.
    /// Modelling it as a `let` seeded once from the `.load`
    /// intent dropped `preferredProtocolV3SubtitleIndex` and
    /// `preferredQualityOverride` from every replay — `copyForRecovery`
    /// carries both from its *receiver*, and both are wire
    /// arguments to `startSession` (`qualityOverride:`,
    /// `explicitCombinedIndex:`, `resolvedQualityPreference`)
    /// — so a tvOS suspend/resume, a visible renewal, an outage recovery, an
    /// interruption recovery or Retry after a mid-stream quality switch would
    /// have replayed the *old* rung and the *old* subtitle ordinal.
    var request: LoadRequest
    let options: LoadOptions
    let adoption: PlaybackAdoption
    /// Known from `.startingEngine` onwards: resolving a plan runs the route
    /// planner and the V3 adapter, so it arrives *with* the prepared session
    /// rather than in a phase of its own.
    var plan: ExecutionPlanRef?
    /// The transport projections carried across the load.
    ///
    /// `resetPublishedLoadState` deliberately does **not**
    /// clear `currentTime`, `duration` or the buffering flag — it only mirrors
    /// `currentTime` into `scrubPreviewTime` and zeroes
    /// `bufferedAheadSeconds`/`playbackRunwaySeconds` — so a load in flight
    /// still has a playhead and a duration, which is what
    /// `makeSuspendedPlaybackContext` snapshots when tvOS
    /// backgrounds mid-load.
    ///
    /// When the session resolves, `adoptPreparedPlayback` overwrites
    /// `positionSeconds` with `movieTime(for: session)`
    /// and `durationSeconds` with
    /// `session.durationSeconds ?? selectedVersion.duration ?? fallback`
    /// — *before* the engine load — so `fileLoaded` starts the
    /// `Playing` state from the adopted values rather than from zero.
    var transport: TransportState
    /// `activeQualityId`. `resetPublishedLoadState` sets it to
    /// `ApplePlaybackQuality.autoId`; the adopt sets it to
    /// `prepared.activeQualityId` and it then persists for the
    /// whole load.
    var activeQualityId: String?
    /// `activePreparedProtocolV3 != nil` — set at the adopt and
    /// cleared by `resetPublishedLoadState` and
    /// `finalizeTerminalPlaybackError`. See `Playing.hasProtocolV3`
    /// for why the control plane needs the bit.
    var hasProtocolV3: Bool = false
    /// The inputs `copyForRecovery` needs when this load is suspended or
    /// renewed (see `TrackResumeSelections`).
    var resumeSelections: TrackResumeSelections
    /// A `preserveInterruptionState` load keeps the pending tvOS interruption
    /// alive across the reload, so
    /// `completeInterruptionRecoveryIfNeeded` can still clear
    /// it — and the loading overlay — once the replacement stream advances.
    var interruption: Playing.Interruption?
    /// The text of the last engine failure this load reported, for the same
    /// reason `Playing.lastFailureMessage` exists — and it is needed *here*
    /// because an engine that fails before its first frame fails while the
    /// load is still `.preparing`.
    var lastFailureMessage: String?
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
    /// The plan the engine is running. Rewritten in place by a route change
    /// the shell mints (the native-direct -> loopback fallback and the
    /// loopback re-anchor both replace the local execution route without
    /// touching the server session), so the reuse rule and the duration rule
    /// below always read the plan that is actually executing.
    var plan: ExecutionPlanRef
    /// Today's `lastLoadRequest`: the replay intent every recovery path
    /// rebuilds a fresh load from — and, like the view model's, re-adopted at
    /// every server prepare/replan/renewal rather than frozen at `.load`. See
    /// `Preparing.request`.
    var request: LoadRequest
    let adoption: PlaybackAdoption
    var transport: TransportState
    var sub: Sub
    /// The outstanding seek, if any.
    ///
    /// Deliberately a field rather than a `Sub` case (design §2.3 sketched it
    /// as `Sub.seeking`): in the view model `seekOriginTime`/`seekTargetTime`
    /// are independent of `protocolV3ReplanTask`,
    /// the renewal's session-id echo and the EOF latch, so a seek that
    /// arrives while a replan owns the load is performed *and* the replan
    /// still lands. Modelling it as a `Sub` case made the two mutually
    /// exclusive, which dropped whichever arrived second — a user seek during
    /// a quality switch stranded the load behind the loading overlay because
    /// the server's `.replanned` answer no longer matched `.replanning`.
    /// A new `LoadID` still drops it structurally (design §4 I5): the field
    /// lives on `Playing`, and every engine load builds a new one.
    var seek: SeekRequest?
    /// `activeQualityId` — set by the adopt from `prepared.activeQualityId`
    /// and *not* re-derived per publish: a replan that is not a
    /// quality switch must not clear the label the user sees.
    var activeQualityId: String?
    /// `activePreparedProtocolV3 != nil`: whether a *live server V3 plan* owns
    /// this load. Set at the adopt from `prepared.protocolV3 != nil`
    /// and false for offline/legacy loads.
    ///
    /// It is the precondition of both intents that mint a server replan, and
    /// neither is expressible from the rest of the state:
    ///   * `switchQuality` only takes the replan branch when
    ///     `activePreparedProtocolV3 != nil`; without V3 it resolves the id
    ///     differently (`normalizeStoredId`) and runs source-reselection or
    ///     transcode branches that need version and plan knowledge the control
    ///     plane does not hold, so those stay with the shell.
    ///   * the AVAudioSession route observer guards on
    ///     `activePreparedProtocolV3` before it even reads the snapshot.
    /// `SessionIdentity.offline()` publishes `outputContextId: ""`, which no
    /// real snapshot can equal, so without this bit an offline load would
    /// treat every route notification as material and replan a session that
    /// has no server behind it.
    var hasProtocolV3: Bool = false
    /// The live inputs `copyForRecovery` needs (see `TrackResumeSelections`).
    var resumeSelections: TrackResumeSelections
    var interruption: Interruption?
    /// The text of the last engine failure this load reported.
    ///
    /// `RecoveryAction` is frozen and carries only the *classification* on
    /// `.switchRoute(.serverHLS)`, but the rung that decides it
    /// (`RecoveryPolicy.decideEngineFailed`) always has the failure in hand and
    /// the legacy executor passed its text on: `performServerHLSRouteFallback`
    /// → `requestServerHLSReplan(message: failure?.legacyMessage ?? "")`. That
    /// `message` is both the replan's wire `diagnostics["error_cause"]`
    /// (PlaybackSessionBridge) and the wall text when the server answers
    /// `replanUnavailable`, so the reducer keeps the last text rather than
    /// degrading both to a token.
    var lastFailureMessage: String?
}

/// What `LoadRequest.copyForRecovery` is given when a load is
/// suspended for tvOS background (`makeSuspendedPlaybackContext`) or renewed
/// from scratch (`attemptStaleSessionRenewal`). Both sites rebuild the request
/// from the **live** selection,
/// not from the request that started the load, so backgrounding the Apple TV
/// after changing the audio track resumes on that track and a recovery never
/// re-honours a `startFromBeginning: true` against a resume override.
///
/// The reducer cannot compute these — `resolvedAudioTrackIndexForResume()` and
/// friends read the player's live track lists, which the track
/// coordinator owns — so they are carried. They are seeded from the request at
/// `beginLoad` (which is what `resetPublishedLoadState` + those resolvers
/// produce while a load is in flight: the lists are empty, so each resolver
/// falls back to `lastLoadRequest`'s preferred value) and from
/// `prepared.selectedVersion.fileId` at the adopt. **Wave 3 contract:** the
/// shell/track coordinator must keep `audioTrackIndex`, `subtitleTrackIndex`
/// and `sidecarSubtitleTrackId` current as the user changes selection — the
/// `-1` "Off" sentinel included — exactly as the three resolvers do today.
struct TrackResumeSelections: Equatable {
    /// `currentSelectedVersion?.fileId`. Only the *renewal* site prefers it
    /// (`?? lastLoadRequest.preferredFileId`); the suspend site keeps the
    /// request's own `preferredFileId`.
    var selectedFileId: Int?
    /// `resolvedAudioTrackIndexForResume()`.
    var audioTrackIndex: Int?
    /// `resolvedSubtitleTrackIndexForResume()`.
    var subtitleTrackIndex: Int?
    /// `resolvedSidecarSubtitleTrackIdForResume()`.
    var sidecarSubtitleTrackId: Int64?

    init(
        selectedFileId: Int? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        sidecarSubtitleTrackId: Int64? = nil
    ) {
        self.selectedFileId = selectedFileId
        self.audioTrackIndex = audioTrackIndex
        self.subtitleTrackIndex = subtitleTrackIndex
        self.sidecarSubtitleTrackId = sidecarSubtitleTrackId
    }

    /// The seed `resetPublishedLoadState` leaves behind: no live selection, so
    /// every resolver returns the request's preferred value.
    static func seeded(from request: LoadRequest) -> TrackResumeSelections {
        TrackResumeSelections(
            selectedFileId: nil,
            audioTrackIndex: request.preferredAudioTrackIndex,
            subtitleTrackIndex: request.preferredSubtitleTrackIndex,
            sidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId
        )
    }
}

/// What is happening to a live load. Exactly one at a time — the mutually
/// exclusive mode bits the view model kept as separate flags
/// (`protocolV3ReplanTask != nil`, the renewal's session-id echo,
/// `sourceOutageActive`, `hasReachedEndOfFile`) become cases here, which is
/// what makes "no second replan while replanning" structural instead of a
/// guard that two pipelines disagreed about. The seek filter pair is
/// deliberately **not** one of them — see `Playing.seek`.
enum Sub: Equatable {
    case steady
    case recovering(RecoveryStep)
    case replanning(ReplanIntent)
    case renewingSource(SourceRenewal)
    /// The marker only: an origin-outage ride-through owns the load. Its
    /// numbers — the 90 s budget's origin, the probe backoff, the
    /// once-per-outage notice latch — are `RecoveryContext.OutageState`'s,
    /// which is the one thing that writes them.
    case ridingOutOutage
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
    let request: LoadRequest
    let resumePosition: Double
    /// Set when the suspend happened on the error screen.
    /// `suspendForBackground` needs only `lastLoadRequest`, and
    /// `finalizeTerminalPlaybackError` keeps that — so backgrounding the Apple
    /// TV while a failure is on screen suspends *and* leaves `error` set. One
    /// enum case cannot be both `.failed` and `.suspended`, so the failure
    /// travels here and the projection keeps publishing it.
    let failure: PlaybackFailure?
    /// The load whose source proxy the suspend deliberately kept running
    /// (`SourceCacheDisposition.retainProxy`).
    ///
    /// `PlaybackState.loadID` is deliberately `nil` while suspended — no timer,
    /// transport command or report may target a load whose engine is gone — but
    /// the resume still has to stash that proxy's cached prefix and stop it,
    /// which is what `disposeActivePlayerForFreshLoad` did unconditionally at
    /// base. `beginLoad` reads it through `previousEngineLoadID(_:)`.
    let retainedLoadID: LoadID?

    init(
        request: LoadRequest,
        resumePosition: Double,
        failure: PlaybackFailure? = nil,
        retainedLoadID: LoadID? = nil
    ) {
        self.request = request
        self.resumePosition = resumePosition
        self.failure = failure
        self.retainedLoadID = retainedLoadID
    }
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
    /// `AVPlayerBackend.isExternalPlaybackActive` (AirPlay). The iOS
    /// background rule exempts it.
    var isExternalPlaybackActive: Bool = false
    /// `PictureInPictureCoordinator.isEngaged` — `isActive || isTransitioning`
    /// — which is the fact the scene-phase handler reads today, not
    /// the backend's `isPictureInPictureActiveProvider` (plain
    /// `isActive`). `isTransitioning` exists *for this call site*
    /// (`PictureInPictureCoordinator.isTransitioning`): wiring the provider here
    /// would pause playback in the window where iOS auto-starts PiP as the app
    /// is being backgrounded, i.e. on every automatic PiP start on iPhone.
    ///
    /// The third exemption — `isPossible` plus a bounded 1 s grace
    /// (`schedulePictureInPictureBackgroundGrace`) — stays in the iOS shell,
    /// because that grace is a UI timer and is deliberately absent from
    /// `TimerID`. The shell must therefore resolve the grace *before* it
    /// forwards `.scenePhase(.background)` to the control plane.
    var isPictureInPictureEngaged: Bool = false
}

// MARK: - Load inputs

/// Where a load came from. It determines (a) whether the session start is
/// bounded by a timeout and (b) how a load failure is surfaced to the user.
/// Wave 1E declared it here because `PlayerViewModel.LoadOrigin` was `private`
/// and therefore unreachable; wave 3 deleted that copy, so this is the only one.
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
    /// `preserveInterruptionState` — keeps the tvOS interruption alive across
    /// the load: the pending `Playing.Interruption` rides on
    /// `Preparing.interruption` and is restored into `Playing` when the
    /// replacement engine reports `fileLoaded`, so
    /// `completeInterruptionRecoveryIfNeeded` can still complete it. The
    /// interruption-recovery timer is likewise not cancelled.
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
/// `PlaybackAdoptionOrigin` the control plane decides with —
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
        ///
        /// Its prologue reports progress against the outgoing session,
        /// which the reducer emits. Two further obligations
        /// are wave 3's, because they happen outside the request:
        /// the outgoing engine is disposed — implied here by
        /// `reuseEngine == false`, which `.replanned` always computes for this
        /// kind — and a quality restart raises the loading overlay and clears
        /// the buffering flag at the *adopt*, i.e. from the
        /// `.replanned` arm rather than from `requestReplan`.
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
///
/// The sub-state is the *structural* half of the single-flight the two
/// `*SessionId` echoes provided: at reduce time it refuses a second renewal, or
/// one that would overwrite an in-flight replan. The decide-time half is
/// `RecoveryContext.backgroundRenewalInFlight`; the two windows are disjoint.
struct SourceRenewal: Equatable {
    let reason: String
    let observedPosition: Double
    let startedAt: Date
    /// The session the renewal was issued against. A renewal mints a *new*
    /// server session by definition, so `belongsToSameSession` cannot guard its
    /// answer; the active session id is re-checked against the stale one before
    /// the answer is adopted, and this is that check's data.
    let issuedFor: SessionIdentity
}

// MARK: - Seeking

struct SeekRequest: Equatable {
    /// The pre-seek position (`seekOriginTime`) — the filter needs it to tell
    /// a stale drainage frame from a landed one.
    let fromSeconds: Double
    /// `seekTargetTime`.
    let targetSeconds: Double
    let origin: SeekOrigin
}

enum SeekOrigin: Equatable {
    /// Every ordinary seek — the scrubber, skip, a chapter/intro/credits jump.
    /// The reducer treats them identically; only the two below behave
    /// differently, so only they are cases.
    case user
    /// Leaving the terminal postroll (`keepWatchingCurrentEpisode`): it is one
    /// of the two origins allowed to clear the EOF latch.
    case nextUpKeepWatching
    /// A stream rebuild anchored at a new position: `beginReanchorSeekUI`
    /// arms the origin/target filter, moves the scrubber and
    /// cancels the 5 s safety timeout — and issues **no** engine seek. The
    /// anchoring is done by the rebuild that follows it (a `seek_reanchor` V3
    /// replan, a fresh load, or a re-anchored loopback `loadStream`), which is
    /// also what raises the loading overlay and clears the buffering flag.
    ///
    /// **Wave-3 obligation:** the rebuild is *not* modelled by this reducer —
    /// `commitSeek`'s first branch (`reloadServerBackedHLSForSeek`,
    /// `reloadLocalLoopbackForSeekBeforeAnchor`) chooses it before either
    /// `.seek` path below. Wiring a plain
    /// `.seek` intent straight through would regress seeking past the anchor
    /// on remux/transcode HLS and on loopback, and the loopback re-anchor is
    /// the one path where nothing else raises the overlay.
    case reanchor
}

/// Which platform's scene-phase table applies.
///
/// The three tables in `handleScenePhase` differ per platform
/// and are the riskiest surface in this package, but `SiloTests` is an
/// iOS-only bundle (`project.yml` `SiloTests: platform: iOS`), so an
/// `#if os(tvOS)` assertion in a test never executes. The platform is
/// therefore a *parameter* of the reducer's scene-phase rule and `#if os`
/// appears exactly once, in `ScenePhasePlatform.current`, so all three tables
/// are exercised from the iOS bundle.
enum ScenePhasePlatform: Equatable, CaseIterable {
    case iOS
    case tvOS
    case macOS

    static var current: ScenePhasePlatform {
        #if os(tvOS)
        return .tvOS
        #elseif os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

// MARK: - Intents

/// What the view (or the platform) asks for. The reducer is the only place
/// these turn into effects.
enum PlayerIntent: Equatable {
    case load(LoadRequest, origin: LoadOrigin, options: LoadOptions)
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
    /// **Movie time.** `PlaybackEngineSession` converts the backend's player
    /// clock once, on the way out (see its `mediaTimelineOffsetSeconds`), so
    /// the playhead the reducer stores, the seek targets it compares against
    /// and the position `Effect.reportProgress` puts on the wire are all on
    /// one axis.
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
    /// A `RecoveryAction` the load's `RecoveryDriver` decided whose execution
    /// belongs to the shell, not to the engine (wave 2b). The engine session
    /// performs the in-route arms itself and forwards these on the same stream
    /// so a superseded load's decision dies with its session — it is the reason
    /// the shell no longer needs a generation guard around its ladders.
    /// Wave 3 delivers it to the actor as `PlayerEvent.recovery` instead.
    case recoveryAction(RecoveryAction)
}

/// `PlaybackSessionBridge` → control plane. The `ExecutablePlan` travels with
/// the prepared session because resolving it runs the route planner and the V3
/// adapter (`makeExecutionPlan`), which is not reducer work.
enum SessionEvent: Equatable {
    /// Carries the `LoadID` it answers: a fresh prepare mints a brand-new
    /// `SessionIdentity`, so there is nothing else to match it against.
    case prepared(PreparedPlaybackRef, ExecutionPlanRef, for: LoadID)
    /// Matched on the session it replaced (`SessionIdentity` keeps the server
    /// session and playback attempt across a replan; only the plan attempt
    /// changes).
    case replanned(PreparedPlaybackRef, ExecutionPlanRef)
    /// The server declined to replace the plan in place (`replan` → `nil`).
    case replanUnavailable
    case terminal(PlaybackV3TerminalFailure)
    /// `replacing` is the session the renewal was issued against, so the
    /// reducer can refuse an answer to a renewal that is no longer the one in
    /// flight — the only mutation that rewrites `Playing.identity`, and the
    /// one the active-versus-stale session-id guard exists for.
    case renewed(PreparedPlaybackRef, replacing: SessionIdentity)
    case renewalFailed
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
    case startSession(LoadRequest, LoadOptions, LoadID)
    case stopSession(SessionIdentity, position: Double?, isPaused: Bool)
    /// `reuseEngine == true` is today's `prepareBackend(for:)` path: the live
    /// `AVPlayerBackend` survives, its callbacks re-bind to the new `LoadID`.
    case loadEngine(ExecutionPlanRef, LoadID, reuseEngine: Bool)
    /// Tear the load's engine down. `sourceCache` is what the outgoing source
    /// proxy's cached prefix is worth to whatever comes next — the four
    /// dispose sites disagree about it today and the effect has to carry the
    /// disagreement, not average it (see `SourceCacheDisposition`).
    case disposeEngine(LoadID, sourceCache: SourceCacheDisposition)
    case seek(SeekRequest, LoadID)
    /// `replanProtocolV3` → `.session(.replanned | .replanUnavailable | .terminal)`.
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
    /// `sessionBridge.syncProgress(contentId:position:duration:forceOverwrite:)`
    /// — the content-scoped progress write, not the session heartbeat.
    ///
    /// One emitter: `attemptStaleSessionRenewal` force-writes
    /// the resume position against the *content* before it re-loads, because
    /// the session it would otherwise report against is the one that vanished.
    /// The `LoadID` is the outgoing load's, so the actor can drop a write whose
    /// load was superseded; the actor must complete it **before** running the
    /// `.startSession` that follows it in the same effect list, which is the
    /// `await` ordering inside `staleSessionRecoveryTask`.
    case syncProgress(
        contentId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool,
        LoadID
    )
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

/// What an engine teardown does with the outgoing `PlaybackSourceProxy`'s
/// cached prefix (`SourceCacheHandoff`). The handoff lives for
/// exactly one load attempt and `SourceCacheAdoptionPolicy` decides whether
/// the next proxy may adopt it, so the *only* thing a dispose site chooses is
/// whether to offer it at all — and the sites genuinely disagree.
enum SourceCacheDisposition: Equatable {
    /// `stashSourceCacheHandoff()` immediately before `sourceProxy.stop()`:
    /// keep the prefix for a same-file successor. Both halves of a fresh load
    /// (`resetPublishedLoadState`, `loadStream`) and every
    /// server-outage recovery whose reason is *not* `source_entity_changed`.
    case stash
    /// `discardSourceCacheHandoff()`: the prefix must not be adopted.
    /// `finalizeTerminalPlaybackError`, `cleanup()`, and
    /// a `source_entity_changed` outage recovery, where the
    /// validator proved the cached bytes belong to the *replaced* entity —
    /// adopting them would serve the old file's prefix under the new one.
    case discard
    /// The engine goes, the proxy stays: `suspendForBackground`
    /// calls `avPlayerBackend?.dispose()` and deliberately never touches
    /// `sourceProxy`, so the tvOS background suspend keeps the live proxy —
    /// and its cache — and the resume's own `beginLoad` is what finally stashes
    /// and stops it. Wave 3's `PlaybackEngineSession` owns both halves, so this
    /// case is what stops it tearing the proxy down on every Apple TV suspend.
    case retainProxy
}

// MARK: - Presentation

/// The stored projections the control plane owns. View-local state
/// (showControls, scrubbing, hold-seek, HUD, next-up, notices, sleep timer)
/// stays view-model-owned, so it is deliberately absent here.
struct Presentation: Equatable {
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    /// `nil` means "leave the shell's overlay where it is" — a publish whose
    /// arm owns no overlay decision (the pause change) must not clear or raise
    /// it. `false` clears, `true` raises, exactly as before.
    var isLoading: Bool? = false
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
    /// Why the loading overlay is being taken down, so `clearLoadingOverlay`'s
    /// `[CMP] playback loading overlay dismissed reason=…` breadcrumb keeps its
    /// wording. The reason is a property of the *transition*, not of the state,
    /// which is why it rides the publish rather than sitting on `Playing`.
    var loadingReason: String = ""
    /// Why the buffering capsule flipped, for `setBuffering`'s
    /// `[CMP] playback buffering=…` breadcrumb. Only the control-plane-driven
    /// flips travel here ("replan", "quality_switch", "end_of_file",
    /// "background_suspend", "restart"); the engine's own edges are named by
    /// the shell where they arrive.
    var bufferingCause: String = ""
    /// `Sub.ended` — the postroll latch every transport command guards on. It
    /// replaces the view model's `hasReachedEndOfFile` field.
    var hasEnded: Bool = false
    /// `PlaybackState.suspended` — the tvOS wake screen and the ~20 command
    /// guards that read `isBackgroundSuspended`.
    var isBackgroundSuspended: Bool = false
    /// `SessionIdentity.serverSessionId`, the one mirror the shell still needs:
    /// the SiloControl wire projection and the subtitle-AI live gate both
    /// report it. It replaces the view model's active-session-id mirror.
    var serverSessionId: String?
    /// A pending tvOS interruption's recovery deadline, when one is still
    /// eligible for automatic recovery. `RecoveryContext` reads only "is there
    /// still time", and the shell owes that answer synchronously to
    /// `RecoveryPolicy` — so the deadline is projected rather than the whole
    /// `Playing.Interruption`.
    var interruptionRecoveryDeadline: Date?

    init(
        isPlaying: Bool = false,
        currentTime: Double = 0,
        duration: Double = 0,
        isLoading: Bool? = false,
        isBuffering: Bool = false,
        error: String? = nil,
        isReconnecting: Bool = false,
        activeQualityId: String? = nil,
        isQualitySwitching: Bool = false,
        bufferedAheadSeconds: Double = 0,
        playbackRunwaySeconds: Double = 0,
        loadingReason: String = "",
        bufferingCause: String = "",
        hasEnded: Bool = false,
        isBackgroundSuspended: Bool = false,
        serverSessionId: String? = nil,
        interruptionRecoveryDeadline: Date? = nil
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
        self.loadingReason = loadingReason
        self.bufferingCause = bufferingCause
        self.hasEnded = hasEnded
        self.isBackgroundSuspended = isBackgroundSuspended
        self.serverSessionId = serverSessionId
        self.interruptionRecoveryDeadline = interruptionRecoveryDeadline
    }
}

// MARK: - Boxed payloads

/// The execution plan the control plane carries, by reference.
///
/// `PlaybackExecutionPlan` is the artefact the engine install executes: the
/// source proxy rewrites its URLs and the loopback session spec travels on it,
/// so the control plane must carry the whole thing rather than a projection of
/// it — a projection is what left the shell holding the real plan in a side
/// slot. It bundles server response models and a `LoopbackSessionSpec` with no
/// `Equatable` conformance, so — exactly like `PreparedPlaybackRef` below — it
/// is compared by the facts the control plane decides with: the route, the
/// delivery, where the plan starts and what it points at.
struct ExecutionPlanRef: Equatable {
    let value: PlaybackExecutionPlan

    init(_ value: PlaybackExecutionPlan) {
        self.value = value
    }

    /// The implementation route, which is what the reuse rule compares.
    var engine: PlaybackEngineKind { value.engine }
    /// The delivery strategy, which is what the duration rule reads: a
    /// growing transcode playlist reports a manifest length shorter than the
    /// real one, so its duration is never adopted.
    var delivery: PlaybackDeliveryStrategy { value.delivery }

    static func == (lhs: ExecutionPlanRef, rhs: ExecutionPlanRef) -> Bool {
        lhs.value.engine == rhs.value.engine
            && lhs.value.delivery == rhs.value.delivery
            && lhs.value.startMode == rhs.value.startMode
            && lhs.value.streamRequest.url == rhs.value.streamRequest.url
            && lhs.value.loopbackSession?.sourceStartTimeSeconds
                == rhs.value.loopbackSession?.sourceStartTimeSeconds
    }
}

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
// `LoadRequest`'s hand-written `Equatable` moved with the type to
// `ControlPlane/LoadRequest.swift` in wave 3.
