import Foundation

// OWNERSHIP NOTE (wave 1): this file is the deliverable of Stage 2 package
// `s2w1-recovery-policy` (wave 1B), which lands `RecoveryObservation`,
// `RecoveryContext`, `RecoveryPolicy` and this enum together. It is duplicated
// here — same path, same shape as design §2.4 — only because the wave-1E
// control-plane types reference it: `Effect.runRecovery(RecoveryAction, LoadID)`
// and `PlayerEvent.recovery(RecoveryAction, LoadID)` are binding deliverables
// of that package and cannot be declared without it, and the two branches are
// cut from the same base.
//
// MERGE ORDER (binding — an add/add conflict resolved carelessly leaves two
// `enum RecoveryAction` declarations and the build fails on redeclaration):
//   1. merge wave 1B (`stage2/s2w1-recovery-policy`) first;
//   2. merge wave 1E (`stage2/s2w1-reducer-types`) and resolve
//      `iosApp/iosApp/Screens/Player/Recovery/RecoveryAction.swift` in favour
//      of 1B's version — take theirs wholesale, delete this copy;
//   3. verify before building:
//      `grep -rc "enum RecoveryAction" iosApp/iosApp | awk -F: '{n+=$2} END {print n}'`
//      must print 1.
// 1B nests `RouteFallback` inside `RecoveryAction` where this copy declares it
// top-level; `PlaybackReducer` and `PlaybackReducerTests` only ever spell the
// cases with leading-dot syntax, so taking 1B's file compiles unchanged.

/// What a recovery decision asks the rest of the player to do.
///
/// One owner (design §4 I3): `RecoveryPolicy` is the only place that decides,
/// the engine session and the session actor only execute. The engine-scoped
/// cases (`reassertPlay` … `resumePlayback`) are performed inside the engine
/// session; the session-scoped ones re-enter the control plane as reducer
/// transitions.
enum RecoveryAction: Equatable {
    /// Bare `avPlayer.play()`.
    case reassertPlay
    /// Startup ladder, stage `.initial`.
    case nudgeStartup
    /// Startup ladder, stage `.nudged`.
    case reloadStartupItem
    /// `recoverLocalLoopbackStallIfNeeded` / `vod_stall_nudge`.
    case reanchor(atMediaSeconds: Double, reason: String)
    /// `reloadEstablishedLoopbackItem`.
    case reloadItem(atMediaSeconds: Double, reason: String)
    /// `requestVODProducerRestart`.
    case restartProducer(atSegmentIndex: Int, authoritative: Bool)
    /// `rebuildSiloLoopbackSession` (budgeted).
    case rebuildLocalSession(atMediaSeconds: Double, reason: String)
    /// Playlist-unchanged while paused (`pendingLocalLoopbackRecoveryMediaTime`).
    case deferUntilPlay(mediaSeconds: Double)
    /// The auto-resume rung.
    case resumePlayback
    /// The view model's near-end rung: a failure this close to the end reads
    /// as the stream draining, not as an engine defect.
    case treatAsNaturalEnd
    /// The V3 replan rung (also the HLS fallback rungs).
    case requestServerReplan(classification: String, message: String)
    /// The offline-only route-fallback rungs.
    case switchRoute(RouteFallback)
    /// `attemptBackgroundSessionRenewal` — silent, keeps the engine.
    case renewSourceInBackground(reason: String)
    /// `attemptStaleSessionRenewal` — visible, reloads the stream.
    case renewSessionFresh(reason: String)
    /// `handleOriginOutageChanged(true)`.
    case rideThroughOutage(probeAfter: Duration)
    /// `clearSourceOutageRideThroughState` + `kickPlaybackAfterExternalStallCleared`.
    case endOutageRideThrough(kick: Bool)
    /// `attemptServerOutageRecovery`.
    case recoverFromServerOutage(reason: String)
    /// The `waitForServerReady` poll.
    case waitForServerReady(probeAfter: Duration)
    /// `triggerAutomaticInterruptionRecovery` (tvOS transient inactive).
    case autoRecoverInterruption
    /// Terminal.
    case fail(PlaybackFailure)
}

/// The two offline-only route switches the view-model ladder still performs.
/// The fallback plan itself is built by the engine session, so the action
/// stays a value.
enum RouteFallback: Equatable {
    /// Native direct failed → rebuild as a loopback session.
    case loopbackFallback
    /// Loopback failed → ask the server for an HLS plan.
    case serverHLS(classification: String)
}
