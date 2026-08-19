//
//  RecoveryAction.swift
//
//  Stage 2 — the output alphabet of the single recovery owner.
//
//  One case per thing a recovery rung does today. The engine session (wave 2)
//  and the session actor (wave 3) only *execute* these; they never decide.
//  Nothing carries a closure, a task or a player reference, so the whole ladder
//  is comparable in a test.
//
//  Anchors (`atMediaSeconds`) are on the **media** timeline. Observations are
//  sampled on the player timeline, and `RecoveryContext.mediaSeconds(forPlayerSeconds:)`
//  — `AVPlayerBackend.mediaTime(for:)` verbatim — converts. The two sinks that
//  want a player-timeline value (`reloadEstablishedLoopbackItem`,
//  `performRecoverySeek`) get it back through the exact inverse,
//  `playerTime(forMediaTime:)`; both clamp at zero, so the round trip is exact
//  for every anchor the policy can emit.
//

import Foundation

/// What the recovery owner decided to do. `nil` (no action) is the common case:
/// an observation that does not qualify, or one that only advances the
/// context's bookkeeping.
enum RecoveryAction: Equatable {

    /// The offline-only route fallbacks. Both rungs are unreachable while
    /// Protocol V3 is active — the server owns delivery through a replan — so
    /// these fire only on an offline/legacy start.
    enum RouteFallback: Equatable {
        /// `attemptNativeDirectRouteRecovery`: hand the failed native-direct
        /// source to the local loopback remuxer. The execution plan is built by
        /// the engine session (`makeLoopbackFallbackPlan`), not carried here —
        /// `PlaybackExecutionPlan` is not usefully `Equatable` and the plan
        /// depends on live state the policy does not own.
        case loopbackFallback
        /// `requestServerHLSRouteFallback`: ask the server to replan onto a
        /// server-produced HLS rendition. The classification is the wire token
        /// the legacy call sites pass — `"silo_loopback_failed"` from the
        /// loopback rung, `"native_direct_avplayer_failed"` when the loopback
        /// fallback plan could not be built.
        case serverHLS(classification: String)
    }

