//
//  RecoveryObservation.swift
//
//  Stage 2 (control-plane extraction) — the input alphabet of the single
//  recovery owner, `RecoveryPolicy`.
//
//  Today six in-route ladders live inside `AVPlayerBackend` (startup watchdog,
//  playhead watchdog, item-death evidence, edge watchdog, `.PlaybackStalled`,
//  "Playlist File unchanged") and three more live in `PlayerViewModel`
//  (`handlePlaybackError`, the origin-outage ride-through, the two session
//  renewals). Each one both *observes* and *decides*. Stage 2 splits those
//  halves: the observation sites keep their timers, notifications and KVO and
//  emit one of these cases; every decision moves into `RecoveryPolicy.decide`.
//
//  Nothing here is wired yet — wave 2 makes the engine session emit these and
//  execute the resulting `RecoveryAction`s.
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
    /// without importing AVFoundation into the policy.
    enum TimeControl: Equatable {
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

    init(
        position: Double,
        timeControl: TimeControl,
        bufferedAhead: Double,
        generatedAhead: Double,
        secondsSinceLastServe: Double,
        userPaused: Bool,
        playbackEstablished: Bool
    ) {
        self.position = position
        self.timeControl = timeControl
        self.bufferedAhead = bufferedAhead
        self.generatedAhead = generatedAhead
        self.secondsSinceLastServe = secondsSinceLastServe
        self.userPaused = userPaused
        self.playbackEstablished = playbackEstablished
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
    /// (`reason: "replan"`).
    case replanCatch

    /// The `reason` token the legacy call sites pass, reproduced verbatim so
    /// the renewal log lines and the `"<reason>_bg_renewal_failed"` escalation
    /// token are unchanged.
    var reason: String {
        switch self {
        case .playerError: return "player_error"
        case .proxy404: return "source_404"
        case .progressHeartbeat: return "progress"
        case .replanCatch: return "replan"
        }
    }
}

/// Mirrors `AVPlayerBackend.SeekDeadlineKind` (private, at the seek-deadline
/// state) so the policy can see a seek that never completed.
enum SeekDeadlineKind: Equatable {
    /// A user-initiated seek. `mediaTarget` is the media-timeline target that
    /// was requested.
    case interactive(mediaTarget: Double)
    /// The resume seek issued at load. `mediaTarget` is the media-timeline
    /// start position.
    case initial(mediaTarget: Double)
    /// A seek issued by a recovery rung (stall nudge, item reload). It carries
    /// no follow-up of its own: the rung that issued it owns the next step.
    case recovery(reason: String)
}

/// Everything the recovery owner can be told. One case per observation site
/// that today also decides.
enum RecoveryObservation: Equatable {
    // MARK: Backend-originated (loopback route unless noted)

    /// Startup watchdog tick, 1 Hz, pre-`didFireFileLoaded`
    /// (`loopbackStartupWatchdogTick`). `servedRequests` is the local HLS
    /// server's cumulative served-request count; a change since the last tick
    /// is the only evidence of forward progress.
    case startupTick(
        servedRequests: UInt64,
        secondsSinceStart: Double,
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
    /// `.AVPlayerItemFailedToPlayToEndTime` whose description carries
    /// "Playlist File unchanged" or "-12888".
    case playlistUnchanged(userPaused: Bool)
    /// `isPlaybackLikelyToKeepUp` / `loadedTimeRanges` KVO — the auto-resume
    /// rung's trigger.
    ///
    /// `likely` is `AVPlayerItem.isPlaybackLikelyToKeepUp` read at the moment
    /// the KVO fired. It is a payload rather than an implication of the case
    /// name because the rung's predicate is
    /// `item.isPlaybackLikelyToKeepUp || bufferedAhead > 0.5` (B:3713) and both
    /// KVOs feed it — without the flag the emitter would have to evaluate half
    /// the rung, which is exactly the split ownership Stage 2 removes.
    case likelyToKeepUp(rate: Double, bufferedAhead: Double, reachedEnd: Bool, likely: Bool)
    /// A seek deadline expired without the seek completing.
    case seekDeadlineExpired(kind: SeekDeadlineKind)
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
    /// Buffering edge, for the origin-outage "Reconnecting" runway gate.
    case bufferingChanged(Bool)
}
