//
//  RecoveryObservation.swift
//
//  The input alphabet of the single recovery owner, `RecoveryPolicy`.
//
//  Nine ladders used to both *observe* and *decide*: six inside
//  `AVPlayerBackend` (startup watchdog, playhead watchdog, item-death evidence,
//  edge watchdog, `.PlaybackStalled`, "Playlist File unchanged") and three
//  inside `PlayerViewModel` (`handlePlaybackError`, the origin-outage
//  ride-through, the two session renewals). Those halves are split: the
//  observation sites keep their timers, notifications and KVO and emit one of
//  these cases; every decision is `RecoveryPolicy.decide`'s.
//

import Foundation

/// One transport sample, as the playhead watchdog's 1 Hz tick reads it
/// (`AVPlayerBackend.loopbackPlayheadWatchdogTick`).
///
/// `position` is on the **player** timeline — what `AVPlayerBackend.currentTime()`
/// returns — because every threshold in the watchdog is expressed against it
/// (the shared reanchor rung's `playerSeconds < 10` arm, and `generatedAhead`,
/// which is measured from the local playlist's visible end, itself a player-axis
/// value). `RecoveryContext.mediaTimelineOffset` converts it to the media axis
/// the actions' anchors carry.
struct PlayheadSample: Equatable {
    /// How AVPlayer reports its transport. Mirrors `AVPlayer.timeControlStatus`
    /// without importing AVFoundation into the policy;
    /// `AVPlayerBackend.timeControl(for:)` is the one mapping. The raw value is
    /// the `tc=` log token, so every line that prints transport state prints the
    /// same vocabulary.
    enum TimeControl: String, Equatable {
        case paused
        case waiting
        case playing
        case unknown
    }

    /// Player-timeline position, `AVPlayerBackend.currentTime()`.
    var position: Double
    var timeControl: TimeControl
    /// `playableAheadSeconds(for:referenceTime:)` — buffered runway ahead of
    /// the playhead.
    var bufferedAhead: Double
    /// `latestLoopbackGeneratedStats.playlistVisibleEndSeconds` (or the store's
    /// `generatedMediaSeconds`) minus the position, clamped at zero.
    var generatedAhead: Double
    /// `LoopbackSegmentStore.secondsSinceLastSegmentServe()`; `.infinity` when
    /// there is no store (the backend's `?? .infinity`).
    var secondsSinceLastServe: Double
    /// `AVPlayerBackend.isUserPaused` — the explicit play-intent latch, not
    /// `rate == 0`.
    var userPaused: Bool
    /// `didFireFileLoaded`. Startup rungs run while this is false, the playhead
    /// rungs only once it is true.
    var playbackEstablished: Bool
    /// `AVPlayerBackend.vodPendingSeekMediaTarget` — the **media**-timeline
    /// target of a loopback seek that has been issued but has not landed.
    ///
    /// The wedge rung anchors on it in preference to `position`
    /// (`AVPlayerBackend.performVODStallRecovery`): a wedged zero-tolerance seek
    /// leaves the frozen clock at the PRE-seek position, so recovering at
    /// `position` would silently discard the user's seek. It is usually nil at
    /// tick time — the tick's own `!isSeekPending` guard plus the backend's
    /// clear-sites see to that — but it is reachable in the main-queue window
    /// between `handleSeekDeadline`'s `markSeekSettled()` and the `Task` that
    /// re-latches and consumes it, which is exactly the case the preference
    /// exists for.
    ///
    /// Only the wedge rung reads it. The shared reanchor rung deliberately does
    /// not: it reads `currentTime()` alone.
    var pendingSeekMediaTarget: Double?

    init(
        position: Double,
        timeControl: TimeControl,
        bufferedAhead: Double,
        generatedAhead: Double,
        secondsSinceLastServe: Double,
        userPaused: Bool,
        playbackEstablished: Bool,
        pendingSeekMediaTarget: Double? = nil
    ) {
        self.position = position
        self.timeControl = timeControl
        self.bufferedAhead = bufferedAhead
        self.generatedAhead = generatedAhead
        self.secondsSinceLastServe = secondsSinceLastServe
        self.userPaused = userPaused
        self.playbackEstablished = playbackEstablished
        self.pendingSeekMediaTarget = pendingSeekMediaTarget
    }
}

