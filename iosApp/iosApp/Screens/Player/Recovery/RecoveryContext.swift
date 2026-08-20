//
//  RecoveryContext.swift
//
//  Stage 2 — the threaded state of the single recovery owner.
//
//  Every field here replaces a mutable field that today lives on either
//  `AVPlayerBackend` (the six in-route ladders' watchdog state) or
//  `PlayerViewModel` (the outage ride-through latches, the two renewal
//  single-flights, the two route-fallback `hasAttempted*` latches). The three
//  pure value types that already exist — `LoopbackItemDeathRecoveryState`,
//  `LoopbackItemDeathConfirmationState`, `LoopbackRebuildBudget` — are reused
//  verbatim rather than reimplemented: they are already the decision cores of
//  their rungs, they already carry the right constants, and they already have
//  tests.
//
//  `RecoveryPolicy.decide` takes a context by value and returns the next one;
//  the caller (wave 2's engine session, wave 3's session actor) stores it
//  against the load's identity, which is what makes every recovery decision
//  identity-scoped without a generation counter.
//

import Foundation

/// The recovery owner's threaded state for one load.
struct RecoveryContext: Equatable {

    // MARK: - Nested states

    /// Startup ladder state (`AVPlayerBackend.loopbackStartupRecoveryStage` +
    /// the three `loopbackStartup*` timestamps/counters, set by
    /// `armLoopbackStartupWatchdogIfNeeded`).
    struct StartupState: Equatable {
        /// `AVPlayerBackend.LoopbackStartupRecoveryStage`, re-declared here so
        /// the policy owns the ladder's position rather than the backend.
        enum Stage: Equatable {
            case initial
            case nudged
            case reloaded
        }

        var stage: Stage
        /// `loopbackStartupWatchdogStartedAt` — the absolute backstop's origin.
        var startedAt: Date
        /// `loopbackStartupLastProgressAt` — rebased on every served-request
        /// delta, on every display-mode-switch tick, and by the nudge and
        /// reload rungs.
        var lastProgressAt: Date
        /// `loopbackStartupLastRequestCount` — the local HLS server's served
        /// request count at the previous tick.
        var lastRequestCount: UInt64

        init(
            stage: Stage = .initial,
            startedAt: Date,
            lastProgressAt: Date,
            lastRequestCount: UInt64 = 0
        ) {
            self.stage = stage
            self.startedAt = startedAt
            self.lastProgressAt = lastProgressAt
            self.lastRequestCount = lastRequestCount
        }
    }

    /// Playhead watchdog state (`watchdogLast*`, `watchdogReanchor*`, the
    /// retired starvation-escalation latch, `lastLocalLoopbackStallRecoveryAt`).
    struct PlayheadState: Equatable {
        /// When the playhead was last observed to move by more than 0.05 s in
        /// either direction (`watchdogLastAdvanceWall`). `nil` until the first
        /// sample, which is the backend's `watchdogLastAdvanceWall == 0` state:
        /// `stationaryFor` reads 0.
        var stationarySince: Date?
        /// The last position the advance tracker latched
        /// (`watchdogLastPlayheadSeconds`; the backend's `< 0` sentinel is `nil`
        /// here).
        var lastAdvancePosition: Double?
        /// The backend's retired reanchor counter (`watchdogReanchor*`).
        var reanchorCount: Int
        /// `watchdogReanchorWindowStartWall`; `nil` is the backend's `== 0`
        /// "no window yet" sentinel.
        var windowStart: Date?
        /// The retired starvation-escalation latch — one starvation/exhaustion
        /// escalation per rolling window.
        var didEscalateStarvation: Bool
        /// `lastLocalLoopbackStallRecoveryAt` — the shared reanchor rung's 10 s
        /// cooldown clock.
        var lastStallRecoveryAt: Date?
        /// The most recent transport sample.
        ///
        /// The shared reanchor rung, the auto-resume rung and the item-death
        /// rung read the player live today (`currentTime()`,
        /// `playableAheadSeconds`, `latestLoopbackGeneratedStats`) at the moment
        /// their notification fires — they are not driven by the 1 Hz tick. The
        /// policy is pure, so its caller refreshes this field from the live
        /// player immediately before every `decide` call; that is what keeps
        /// those rungs reading the same values they read today.
        var lastSample: PlayheadSample?

        init(
            stationarySince: Date? = nil,
            lastAdvancePosition: Double? = nil,
            reanchorCount: Int = 0,
            windowStart: Date? = nil,
            didEscalateStarvation: Bool = false,
            lastStallRecoveryAt: Date? = nil,
            lastSample: PlayheadSample? = nil
        ) {
            self.stationarySince = stationarySince
            self.lastAdvancePosition = lastAdvancePosition
            self.reanchorCount = reanchorCount
            self.windowStart = windowStart
            self.didEscalateStarvation = didEscalateStarvation
            self.lastStallRecoveryAt = lastStallRecoveryAt
            self.lastSample = lastSample
        }
    }