    /// Bare `avPlayer.play()`. The item-death confirmation state's
    /// `.reassertPlay`: AVPlayer parked at rate 0 with media available, which is
    /// a candidate for a dead item, not a user pause.
    case reassertPlay
    /// Startup ladder stage 1 — `nudgeLoopbackStartupConsumer()`: a
    /// zero-tolerance seek to the startup target that forces AVFoundation to
    /// rebuild its item loader.
    case nudgeStartup
    /// Startup ladder stage 2 — `reloadLoopbackStartupItem()`: a fresh
    /// `AVPlayerItem` on the same loopback URL.
    case reloadStartupItem
    /// Reanchor the loopback session at `atMediaSeconds`.
    ///
    /// Two legacy sinks, distinguished by `reason`:
    /// * `"stall"` / `"edge_watchdog"` / `"playlist_unchanged"` —
    ///   `recoverLocalLoopbackStallIfNeeded`: flush the subtitle session, seek
    ///   the extractor, then `load(.siloLoopback(spec.reanchored(at:)))`.
    /// * `"vod_stall_nudge"` — `performVODStallRecovery(attempt: 1, …)`:
    ///   `requestVODProducerRestart(at:authoritative: true)` **first**, then
    ///   `cancelPendingSeeks()`, a recovery seek to the anchor, and `play()`.
    ///   The producer restart is part of executing this action, not a separate
    ///   action: the policy issues one decision per observation and the engine
    ///   performs the recipe that decision names, exactly as
    ///   `performVODStallRecovery` does today.
    case reanchor(atMediaSeconds: Double, reason: String)
    /// Rebuild AVFoundation's item on the same loopback session
    /// (`reloadEstablishedLoopbackItem`), preserving producer, plan, store,
    /// server, display criteria, audio session and budgets.
    ///
    /// `reason` is the legacy log/seek token: `"vod_stall"` from the playhead
    /// watchdog's second and later attempts (which, like `.reanchor`, first
    /// issue an authoritative producer restart — `performVODStallRecovery`
    /// B:1917 restarts on every attempt), or
    /// `"item_death_<trigger>_<attempt>"` from the item-death rung.
    case reloadItem(atMediaSeconds: Double, reason: String)
    /// `requestVODProducerRestart(at:authoritative:)` on its own.
    case restartProducer(atSegmentIndex: Int, authoritative: Bool)
    /// `rebuildSiloLoopbackSession(at:reason:)` — recreate the whole local
    /// pipeline at the rendered clock. Budgeted: the policy only emits this
    /// after `LoopbackRebuildBudget.consume()` succeeded.
    case rebuildLocalSession(atMediaSeconds: Double, reason: String)
    /// The "Playlist File unchanged" rung while the user is paused: latch the
    /// media time and recover when playback is resumed
    /// (`pendingLocalLoopbackRecoveryMediaTime`, consumed by `play()`).
    case deferUntilPlay(mediaSeconds: Double)
    /// The auto-resume rung — `resumeLocalLoopbackPlaybackIfNeeded`'s
    /// `avPlayer.play()`.
    case resumePlayback
    /// `handlePlaybackError`'s near-end rung: treat the failure as the stream
    /// draining and run `handleEndOfFile()`.
    case treatAsNaturalEnd
    /// `attemptProtocolV3Replan` — the online delivery/fallback owner.
    case requestServerReplan(classification: String, message: String)
    /// The offline-only route fallbacks.
    case switchRoute(RouteFallback)
    /// `attemptBackgroundSessionRenewal` — silent renewal that retargets the
    /// source proxy's origin and leaves the player untouched.
    case renewSourceInBackground(reason: String)
    /// `attemptStaleSessionRenewal` — the visible renewal that re-runs the load.
    case renewSessionFresh(reason: String)
    /// `handleOriginOutageChanged(true)` — start (or continue) riding the
    /// buffered runway.
    ///
    /// One contract, both on entry and on every continuation: **sleep
    /// `probeAfter`, then issue one `/api/v1/health` probe and report it back
    /// as `.serverHealthProbe(ok:)`**. Entry emits `probeAfter: 0` because the
    /// legacy loop probes before its first sleep (PVM:4299-4310); the delays
    /// that come back from each probe are 1, 2, 4, 8, 8, …, so the full emitted
    /// sequence 0, 1, 2, 4, 8, 8 reproduces the legacy probe times
    /// t = 0, 1, 3, 7, 15, 23, ….
    case rideThroughOutage(probeAfter: Duration)
    /// `handleOriginOutageChanged(false)` — `clearSourceOutageRideThroughState()`
    /// and, when `kick` is set, `kickPlaybackAfterExternalStallCleared()`.
    case endOutageRideThrough(kick: Bool)
    /// `attemptServerOutageRecovery(reason:observedPosition:)` — the visible
    /// recovery: tear the proxy and backend down, show "Reconnecting", wait for
    /// the server, then reload.
    ///
    /// `reason` is the token form of `PlaybackSourceInterruptionReason`;
    /// `"source_entity_changed"` is the discriminator the cache-handoff branch
    /// needs (`discardSourceCacheHandoff()` instead of
    /// `stashSourceCacheHandoff()`).
    case recoverFromServerOutage(reason: String)
    /// `waitForServerReady`'s next iteration, on the same contract as
    /// `.rideThroughOutage`: sleep `probeAfter`, then probe and report
    /// `.serverHealthProbe(ok:)`. There is no `probeAfter: 0` entry here
    /// because `waitForServerReady`'s first probe is issued by the tail of
    /// `.recoverFromServerOutage` (PVM:4494-4504), so the first delay this case
    /// carries is already the legacy loop's first sleep.
    case waitForServerReady(probeAfter: Duration)
    /// `triggerAutomaticInterruptionRecovery()`.
    case autoRecoverInterruption
    /// Terminal. `finalizeTerminalPlaybackError(failure.legacyMessage)`.
    case fail(PlaybackFailure)
}