/// One edge-watchdog sample, as `AVPlayerBackend.sampleLocalLoopbackEdge`
/// computes it from the 10 Hz time observer and every generated-media stats
/// callback. All seconds are player-timeline.
struct EdgeSample: Equatable {
    /// Reference player time the sample was taken at.
    var referenceTime: Double
    /// End of AVFoundation's loaded range at (or after) `referenceTime`.
    var loadedEnd: Double
    /// `GeneratedMediaStats.playlistVisibleEndSeconds`.
    var playlistEnd: Double
    /// `GeneratedMediaStats.playlistBodyHash` — a body change counts as
    /// playlist advance even when the visible end did not move.
    var playlistHash: UInt64
    /// `loadedEnd - referenceTime`, clamped at zero.
    var loadedAhead: Double
    /// `playlistEnd - referenceTime`, clamped at zero.
    var visibleAhead: Double
    /// `GeneratedMediaStats.targetDuration`, already floored at 1.0 by the
    /// sampler (`max(1.0, Double(targetDuration))`).
    var targetDuration: Double
    /// `GeneratedMediaStats.longestSegmentDuration`.
    var longestSegment: Double

    init(
        referenceTime: Double,
        loadedEnd: Double,
        playlistEnd: Double,
        playlistHash: UInt64,
        loadedAhead: Double,
        visibleAhead: Double,
        targetDuration: Double,
        longestSegment: Double
    ) {
        self.referenceTime = referenceTime
        self.loadedEnd = loadedEnd
        self.playlistEnd = playlistEnd
        self.playlistHash = playlistHash
        self.loadedAhead = loadedAhead
        self.visibleAhead = visibleAhead
        self.targetDuration = targetDuration
        self.longestSegment = longestSegment
    }
}

/// Where the "the server no longer knows this playback session" signal came
/// from. Today the same two renewals are triggered from four sites with a
/// `reason` string; the source is the typed form of that string.
enum SessionMissingSource: Equatable {
    /// `handlePlaybackError` saw `PlaybackFailure.isPlaybackSessionMissing`
    /// (`reason: "player_error"`).
    case playerError
    /// `PlaybackSourceProxy.onPlaybackSessionMissing` (`reason: "source_404"`).
    case proxy404
    /// The 10 s progress heartbeat noticed the session was gone
    /// (`reason: "progress"`).
    case progressHeartbeat
    /// The Protocol V3 replan's `catch` fell through to a visible renewal
    /// (`reason: "protocol_v3_replan_missing_session"`).
    ///
    /// This is the one source that never tries the silent renewal first: the
    /// legacy `catch` calls `attemptStaleSessionRenewal` directly, because once
    /// the server has re-planned "only a full visible renewal can pick up the
    /// new plan", while the silent path keeps the existing plan alive.
    /// `RecoveryPolicy.decideSessionMissing` short-circuits on it for that
    /// reason.
    case replanCatch

    /// The `reason` token the legacy call sites pass, reproduced verbatim so
    /// the renewal log lines and the `"<reason>_bg_renewal_failed"` escalation
    /// token are unchanged.
    var reason: String {
        switch self {
        case .playerError: return "player_error"
        case .proxy404: return "source_404"
        case .progressHeartbeat: return "progress"
        case .replanCatch: return "protocol_v3_replan_missing_session"
        }
    }
}

/// Everything the recovery owner can be told. One case per observation site
/// that today also decides.
enum RecoveryObservation: Equatable {
    // MARK: Backend-originated (loopback route unless noted)