    /// A copy of `AVPlayerBackend.LoopbackEdgeWatch` (private, at the
    /// `loopbackEdgeWatch` field). Wave 2 deletes the backend's copy when the
    /// edge sampler becomes an observation source.
    struct EdgeWatchState: Equatable {
        var lastLoadedEnd: Double
        var lastLoadedEndAdvancedAt: Date
        var lastPlaylistEnd: Double
        var lastPlaylistHash: UInt64

        init(
            lastLoadedEnd: Double,
            lastLoadedEndAdvancedAt: Date,
            lastPlaylistEnd: Double,
            lastPlaylistHash: UInt64
        ) {
            self.lastLoadedEnd = lastLoadedEnd
            self.lastLoadedEndAdvancedAt = lastLoadedEndAdvancedAt
            self.lastPlaylistEnd = lastPlaylistEnd
            self.lastPlaylistHash = lastPlaylistHash
        }
    }

    /// Origin-outage ride-through state (`PlayerViewModel.sourceOutageActive`,
    /// `sourceOutageNoticeShown`, and the `sourceOutageRideThroughTask` loop's
    /// two locals: its deadline origin and its `delay`).
    struct OutageState: Equatable {
        /// When the ride-through started; the 90 s budget runs from here.
        var rideThroughStart: Date
        /// The loop's `delay` local: the interval it will sleep after the probe
        /// it is about to issue. Starts at
        /// `RecoveryPolicy.serverOutageRecoveryInitialDelay`, doubles per probe,
        /// capped at `serverOutageRecoveryMaxDelay`.
        var nextProbeDelay: TimeInterval
        /// `sourceOutageNoticeShown` — the "Reconnecting" runway gate fires once.
        var noticeShown: Bool

        init(
            rideThroughStart: Date,
            nextProbeDelay: TimeInterval = RecoveryPolicy.serverOutageRecoveryInitialDelay,
            noticeShown: Bool = false
        ) {
            self.rideThroughStart = rideThroughStart
            self.nextProbeDelay = nextProbeDelay
            self.noticeShown = noticeShown
        }
    }

    /// Visible server-outage recovery state — the `waitForServerReady` loop's
    /// deadline origin and `delay` (`PlayerViewModel.waitForServerReady`).
    struct ServerOutageRecoveryState: Equatable {
        /// When the wait began; the 90 s timeout runs from here.
        var waitStart: Date
        /// The loop's `delay` local: what it sleeps after a failed probe.
        var nextDelay: TimeInterval

        init(
            waitStart: Date,
            nextDelay: TimeInterval = RecoveryPolicy.serverOutageRecoveryInitialDelay
        ) {
            self.waitStart = waitStart
            self.nextDelay = nextDelay
        }
    }

    /// The four corroborating inputs of
    /// `PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd`.
    struct NearEndInputs: Equatable {
        var duration: Double
        var currentTime: Double
        var bufferedAhead: Double
        /// `sourceOutageActive || sourceProxy?.isOriginOutageActive == true`.
        var sourceOutageActive: Bool

        init(
            duration: Double,
            currentTime: Double,
            bufferedAhead: Double,
            sourceOutageActive: Bool
        ) {
            self.duration = duration
            self.currentTime = currentTime
            self.bufferedAhead = bufferedAhead
            self.sourceOutageActive = sourceOutageActive
        }
    }

    // MARK: - Stored state

    /// Which engine this load is running on. The in-route rungs are
    /// loopback-only, exactly as the backend's `case .siloLoopback` guards are.
    var route: PlaybackEngineKind
    /// `AVPlayerBackend.didFireFileLoaded`.
    var playbackEstablished: Bool
    /// `AVPlayerBackend.isUserPaused` — the explicit play-intent latch.
    var userPaused: Bool
    /// `AVPlayerBackend.recoverySuspensionReasons`. Same reason strings as
    /// today: `AVPlayerBackend.serverReplanRecoverySuspensionReason`
    /// ("server_replan") and `originOutageRecoverySuspensionReason`
    /// ("origin_outage").
    var suspendedReasons: Set<String>
    /// `AVPlayerBackend.mediaTimelineOffsetSeconds`. Observations are sampled on
    /// the player timeline; the actions' anchors are media-timeline, and this is
    /// the conversion the backend applies today at its sinks
    /// (`mediaTime(for:)`).
    var mediaTimelineOffset: Double

