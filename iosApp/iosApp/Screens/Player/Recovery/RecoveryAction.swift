//
//  RecoveryAction.swift
//
//  The output alphabet of the single recovery owner, `RecoveryPolicy`.
//
//  One case per thing a recovery rung does. `PlaybackEngineSession.perform`
//  routes them: the engine-level arms run on `AVPlayerBackend.perform(_:)`, the
//  session- and transport-level arms ride the event stream to `PlayerViewModel`.
//  Nothing carries a closure, a task or a player reference, so the whole ladder
//  is comparable in a test.
//
//  Anchors (`atMediaSeconds`) are on the **media** timeline. Observations are
//  sampled on the player timeline, and `RecoveryContext.mediaSeconds(forPlayerSeconds:)`
//  — `AVPlayerBackend.mediaTime(for:)` verbatim — converts. The two sinks that
//  want a player-timeline value (`AVPlayerBackend.reloadEstablishedLoopbackItem`,
//  `AVPlayerBackend.performRecoverySeek`) get it back through the exact inverse,
//  `AVPlayerBackend.playerTime(forMediaTime:)`; both clamp at zero, so the round
//  trip is exact for every anchor the policy can emit.
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
        /// `PlayerViewModel.attemptNativeDirectRouteRecovery`: hand the failed
        /// native-direct source to the local loopback remuxer. The execution
        /// plan is built by the engine session (`makeLoopbackFallbackPlan`), not
        /// carried here — `PlaybackExecutionPlan` is not usefully `Equatable`
        /// and the plan depends on live state the policy does not own.
        case loopbackFallback
        /// `PlayerViewModel.requestServerHLSRouteFallback`: ask the server to
        /// replan onto a server-produced HLS rendition. The classification is
        /// the wire token the call sites pass — `"silo_loopback_failed"` from
        /// the loopback rung, `"native_direct_avplayer_failed"` when the
        /// loopback fallback plan could not be built.
        case serverHLS(classification: String)
    }

    /// Why a reanchor, an in-place item reload or a full session rebuild was
    /// ordered. The engine picks its recipe off the case; `token` is the
    /// log/seek string the rung printed, reproduced verbatim so a console
    /// capture reads exactly as it did before.
    enum Cause: Equatable {
        /// `.AVPlayerItemPlaybackStalled`.
        case stall
        /// The edge watchdog: the local playlist advanced while AVFoundation's
        /// loaded range did not.
        case edgeWatchdog
        /// The "Playlist File unchanged" / `-12888` tail of a failed-to-end
        /// notification, with the user playing.
        case playlistUnchanged
        /// The playhead watchdog's first attempt, and the expired interactive
        /// seek deadline: an authoritative producer restart, then a nudge seek
        /// and `play()` — never a reload.
        case vodStallNudge
        /// The playhead watchdog's second and later attempts: an authoritative
        /// producer restart, then an in-place item reload.
        case vodStall
        /// The item-death rung's reload. `trigger` names the evidence source
        /// (`error_log`, `failed_to_end`, `unexpected_pause`) and `attempt` the
        /// reload number; the decision log line reads both straight off this
        /// payload.
        case itemDeath(trigger: String, attempt: Int)
        /// Item death confirmed again at the same position: the reload budget is
        /// spent, so the rung escalates to a full rebuild.
        case itemDeathRepeated
        /// A producer-dead stall — AVPlayer waiting on an empty buffer while the
        /// store served nothing.
        case starvation
        /// The playhead watchdog spent its reanchor budget inside the rolling
        /// window.
        case playheadWatchdogExhausted

        /// The log/seek token, verbatim.
        var token: String {
            switch self {
            case .stall: return "stall"
            case .edgeWatchdog: return "edge_watchdog"
            case .playlistUnchanged: return "playlist_unchanged"
            case .vodStallNudge: return "vod_stall_nudge"
            case .vodStall: return "vod_stall"
            case let .itemDeath(trigger, attempt): return "item_death_\(trigger)_\(attempt)"
            case .itemDeathRepeated: return "loopback_item_death"
            case .starvation: return "loopback_starvation"
            case .playheadWatchdogExhausted: return "playhead_watchdog"
            }
        }
    }

    /// Bare `avPlayer.play()`. The item-death confirmation state's
    /// `.reassertPlay`: AVPlayer parked at rate 0 with media available, which is
    /// a candidate for a dead item, not a user pause.
    case reassertPlay
    /// Startup ladder stage 1 — `AVPlayerBackend.nudgeLoopbackStartupConsumer`:
    /// a zero-tolerance seek to the startup target that forces AVFoundation to
    /// rebuild its item loader.
    case nudgeStartup
    /// Startup ladder stage 2 — `AVPlayerBackend.reloadLoopbackStartupItem`: a
    /// fresh `AVPlayerItem` on the same loopback URL.
    case reloadStartupItem
    /// Reanchor the loopback session at `atMediaSeconds`.
    ///
    /// Two sinks, distinguished by `cause`:
    /// * `.stall` / `.edgeWatchdog` / `.playlistUnchanged` —
    ///   `AVPlayerBackend.performLoopbackReanchor`: flush the subtitle session,
    ///   seek the extractor, then `load(.siloLoopback(spec.reanchored(at:)))`.
    /// * `.vodStallNudge` — `AVPlayerBackend.performVODStallRecovery(attempt: 1, …)`:
    ///   `LocalHLSHost.requestProducerRestart(atSegmentIndex:authoritative:)`
    ///   with `authoritative: true` **first**, then `cancelPendingSeeks()`, a
    ///   recovery seek to the anchor, and `play()`. The producer restart is part
    ///   of executing this action, not a separate action: the policy issues one
    ///   decision per observation and the engine performs the recipe that
    ///   decision names.
    case reanchor(atMediaSeconds: Double, cause: Cause)
    /// Rebuild AVFoundation's item on the same loopback session
    /// (`AVPlayerBackend.reloadEstablishedLoopbackItem`), preserving producer,
    /// plan, store, server, display criteria, audio session and budgets.
    ///
    /// `.vodStall` is the playhead watchdog's second and later attempts (which,
    /// like `.reanchor`, first issue an authoritative producer restart —
    /// `performVODStallRecovery` restarts on every attempt); `.itemDeath`
    /// carries the item-death rung's trigger and attempt number.
    case reloadItem(atMediaSeconds: Double, cause: Cause)
    /// `AVPlayerBackend.performLoopbackReanchor(…, rebuilding: true)` — recreate
    /// the whole local pipeline at the rendered clock. It differs from
    /// `.reanchor` in which budget the policy spends to get here, in logging at
    /// error level, and in proceeding without a live `AVPlayerItem` (the rung
    /// exists for a dead one). Budgeted: the policy only emits this after
    /// `LoopbackRebuildBudget.consume()` succeeded.
    case rebuildLocalSession(atMediaSeconds: Double, cause: Cause)
    /// The "Playlist File unchanged" rung while the user is paused: latch the
    /// media time and recover when playback is resumed
    /// (`AVPlayerBackend.deferredRecoveryMediaTime`, consumed by `play()`).
    case deferUntilPlay(mediaSeconds: Double)
    /// The auto-resume rung — `resumeLocalLoopbackPlaybackIfNeeded`'s
    /// `avPlayer.play()`.
    case resumePlayback
    /// `PlayerViewModel.handlePlaybackError`'s near-end rung: treat the failure
    /// as the stream draining and run `handleEndOfFile()`.
    case treatAsNaturalEnd
    /// `PlayerViewModel.attemptProtocolV3Replan` — the online delivery/fallback
    /// owner.
    case requestServerReplan(classification: String, message: String)
    /// The offline-only route fallbacks.
    case switchRoute(RouteFallback)
    /// `PlayerViewModel.attemptBackgroundSessionRenewal` — silent renewal that
    /// retargets the source proxy's origin and leaves the player untouched.
    case renewSourceInBackground(reason: String)
    /// `PlayerViewModel.attemptStaleSessionRenewal` — the visible renewal that
    /// re-runs the load.
    case renewSessionFresh(reason: String)
    /// Start (or continue) riding the buffered runway through an origin outage.
    ///
    /// One contract, both on entry and on every continuation: **sleep
    /// `probeAfter`, then issue one `/api/v1/health` probe and report it back
    /// as `.serverHealthProbe(ok:)`**. Entry emits `probeAfter: 0` because the
    /// ride-through loop probes before its first sleep; the delays that come
    /// back from each probe are 1, 2, 4, 8, 8, …, so the full emitted sequence
    /// 0, 1, 2, 4, 8, 8 reproduces the probe times t = 0, 1, 3, 7, 15, 23, ….
    case rideThroughOutage(probeAfter: Duration)
    /// The ride-through ended: clear the state and run the post-outage playback
    /// kick (`AVPlayerBackend.kickPlaybackAfterOutage`).
    case endOutageRideThrough
    /// `PlayerViewModel.attemptServerOutageRecovery(reason:observedPosition:)` —
    /// the visible recovery: tear the proxy and backend down, show
    /// "Reconnecting", wait for the server, then reload.
    ///
    /// `reason` is the token form of `PlaybackSourceInterruptionReason`;
    /// `"source_entity_changed"` is the discriminator the cache-handoff branch
    /// needs (`discardSourceCacheHandoff()` instead of
    /// `stashSourceCacheHandoff()`).
    case recoverFromServerOutage(reason: String)
    /// `PlayerViewModel.waitForServerReady`'s next iteration, on the same
    /// contract as `.rideThroughOutage`: sleep `probeAfter`, then probe and
    /// report `.serverHealthProbe(ok:)`. There is no `probeAfter: 0` entry here
    /// because that loop's first probe is issued by the tail of
    /// `.recoverFromServerOutage`, so the first delay this case carries is
    /// already the loop's first sleep.
    case waitForServerReady(probeAfter: Duration)
    /// `PlayerViewModel.triggerAutomaticInterruptionRecovery()`.
    case autoRecoverInterruption
    /// Terminal: the shell publishes the failure's legacy message.
    case fail(PlaybackFailure)
}