    /// Startup watchdog tick, 1 Hz, pre-`didFireFileLoaded`
    /// (`loopbackStartupWatchdogTick`). `servedRequests` is the local HLS
    /// server's cumulative served-request count; a change since the last tick
    /// is the only evidence of forward progress.
    ///
    /// There is deliberately no `secondsSinceStart` payload: the 60 s absolute
    /// backstop is measured from `RecoveryContext.StartupState.startedAt`
    /// (`loopbackStartupWatchdogStartedAt`) inside the policy, so the tick's
    /// emitter cannot own half of the backstop decision and the two clocks
    /// cannot disagree.
    case startupTick(
        servedRequests: UInt64,
        displayModeSwitchInProgress: Bool
    )
    /// Playhead watchdog tick, 1 Hz, post-`didFireFileLoaded`
    /// (`loopbackPlayheadWatchdogTick`).
    case playheadTick(PlayheadSample)
    /// Evidence that the AVPlayer item died: the item error log, or
    /// `.AVPlayerItemFailedToPlayToEndTime` with an item-death signature.
    /// `weight` is 2 for a `-15628`/failed-to-end signature, 1 otherwise.
    case itemDeathEvidence(
        statusCode: Int?,
        description: String,
        weight: Int,
        position: Double,
        userPaused: Bool
    )
    /// Edge watchdog sample (`sampleLocalLoopbackEdge`).
    case edgeSample(EdgeSample)
    /// `.AVPlayerItemPlaybackStalled`.
    case playbackStalled
    /// `.AVPlayerItemFailedToPlayToEndTime` on the current item.
    ///
    /// This is the **only** thing that arms the item-death confirmation
    /// state's `.failedToEnd` candidate: calls
    /// `LoopbackItemDeathConfirmationState.noteExplicitFailure` and returns for
    /// every such notification on an established loopback item, whatever the
    /// error says. `.itemDeathEvidence` is a different mechanism
    /// (`LoopbackItemDeathRecoveryState.record`, gated on `isItemDeath(…)`,
    /// which this note deliberately is not), so the emitter must not fold the
    /// two together — doing so would replace a 3 s confirmation window with its
    /// 0.5 s position-drift cancellation by an immediate item reload.
    ///
    /// Emitted for every failed-to-end notification. The policy consumes it on
    /// an established loopback item and otherwise returns no action, because
    /// the rest of that notification's tail — the "Playlist File unchanged" /
    /// `-12888` branch of `AVPlayerBackend.itemFailedToEndObserver` — is
    /// reachable only when this arm did **not** consume it, and arrives
    /// classified as `.playlistUnchanged`.
    case itemFailedToEnd(position: Double, userPaused: Bool)
    /// The tail of a `.AVPlayerItemFailedToPlayToEndTime` that the
    /// `.itemFailedToEnd` arm did not consume, whose description carries
    /// "Playlist File unchanged" or "-12888".
    case playlistUnchanged(userPaused: Bool)
    /// `isPlaybackLikelyToKeepUp` / `loadedTimeRanges` KVO — the auto-resume
    /// rung's trigger.
    ///
    /// `likely` is `AVPlayerItem.isPlaybackLikelyToKeepUp` read at the moment
    /// the KVO fired. It is a payload rather than an implication of the case
    /// name because the rung's predicate is
    /// `item.isPlaybackLikelyToKeepUp || bufferedAhead > 0.5` and both
    /// KVOs feed it — without the flag the emitter would have to evaluate half
    /// the rung, which is exactly the split ownership this layer removes.
    case likelyToKeepUp(rate: Double, bufferedAhead: Double, reachedEnd: Bool, likely: Bool)
    /// A user-initiated seek's deadline expired without the seek completing;
    /// `mediaTarget` is the media-timeline target that was requested.
    ///
    /// The backend's other two deadline kinds never cross this boundary: a
    /// recovery seek's follow-up belongs to the rung that issued it, and the
    /// initial resume seek's retry is transport bookkeeping. Both stay inside
    /// `AVPlayerBackend.handleSeekDeadline`.
    case interactiveSeekDeadlineExpired(mediaTarget: Double)
    /// The backend reported a typed failure (any route).
    case engineFailed(PlaybackFailure)

    // MARK: Transport / session

    /// `PlaybackSourceProxy.onOriginOutageChanged`.
    case originOutage(active: Bool)
    /// `PlaybackSourceProxy.onPlaybackSourceInterrupted`.
    case sourceInterrupted(reason: PlaybackSourceInterruptionReason)
    /// The server does not know this playback session any more.
    case sessionMissing(source: SessionMissingSource)
    /// One `/api/v1/health` probe finished. `ok` is the legacy predicate: any
    /// success, plus 401/403 (auth reached ⇒ the server is up).
    case serverHealthProbe(ok: Bool)
    /// The buffered runway ran out while an origin outage is being ridden —
    /// the "Reconnecting" notice's gate. Only the exhausted edge was ever
    /// reported: the notice fires once per outage and the refill edge never
    /// meant anything to the policy.
    case runwayExhaustedDuringOutage
}