    var startup: StartupState?
    var playhead: PlayheadState
    /// Reused verbatim — `AVPlayerBackend.loopbackItemDeathRecoveryState`.
    var itemDeath: LoopbackItemDeathRecoveryState
    /// Reused verbatim — `AVPlayerBackend.loopbackItemDeathConfirmationState`.
    var itemDeathConfirmation: LoopbackItemDeathConfirmationState
    var edge: EdgeWatchState?
    /// Reused verbatim — `AVPlayerBackend.loopbackRebuildBudget`.
    var rebuildBudget: LoopbackRebuildBudget
    var outage: OutageState?
    var serverOutageRecovery: ServerOutageRecoveryState?
    /// `PlayerViewModel.backgroundRenewalTransientFailures`.
    var backgroundRenewalTransientFailures: Int
    /// Whether a silent (background) source renewal is in flight. Replaces the
    /// background-renewal session-id echo; wave 3 scopes it by `SessionIdentity`.
    var backgroundRenewalInFlight: Bool
    /// Whether the visible (fresh) renewal is in flight. Replaces the
    /// stale-session-recovery session-id echo.
    var freshRenewalInFlight: Bool
    /// `PlayerViewModel.currentDeliveryStrategy == .direct` plus the other
    /// preconditions of `attemptBackgroundSessionRenewal`: not offline, a watch
    /// detail is loaded, and the source proxy is alive. A background renewal
    /// only exists on a proxied direct source.
    var canRenewSourceInBackground: Bool
    /// `PlayerViewModel.activePreparedProtocolV3 != nil` — the online V3 path,
    /// which owns delivery/fallback via a server replan.
    var isProtocolV3Active: Bool
    /// A Protocol V3 replan is already in flight
    /// (`protocolV3ReplanTask != nil`), which is what makes
    /// `requestServerHLSRouteFallback` return false.
    var isReplanInFlight: Bool
    /// `PlayerViewModel.currentWatchDetail != nil` — the other half of
    /// `requestServerHLSRouteFallback`'s guard (PVM:2284). Without a watch
    /// detail there is nothing to replan against, so both offline server-HLS
    /// rungs return false and the failure ladder runs on to its terminal rung.
    ///
    /// The online rung (`isProtocolV3Active`) deliberately does not read it:
    /// PVM:1553-1555 calls `attemptProtocolV3Replan` and returns whether or not
    /// the replan is accepted, so no lower rung runs either way and the engine
    /// executing `.requestServerReplan` reproduces the no-op at PVM:1609.
    var hasWatchDetail: Bool
    /// A foreground interruption is pending, not yet auto-recovered, and inside
    /// its 3 s deadline (`shouldAutoRecoverFromInterruption`).
    var canAutoRecoverInterruption: Bool
    /// The view model's retired per-load native-direct fallback latch.
    var attemptedNativeDirectFallback: Bool
    /// The view model's retired per-load Silo-route HLS fallback latch.
    var attemptedLoopbackHLSFallback: Bool
    /// Whether a local loopback fallback plan can be built for the failed
    /// native-direct route (`makeLoopbackFallbackPlan` returns non-nil). When it
    /// cannot, the native-direct rung escalates straight to the server-HLS rung,
    /// exactly as `attemptNativeDirectRouteRecovery` does.
    var canBuildLoopbackFallback: Bool
    var nearEnd: NearEndInputs?

    // MARK: - Construction

    init(
        route: PlaybackEngineKind,
        playbackEstablished: Bool = false,
        userPaused: Bool = false,
        suspendedReasons: Set<String> = [],
        mediaTimelineOffset: Double = 0,
        startup: StartupState? = nil,
        playhead: PlayheadState = PlayheadState(),
        itemDeath: LoopbackItemDeathRecoveryState = LoopbackItemDeathRecoveryState(),
        itemDeathConfirmation: LoopbackItemDeathConfirmationState = LoopbackItemDeathConfirmationState(),
        edge: EdgeWatchState? = nil,
        rebuildBudget: LoopbackRebuildBudget = LoopbackRebuildBudget(),
        outage: OutageState? = nil,
        serverOutageRecovery: ServerOutageRecoveryState? = nil,
        backgroundRenewalTransientFailures: Int = 0,
        backgroundRenewalInFlight: Bool = false,
        freshRenewalInFlight: Bool = false,
        canRenewSourceInBackground: Bool = false,
        isProtocolV3Active: Bool = false,
        isReplanInFlight: Bool = false,
        hasWatchDetail: Bool = false,
        canAutoRecoverInterruption: Bool = false,
        attemptedNativeDirectFallback: Bool = false,
        attemptedLoopbackHLSFallback: Bool = false,
        canBuildLoopbackFallback: Bool = false,
        nearEnd: NearEndInputs? = nil
    ) {
        self.route = route
        self.playbackEstablished = playbackEstablished
        self.userPaused = userPaused
        self.suspendedReasons = suspendedReasons
        self.mediaTimelineOffset = mediaTimelineOffset
        self.startup = startup
        self.playhead = playhead
        self.itemDeath = itemDeath
        self.itemDeathConfirmation = itemDeathConfirmation
        self.edge = edge
        self.rebuildBudget = rebuildBudget
        self.outage = outage
        self.serverOutageRecovery = serverOutageRecovery
        self.backgroundRenewalTransientFailures = backgroundRenewalTransientFailures
        self.backgroundRenewalInFlight = backgroundRenewalInFlight
        self.freshRenewalInFlight = freshRenewalInFlight
        self.canRenewSourceInBackground = canRenewSourceInBackground
        self.isProtocolV3Active = isProtocolV3Active
        self.isReplanInFlight = isReplanInFlight
        self.hasWatchDetail = hasWatchDetail
        self.canAutoRecoverInterruption = canAutoRecoverInterruption
        self.attemptedNativeDirectFallback = attemptedNativeDirectFallback
        self.attemptedLoopbackHLSFallback = attemptedLoopbackHLSFallback
        self.canBuildLoopbackFallback = canBuildLoopbackFallback
        self.nearEnd = nearEnd
    }

    /// The state a load starts in: nothing latched, a full rebuild budget.
    /// Mirrors what the three public `load*` entry points do today — they reset
    /// `isUserPaused` and `loopbackRebuildBudget` and nothing else, because the
    /// rest of the watchdog state is re-armed by the loopback start path.
    static func initial(route: PlaybackEngineKind) -> RecoveryContext {
        RecoveryContext(route: route)
    }

    // MARK: - Derived

    /// `AVPlayerBackend.isRecoverySuspended`.
    var isRecoverySuspended: Bool { !suspendedReasons.isEmpty }

    /// `AVPlayerBackend.mediaTime(for:)`, verbatim.
    func mediaSeconds(forPlayerSeconds playerSeconds: Double) -> Double {
        guard playerSeconds.isFinite else { return 0 }
        return max(0, playerSeconds + mediaTimelineOffset)
    }

    // MARK: - Equatable

    /// Hand-written because two of the three reused value types
    /// (`LoopbackItemDeathRecoveryState`, `LoopbackItemDeathConfirmationState`)
    /// keep all of their stored properties `private` and do not declare
    /// `Equatable`. The conformance cannot be added from here — Swift only
    /// synthesises it in the type's own file, and wave 1 may not edit
    /// `AVPlayerBackend.swift` — so those two are compared structurally by
    /// reflection instead of being silently dropped from `==`, which would make
    /// two contexts with different item-death evidence compare equal. Both are
    /// plain data (`Double?` + two `Int`s; one optional three-field candidate),
    /// so the reflected description is a total, deterministic rendering of
    /// their whole state. Wave 2 owns `AVPlayerBackend.swift` and replaces this
    /// with the real conformances.
    static func == (lhs: RecoveryContext, rhs: RecoveryContext) -> Bool {
        lhs.route == rhs.route
            && lhs.playbackEstablished == rhs.playbackEstablished
            && lhs.userPaused == rhs.userPaused
            && lhs.suspendedReasons == rhs.suspendedReasons
            && lhs.mediaTimelineOffset == rhs.mediaTimelineOffset
            && lhs.startup == rhs.startup
            && lhs.playhead == rhs.playhead
            && structurallyEqual(lhs.itemDeath, rhs.itemDeath)
            && structurallyEqual(lhs.itemDeathConfirmation, rhs.itemDeathConfirmation)
            && lhs.edge == rhs.edge
            && lhs.rebuildBudget.used == rhs.rebuildBudget.used
            && lhs.outage == rhs.outage
            && lhs.serverOutageRecovery == rhs.serverOutageRecovery
            && lhs.backgroundRenewalTransientFailures == rhs.backgroundRenewalTransientFailures
            && lhs.backgroundRenewalInFlight == rhs.backgroundRenewalInFlight
            && lhs.freshRenewalInFlight == rhs.freshRenewalInFlight
            && lhs.canRenewSourceInBackground == rhs.canRenewSourceInBackground
            && lhs.isProtocolV3Active == rhs.isProtocolV3Active
            && lhs.isReplanInFlight == rhs.isReplanInFlight
            && lhs.hasWatchDetail == rhs.hasWatchDetail
            && lhs.canAutoRecoverInterruption == rhs.canAutoRecoverInterruption
            && lhs.attemptedNativeDirectFallback == rhs.attemptedNativeDirectFallback
            && lhs.attemptedLoopbackHLSFallback == rhs.attemptedLoopbackHLSFallback
            && lhs.canBuildLoopbackFallback == rhs.canBuildLoopbackFallback
            && lhs.nearEnd == rhs.nearEnd
    }
}

/// Structural comparison for the two reused backend value types that cannot
/// conform to `Equatable` from this file. See `RecoveryContext.==`.
private func structurallyEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    String(reflecting: lhs) == String(reflecting: rhs)
}
