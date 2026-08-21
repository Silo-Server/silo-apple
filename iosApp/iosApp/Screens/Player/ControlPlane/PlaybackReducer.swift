import Foundation
import SwiftUI

/// The playback control plane's decision function: pure, total, and the only
/// place a `PlayerIntent` or a `PlayerEvent` turns into state plus effects.
///
/// It reads no clock (`now` is a parameter), performs no I/O and holds no
/// reference to the view model, the bridge or the backend. Its one
/// collaborator is a pure static — `PlaybackSessionBridge.isMaterialOutputRouteChange`,
/// called rather than restated so the output-route materiality rule has one
/// owner. Recovery decisions
/// are *not* made here — `RecoveryPolicy` decides, the session actor feeds the
/// decision back as `PlayerEvent.recovery(action, loadID)`, and the reducer
/// maps that action to state and effects (design §4 I3).
enum PlaybackReducer {

    // MARK: - Constants (each equals today's literal)

    /// The safety valve that drops a seek filter no post-seek time report
    /// ever released.
    static let seekFilterTimeoutSeconds: TimeInterval = 5.0
    /// How long an interrupted load may take to resume itself before the
    /// recovery is abandoned.
    static let interruptionRecoveryTimeout: TimeInterval = 3.0
    /// How far the playhead must advance past the interruption position for
    /// the resume to count as landed.
    static let interruptionResumeSuccessThresholdSeconds: Double = 0.1
    /// The progress heartbeat interval.
    static let progressReportIntervalSeconds: TimeInterval = 10.0
    /// `RecoveryAction.recoverFromServerOutage(reason:)`'s one meaningful
    /// discriminator: the token form of
    /// `PlaybackSourceInterruptionReason.sourceEntityChanged`, which is what
    /// picks `discardSourceCacheHandoff()` over `stashSourceCacheHandoff()`.
    /// Spelled here rather than imported from
    /// `RecoveryPolicy.token(for:)` because that lives in wave 1B; the two are
    /// pinned to the same literal by that package's
    /// `testInterruptionReason_TokensKeepTheEntityChangedDiscriminator`.
    static let sourceEntityChangedReason = "source_entity_changed"

    // MARK: - Intents

    static func reduce(
        _ state: PlaybackState,
        intent: PlayerIntent,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        // A disposed player accepts nothing (today's `guard !isDisposed` on
        // every entry point).
        if case .disposed = state, !isDismiss(intent) {
            return (state, [])
        }

        switch intent {
        case .load(let request, let origin, let options):
            return beginLoad(
                from: state,
                request: request,
                adoption: .freshLoad(origin),
                options: options
            )

        case .play:
            return transport(state, command: .play)

        case .pause:
            return transport(state, command: .pause)

        case .togglePlayPause:
            // tvOS: a suspended player resumes instead of toggling.
            if case .suspended = state {
                return reduce(state, intent: .resumeSuspended, now: now)
            }
            guard case .playing(let playing) = state else { return (state, []) }
            return transport(state, command: playing.transport.isPaused ? .play : .pause)

        case .seek(let targetSeconds, let origin):
            return beginSeek(state, targetSeconds: targetSeconds, origin: origin)

        case .changeQuality(let qualityId):
            // The V3 path of `switchQuality`. Its pre-V3 branches (source
            // reselection, transcode → direct) need version and plan knowledge
            // the control plane does not hold; they stay with the view model,
            // which issues `.load` for them.
            guard case .playing(let playing) = state else { return (state, []) }
            // `switchQuality` only takes the replan branch when a live V3 plan
            // owns the load. Without one it normalises the id
            // differently and runs the source-reselection / transcode branches,
            // which need version and plan knowledge the control plane does not
            // hold — so an offline or legacy load ignores this intent here and
            // the shell issues its `.load` instead.
            guard playing.hasProtocolV3 else { return (state, []) }
            // `switchQuality` resolves the id through
            // `ApplePlaybackQuality.protocolV3QualityId` on the V3 path and
            // then returns early when it already equals `activeQualityId`,
            // so re-picking the rung that is already playing
            // issues no server call. The reducer holds `activeQualityId`, so
            // it applies the same guard rather than sending a redundant
            // replan. The other half of that guard — `qualitySwitchError != nil`
            // re-arming the switch after a failed one — stays with the
            // presentation model, which owns the error string.
            let resolvedQualityId = ApplePlaybackQuality.protocolV3QualityId(qualityId)
            guard resolvedQualityId != playing.activeQualityId else { return (state, []) }
            return requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: max(0, playing.transport.positionSeconds.isFinite ? playing.transport.positionSeconds : 0),
                    classification: "quality_changed",
                    message: "User selected playback quality \(resolvedQualityId).",
                    qualityPreference: resolvedQualityId,
                    completesQualitySwitch: true
                )
            )

        case .outputRouteChanged(let snapshot):
            guard case .playing(let playing) = state else { return (state, []) }
            // The route observer's first guard, before it even samples the
            // snapshot: `activePreparedProtocolV3` must be live.
            // `isMaterialOutputRouteChange` is a bare id inequality, and an
            // offline identity publishes `outputContextId: ""`, so without this
            // an offline load would find *every* route notification material
            // and ask a server
            // it never spoke to for a replan. (The observer's `!isLoading` half
            // is structural here: a load in flight is `.preparing`, and a
            // replan or renewal in flight is refused by `requestReplan`'s
            // one-slot guard.)
            guard playing.hasProtocolV3 else { return (state, []) }
            // Same materiality rule as the view model's route observer — one
            // owner, called rather than re-derived.
            guard PlaybackSessionBridge.isMaterialOutputRouteChange(
                activeOutputContextId: playing.identity.outputContextId,
                observedOutputContextId: snapshot.outputContextId
            ) else {
                return (state, [])
            }
            return requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: playing.transport.positionSeconds,
                    classification: "output_route_changed",
                    message: "The Apple audio output route changed.",
                    outputRouteSnapshot: snapshot
                )
            )

        case .scenePhase(let phase):
            return scenePhase(state, phase: phase, platform: .current, now: now)

        case .resumeSuspended:
            guard case .suspended(let context) = state else { return (state, []) }
            return beginLoad(
                from: state,
                request: context.request,
                adoption: .freshLoad(.userInitiated),
                options: LoadOptions(
                    progressPosition: nil,
                    resumePosition: context.resumePosition,
                    allowNearEndResume: true
                )
            )

        case .retry:
            guard let request = retryRequest(for: state) else { return (state, []) }
            let position = currentPosition(state)
            return beginLoad(
                from: state,
                request: request,
                adoption: .freshLoad(.userInitiated),
                options: LoadOptions(
                    progressPosition: position,
                    resumePosition: position,
                    allowNearEndResume: true
                )
            )

        case .dismiss:
            return dismiss(state)
        }
    }

    // MARK: - Events

    static func reduce(
        _ state: PlaybackState,
        event: PlayerEvent,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        switch event {
        case .engine(let engineEvent, let loadID):
            return engine(state, event: engineEvent, loadID: loadID, now: now)

        case .session(let sessionEvent, let identity):
            return session(state, event: sessionEvent, identity: identity, now: now)

        case .recovery(let action, let loadID):
            guard state.loadID == loadID else { return (state, []) }
            return recovery(state, action: action, now: now)

        case .timer(let timerID, let loadID):
            guard state.loadID == loadID else { return (state, []) }
            return timer(state, timerID: timerID, now: now)
        }
    }

    // MARK: - Load

    /// The effects `beginFreshLoad` performs, in its order: its synchronous
    /// prologue's timer cancellations, then the `freshLoadTask` body — report
    /// or finalize the outgoing session, dispose the outgoing engine, start the
    /// replacement session.
    ///
    /// (`realtimeClient.unbind()`, which sits between the report and the
    /// dispose, has no control-plane effect: the realtime client is a
    /// collaborator the view model rebinds on adopt.)
    /// The load whose engine the next one has to retire.
    ///
    /// `.suspended` reports no `loadID` on purpose — nothing may be scheduled
    /// against a load whose engine is gone — but the tvOS suspend deliberately
    /// left that load's source proxy running, so the resume is the site that
    /// stashes its cached prefix and stops it (base's
    /// `disposeActivePlayerForFreshLoad`, which ran unconditionally).
    private static func previousEngineLoadID(_ state: PlaybackState) -> LoadID? {
        if case .suspended(let context) = state { return context.retainedLoadID }
        return state.loadID
    }

    private static func beginLoad(
        from state: PlaybackState,
        request: LoadRequest,
        adoption: PlaybackAdoption,
        options: LoadOptions
    ) -> (PlaybackState, [Effect]) {
        let loadID = LoadID()
        // `resetPublishedLoadState` keeps `currentTime`,
        // `duration` and the buffering flag and zeroes only the two buffer
        // gauges, so the load starts from what the user is looking at rather
        // than from zero.
        var transport = currentTransport(state)
        transport.positionSeconds = currentPosition(state)
        transport.bufferedAheadSeconds = 0
        transport.runwaySeconds = 0
        let preparing = Preparing(
            loadID: loadID,
            identity: nil,
            phase: .resolvingSession,
            request: request,
            options: options,
            adoption: adoption,
            plan: nil,
            transport: transport,
            // `resetPublishedLoadState` publishes the "auto" label until the
            // adopt learns the real one.
            activeQualityId: ApplePlaybackQuality.autoId,
            resumeSelections: .seeded(from: request),
            // `beginFreshLoad` clears the interruption unless the caller asked
            // to preserve it.
            interruption: options.preserveInterruptionState ? currentInterruption(state) : nil
        )

        var effects: [Effect] = []
        if case .freshLoad(.userInitiated) = adoption {
            // `clearServerOutageRecoveryState()`, user-initiated loads only.
            effects.append(.cancelTimer(.serverOutageRecovery))
        }
        // A fresh load abandons whatever the outgoing load was riding out. The
        // ride-through is player-scoped now (the actor carries it across a
        // replan so a route change keeps the original deadline), so the load
        // that leaves it behind has to release it: legacy's loop died here by
        // itself — its next turn read the replacement session's driver, which
        // has no outage — and an adopted hold with no releaser suspends the
        // replacement's whole in-route ladder. Only the replan path keeps the
        // carry, which is the case it exists for.
        effects.append(.cancelTimer(.sourceOutageRideThrough))
        if !options.preserveInterruptionState {
            effects.append(.cancelTimer(.interruptionRecovery))
        }
        // `resetPublishedLoadState`'s first two statements are
        // `isLoading = true; error = nil` — the loading overlay every fresh
        // load, retry, resume, interruption recovery and visible session
        // renewal raises. It sits here, between the interruption clear and the
        // two task cancels, because that is where `beginFreshLoad` calls it.
        effects.append(.publish(presentation(for: .preparing(preparing))))
        effects.append(.cancelTimer(.freshLoad))
        effects.append(.cancelTimer(.protocolV3Replan))

        // `shouldFinalizeCurrentSession`: an offline load never starts a
        // replacement server session, so the prior one is finalized here.
        let shouldFinalize = options.finalizeCurrentSession || request.offlineDownloadId != nil
        if let position = options.progressPosition,
           position.isFinite,
           position >= 0,
           let identity = state.identity {
            effects.append(
                shouldFinalize
                    ? .stopSession(identity, position: position, isPaused: true)
                    : .reportProgress(identity, position: position, isPaused: true)
            )
        }

        if let previousLoadID = previousEngineLoadID(state), !adoption.reusesActiveEngine {
            // Both halves of a fresh load stash: `resetPublishedLoadState`
            // and `loadStream` hand the outgoing proxy's
            // cached prefix to the replacement, which `SourceCacheAdoptionPolicy`
            // then accepts or rejects against the incoming plan.
            effects.append(.disposeEngine(previousLoadID, sourceCache: .stash))
        }

        effects.append(.startSession(request, options, loadID))
        return (.preparing(preparing), effects)
    }

    /// `adoptPreparedPlayback`'s transport adoption, which runs
    /// **before** `loadStream` — so by the time the engine reports
    /// `fileLoaded` the playhead and the duration are already the new
    /// session's, and the scrubber never blinks back to 0/0.
    private static func adopting(
        _ transport: TransportState,
        prepared: PreparedPlayback,
        adoption: PlaybackAdoption
    ) -> TransportState {
        var transport = transport
        // `fallbackDuration`: a fresh load has nothing to fall back to, a
        // replan keeps the duration it already published.
        let fallbackDuration: Double
        if case .freshLoad = adoption { fallbackDuration = 0 } else { fallbackDuration = transport.durationSeconds }
        transport.durationSeconds = adoptedDuration(prepared, fallback: fallbackDuration)
        transport.positionSeconds = movieTime(for: prepared.session)
        return transport
    }

    /// The one duration rule every adopt shares — the load/replan adopt and
    /// the silent renewal alike: the session's, else the selected version's,
    /// else what is already published.
    private static func adoptedDuration(_ prepared: PreparedPlayback, fallback: Double) -> Double {
        prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? fallback
    }

    /// `adoptProtocolV3RenewalIntent`: every adopt rewrites
    /// `lastLoadRequest` from the plan the server just authorised, so the
    /// replay intent every later recovery rebuilds from carries the *current*
    /// file, audio index, subtitle identities, authoritative V3 subtitle
    /// ordinal and quality rung — not the ones the load started with.
    ///
    /// Its two preconditions are the view model's, verbatim: the prepare must
    /// carry a V3 plan, and the request must not be an offline download (an
    /// offline load has no server plan to adopt).
    ///
    /// `qualitySwitchOverride` is the pre-adopt latch both replan pipelines
    /// apply first — `attemptProtocolV3Replan` sets
    /// `lastLoadRequest?.preferredQualityOverride = prepared.activeQualityId`
    /// when `completesQualitySwitch` and
    /// `restartCurrentTranscodeHLS` sets it to the requested `qualityId`,
    /// both *before* `adoptPreparedPlayback` runs. On the V3
    /// path the adoption below overwrites it with the same value; the latch is
    /// what keeps the user's choice when the prepare carries no plan.
    private static func adoptedRequest(
        _ request: LoadRequest,
        prepared: PreparedPlayback,
        qualitySwitchOverride: String? = nil
    ) -> LoadRequest {
        var request = request
        if let qualitySwitchOverride {
            request.preferredQualityOverride = qualitySwitchOverride
        }
        guard let plan = prepared.protocolV3?.plan, request.offlineDownloadId == nil else {
            return request
        }
        return request.adoptingProtocolV3Intent(
            plan: plan,
            selectedVersion: prepared.selectedVersion,
            activeQualityId: prepared.activeQualityId
        )
    }

    /// The quality latch a replan applies to the replay request before the
    /// adopt, per pipeline (see `adoptedRequest`).
    private static func qualitySwitchOverride(
        for intent: ReplanIntent,
        prepared: PreparedPlayback
    ) -> String? {
        switch intent.kind {
        case .serverReplan:
            return intent.completesQualitySwitch ? prepared.activeQualityId : nil
        case .transcodeRestart(.qualityChange(let qualityId)):
            return qualityId
        case .transcodeRestart(.seekReanchor):
            return nil
        }
    }

    /// The playhead a prepared session resolves to: the server's position on
    /// the session's own axis, moved onto the movie-time axis the control
    /// plane, the seek targets and the wire all share.
    static func movieTime(for session: PlaybackSessionResponse) -> Double {
        let playerTime = session.position.isFinite ? session.position : 0
        let offset = session.timelineOffsetSeconds.isFinite ? session.timelineOffsetSeconds : 0
        return max(0, playerTime + offset)
    }

    /// A server transcode is exposed as a growing HLS playlist while FFmpeg is
    /// producing it. AVPlayer reports the currently published playlist length
    /// as the item duration, but that is not the VOD duration and can grow past
    /// the probed media length. Keep a known server duration authoritative;
    /// backend duration remains the fallback when the server has no value.
    static func shouldAdoptBackendDuration(
        _ reportedDuration: Double,
        currentDuration: Double,
        delivery: PlaybackDeliveryStrategy
    ) -> Bool {
        guard reportedDuration.isFinite, reportedDuration > 0 else { return false }
        guard currentDuration.isFinite, currentDuration > 0 else { return true }
        if case .transcode = delivery {
            return false
        }
        return reportedDuration >= currentDuration
    }

    /// Outside an explicit seek playback time is monotonic, so a report that
    /// jumps backwards is a loopback replacement item's anchor frame, not a
    /// playhead.
    static func isUnexpectedBackwardPlaybackTime(
        _ candidate: Double,
        currentTime: Double,
        explicitSeekInFlight: Bool
    ) -> Bool {
        guard !explicitSeekInFlight,
              candidate.isFinite,
              currentTime.isFinite else {
            return false
        }
        return candidate + 0.75 < currentTime
    }

    /// The request a recovery re-loads or a suspend stores.
    ///
    /// `makeSuspendedPlaybackContext` and
    /// `attemptStaleSessionRenewal` both rebuild the request
    /// through `copyForRecovery`, from the **live** selection rather than the
    /// one the load started with — which is what keeps a changed audio track
    /// across a tvOS suspend and stops a recovery re-honouring
    /// `startFromBeginning: true` against a resume override. They differ in two
    /// arguments, and both differences are deliberate:
    ///   * the renewal prefers `currentSelectedVersion?.fileId`, the suspend
    ///     keeps the request's own `preferredFileId`;
    ///   * the renewal forces `offlineDownloadId: nil` (a renewal is by
    ///     definition a server session), the suspend keeps the request's.
    private static func recoveryRequest(
        _ request: LoadRequest,
        selections: TrackResumeSelections,
        preferringSelectedFileId: Bool,
        keepingOfflineDownload: Bool
    ) -> LoadRequest {
        request.copyForRecovery(
            preferredFileId: preferringSelectedFileId
                ? (selections.selectedFileId ?? request.preferredFileId)
                : request.preferredFileId,
            preferredAudioTrackIndex: selections.audioTrackIndex,
            preferredSubtitleTrackIndex: selections.subtitleTrackIndex,
            preferredSidecarSubtitleTrackId: selections.sidecarSubtitleTrackId,
            offlineDownloadId: keepingOfflineDownload ? request.offlineDownloadId : nil
        )
    }

    private static func retryRequest(for state: PlaybackState) -> LoadRequest? {
        switch state {
        case .idle, .disposed: return nil
        case .preparing(let preparing): return preparing.request
        case .playing(let playing): return playing.request
        case .suspended(let context): return context.request
        case .failed(_, _, _, let request, _, _): return request
        }
    }

    /// The playhead a state resumes or reports from — today's `currentTime`,
    /// which neither `finalizeTerminalPlaybackError` nor
    /// `suspendForBackground` resets, so `retry()` and the
    /// explicit resume both pick up where playback stopped.
    private static func currentPosition(_ state: PlaybackState) -> Double {
        let position: Double
        switch state {
        case .playing(let playing): position = playing.transport.positionSeconds
        // Pre-adopt this is still the outgoing playhead (the view model does
        // not move `currentTime` to the resume override until
        // `adoptPreparedPlayback` runs); post-adopt it is the new session's.
        case .preparing(let preparing): position = preparing.transport.positionSeconds
        case .suspended(let context): position = context.resumePosition
        case .failed(_, _, _, _, let failedPosition, _): position = failedPosition
        case .idle, .disposed: return 0
        }
        return position.isFinite ? max(0, position) : 0
    }

    /// The transport projections a new load inherits. The view model keeps
    /// them in stored properties that outlive the load; here they travel with
    /// the state.
    private static func currentTransport(_ state: PlaybackState) -> TransportState {
        switch state {
        case .playing(let playing): return playing.transport
        case .preparing(let preparing): return preparing.transport
        // `isPaused: true` is `isPlaying == false`, which each of the three
        // states below genuinely has: it is the view model's initial value,
        // `finalizeTerminalPlaybackError` sets it and
        // `suspendForBackground` sets it. `resetPublishedLoadState`
        // never writes `isPlaying`, so a cold start, a Retry and an explicit
        // resume all stay "not playing" until `handleFileLoaded`.
        // Two arms read the bit off `Preparing.transport` and would otherwise
        // treat those loads as playing: `presentation(for:)` (which would
        // publish a playing capsule under the loading overlay) and the tvOS
        // `.inactive` interruption arm, whose original guard is exactly
        // `guard isPlaying` — a cold start interrupted by a scene
        // blip must not record an interruption or arm the 3 s auto-recovery.
        case .suspended(let context):
            return TransportState(isPaused: true, positionSeconds: context.resumePosition)
        case .failed(_, _, _, _, let position, _):
            return TransportState(isPaused: true, positionSeconds: position)
        case .idle, .disposed:
            return TransportState(isPaused: true)
        }
    }

    /// The live resume selections a state carries (see `TrackResumeSelections`).
    private static func currentSelections(_ state: PlaybackState) -> TrackResumeSelections {
        switch state {
        case .playing(let playing): return playing.resumeSelections
        case .preparing(let preparing): return preparing.resumeSelections
        case .failed(_, _, _, _, _, let selections): return selections
        // `suspendedPlayback` already folded the selections into its request.
        case .suspended(let context): return .seeded(from: context.request)
        case .idle, .disposed: return TrackResumeSelections()
        }
    }

    private static func currentInterruption(_ state: PlaybackState) -> Playing.Interruption? {
        switch state {
        case .playing(let playing): return playing.interruption
        case .preparing(let preparing): return preparing.interruption
        case .idle, .suspended, .failed, .disposed: return nil
        }
    }

    /// The interruption slot — the pending `Playing.Interruption`, the
    /// transport it was recorded against and the load it belongs to — that
    /// **both** `Preparing` and `Playing` carry.
    ///
    /// The three tvOS interruption sites are state-agnostic in the view model
    /// and must stay so here:
    ///
    ///   * `pauseForForegroundInterruptionIfNeeded` guards only
    ///     on `!isBackgroundSuspended` and `isPlaying`;
    ///   * the `.active` re-arm guards only on
    ///     `isBackgroundSuspended` and a pending, `wasPlaying` interruption;
    ///   * `triggerAutomaticInterruptionRecovery` and the
    ///     deadline task that calls it guard only on
    ///     `lastLoadRequest`, `isPending` and `!didAutoRecover`.
    ///
    /// None of them looks at whether a load is in flight, and neither
    /// `playbackInterruption` nor `isPlaying` is cleared by
    /// `resetPublishedLoadState` — a `preserveInterruptionState`
    /// load deliberately keeps the interruption. So the Apple TV
    /// going inactive while a quality switch, a Retry or an interruption reload
    /// is still resolving does pause, re-arm and auto-recover today. Matching
    /// `case .playing` in those arms would silently narrow all three to steady
    /// playback and leave the UI reporting "playing" against a paused engine.
    private static func interruptionSlot(
        _ state: PlaybackState
    ) -> (loadID: LoadID, interruption: Playing.Interruption?, transport: TransportState)? {
        switch state {
        case .playing(let playing):
            return (playing.loadID, playing.interruption, playing.transport)
        case .preparing(let preparing):
            return (preparing.loadID, preparing.interruption, preparing.transport)
        case .idle, .suspended, .failed, .disposed:
            return nil
        }
    }

    /// The write half of `interruptionSlot`: applies `mutate` to whichever of
    /// `Preparing`/`Playing` holds the slot, and leaves the states that hold
    /// none untouched.
    private static func mutatingInterruptionSlot(
        _ state: PlaybackState,
        _ mutate: (inout Playing.Interruption?, inout TransportState) -> Void
    ) -> PlaybackState {
        switch state {
        case .playing(var playing):
            mutate(&playing.interruption, &playing.transport)
            return .playing(playing)
        case .preparing(var preparing):
            mutate(&preparing.interruption, &preparing.transport)
            return .preparing(preparing)
        case .idle, .suspended, .failed, .disposed:
            return state
        }
    }

    // MARK: - Transport

    /// `togglePlayPause` / `play()` / `pause()`: issue the command and write
    /// **nothing**.
    ///
    /// `isPlaying` has one writer — the backend's `onPauseChange` callback
    /// ("let that be the single writer so the UI can't drift
    /// out of sync with the actual pipeline state on error paths"). An
    /// optimistic flip here would republish a paused/playing capsule the
    /// pipeline never reached, and it also feeds `.timer(.progress)`'s
    /// `reportProgress(isPaused:)` and the three scene-phase pause guards, so
    /// the drift would reach the server too. Exactly three sites write
    /// `isPlaying` by hand today and all three are ported where they live, not
    /// here: `handleEndOfFile` (in `endOfFile`),
    /// `triggerAutomaticInterruptionRecovery` and
    /// `attemptServerOutageRecovery`.
    private static func transport(
        _ state: PlaybackState,
        command: TransportCommand
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(let playing) = state else { return (state, []) }
        return (state, [.transport(command, playing.loadID)])
    }

    // MARK: - Seeking

    private static func beginSeek(
        _ state: PlaybackState,
        targetSeconds: Double,
        origin: SeekOrigin
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }
        // The postroll latch. `seek(to:)`, `seekTo(seconds:)`, `skipForward`
        // and `skipBackward` all guard on it, so an ordinary seek is only ever
        // reached by a caller that proved it was unset. Exactly two call sites
        // clear it *themselves* and then seek, and they are the two origins
        // allowed here: `keepWatchingCurrentEpisode` (leaving the terminal
        // postroll replays the last 10 s, and resuming at exact EOF would
        // present the postroll again) and `beginReanchorSeekUI`.
        if case .ended = playing.sub {
            switch origin {
            case .nextUpKeepWatching, .reanchor:
                playing.sub = .steady
            case .user:
                return (state, [])
            }
        }

        let request = SeekRequest(
            fromSeconds: playing.transport.positionSeconds,
            targetSeconds: targetSeconds,
            origin: origin
        )
        // `commitSeek`: the scrubber jumps to the target optimistically while
        // the filter drops stale drainage frames. The seek is a *field*, not a
        // `Sub` case (see `Playing.seek`), so it neither displaces nor is
        // displaced by a replan, a renewal or an in-route recovery — exactly
        // as `seekOriginTime`/`seekTargetTime` behave next to
        // `protocolV3ReplanTask` today.
        playing.seek = request
        playing.transport.positionSeconds = targetSeconds

        guard origin != .reanchor else {
            // `beginReanchorSeekUI` arms the filter, moves the
            // scrubber and cancels the safety timeout — and issues no engine
            // seek at all: the anchoring is the stream rebuild that follows
            // (`seek_reanchor` replan / fresh load / re-anchored loopback
            // `loadStream`). Emitting one here would seek the *outgoing* item
            // to a position it does not contain.
            //
            // The cancel is not decoration: the re-anchor filter deliberately
            // has *no* timeout (the rebuild is what releases it), so a 5 s
            // timeout still armed by an earlier plain seek would fire inside
            // the rebuild window and drop the filter early, letting the
            // outgoing item's drainage frames drag the scrubber back off the
            // anchor.
            let next = PlaybackState.playing(playing)
            return (next, [
                .cancelTimer(.seekFilterTimeout),
                .publish(presentation(for: next, isLoading: nil)),
            ])
        }
        let next = PlaybackState.playing(playing)
        return (
            next,
            [
                .seek(request, playing.loadID),
                // `commitSeek`'s safety valve: drop the filter if no post-seek
                // report ever releases it.
                .schedule(
                    .seekFilterTimeout,
                    after: .seconds(seekFilterTimeoutSeconds),
                    playing.loadID
                ),
                // The optimistic jump has to reach the scrubber *now*: the
                // backend mutes its periodic observer while the seek is
                // pending, so the coalesced transport publish that normally
                // carries `positionSeconds` would not run until the seek
                // completes — and the shell drops the scrub preview on
                // commit, which left the dot parked at the pre-seek position
                // for the whole seek latency.
                .publish(presentation(for: next, isLoading: nil)),
            ]
        )
    }

    /// The time-report seek filter the shell's engine-event loop applies:
    /// reports still closer to the pre-seek position than to the target are
    /// stale drainage frames; the first report past the midpoint means the seek
    /// landed.
    static func seekHasLanded(_ request: SeekRequest, observedSeconds: Double) -> Bool {
        abs(observedSeconds - request.fromSeconds) >= abs(observedSeconds - request.targetSeconds)
    }

    // MARK: - Replan

    /// The single entry point both replan pipelines take. `internal` rather
    /// than `private` because no intent mints a `.transcodeRestart` yet —
    /// wave 3 does — so `PlaybackReducerTests` reaches that branch here.
    static func requestReplan(
        _ playing: Playing,
        intent: ReplanIntent
    ) -> (PlaybackState, [Effect]) {
        // One replan slot. `attemptProtocolV3Replan` guards on
        // `protocolV3ReplanTask == nil`; `restartCurrentTranscodeHLS` did not
        // (it occupied the fresh-load slot instead), which is how two
        // replacements could run at once. Here the sub-state is the guard, so
        // a second replan — from either pipeline — is refused. A renewal in
        // flight refuses one too: it is about to rewrite the same session.
        switch playing.sub {
        case .replanning, .renewingSource:
            return (.playing(playing), [])
        case .steady, .recovering, .ridingOutOutage, .ended:
            break
        }
        let identity = playing.identity
        var playing = playing
        playing.sub = .replanning(intent)
        var effects: [Effect] = []
        switch intent.kind {
        case .serverReplan:
            // `attemptProtocolV3Replan`'s prologue: the 10 s
            // progress heartbeat is cancelled for the whole round trip (it is
            // restarted by the adopt path's `startProgressReporting`), the
            // loading overlay is raised, and the buffering flag is cleared.
            playing.transport.isBuffering = false
            effects.append(.cancelTimer(.progress))
            effects.append(.publish(presentation(for: .playing(playing), isLoading: true, bufferingCause: "replan")))
        case .transcodeRestart(let restart):
            // `restartCurrentTranscodeHLS` has a different prologue: it takes
            // the fresh-load slot (so no heartbeat cancel) and reports
            // progress against the *outgoing* session at the position it is
            // leaving, guarded the same way. A quality restart
            // leaves from where it is; a seek re-anchor carries its origin.
            // The dispose and the overlay are the two obligations that happen
            // outside the request — see `ReplanIntent.Kind.transcodeRestart`.
            let outgoingPosition: Double
            switch restart {
            case .qualityChange: outgoingPosition = playing.transport.positionSeconds
            case .seekReanchor(let origin): outgoingPosition = origin
            }
            if outgoingPosition.isFinite, outgoingPosition >= 0 {
                effects.append(
                    .reportProgress(identity, position: outgoingPosition, isPaused: true)
                )
            }
        }
        effects.append(.replan(intent, identity))
        return (.playing(playing), effects)
    }

    // MARK: - Scene phase

    /// `handleScenePhase` as three data tables.
    ///
    /// The platform is a **parameter**, not an `#if os`: `SiloTests` is an
    /// iOS-only bundle (`project.yml` `SiloTests: platform: iOS`), so an
    /// `#if os(tvOS)` assertion in a test compiles and never runs, and the
    /// tvOS table — suspend/resume, the interruption pause, the error-screen
    /// suspend — is the riskiest surface in this package. `#if os` therefore
    /// appears once, in `ScenePhasePlatform.current`, at the single call site.
    static func scenePhase(
        _ state: PlaybackState,
        phase: ScenePhase,
        platform: ScenePhasePlatform,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        switch platform {
        case .tvOS: return tvOSScenePhase(state, phase: phase, now: now)
        case .macOS: return macOSScenePhase(state, phase: phase)
        case .iOS: return iOSScenePhase(state, phase: phase)
        }
    }

    private static func tvOSScenePhase(
        _ state: PlaybackState,
        phase: ScenePhase,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        switch phase {
        case .inactive:
            // `pauseForForegroundInterruptionIfNeeded`. Its
            // only guards are `!isBackgroundSuspended` and `isPlaying`, so a
            // load in flight is interrupted exactly like a live one — hence
            // the slot rather than `case .playing` (see `interruptionSlot`).
            guard let slot = interruptionSlot(state), !slot.transport.isPaused else {
                return (state, [])
            }
            let position = slot.transport.positionSeconds
            let next = mutatingInterruptionSlot(state) { interruption, _ in
                interruption = Playing.Interruption(
                    wasPlaying: true,
                    positionSeconds: position,
                    recoveryDeadline: now,
                    didAutoRecover: false,
                    isPending: true
                )
            }
            // It calls `avPlayerBackend?.pause()` and never writes `isPlaying`;
            // see `transport(_:command:)`. Mid-load the engine for this
            // `LoadID` may not exist yet, in which case the actor drops the
            // command structurally — which is what `avPlayerBackend?` does in
            // the view model once `beginFreshLoad`'s dispose has run.
            return (
                next,
                [.cancelTimer(.interruptionRecovery), .transport(.pause, slot.loadID)]
            )

        case .background:
            // `suspendForBackground`. It suspends from a load in flight too:
            // `makeSuspendedPlaybackContext` only needs `lastLoadRequest` —
            // rebuilt through `copyForRecovery` from the live selection, which
            // is why the context carries the *resolved* request and not the
            // one the load started with.
            let context: SuspendedContext
            switch state {
            case .playing(let playing):
                context = SuspendedContext(
                    request: recoveryRequest(
                        playing.request,
                        selections: playing.resumeSelections,
                        preferringSelectedFileId: false,
                        keepingOfflineDownload: true
                    ),
                    resumePosition: currentPosition(state),
                    retainedLoadID: playing.loadID
                )
            case .preparing(let preparing):
                // `makeSuspendedPlaybackContext` snapshots `currentTime`,
                // which a load in flight still has: the outgoing
                // playhead before the session resolves, the new session's
                // position after `adoptPreparedPlayback` set it.
                context = SuspendedContext(
                    request: recoveryRequest(
                        preparing.request,
                        selections: preparing.resumeSelections,
                        preferringSelectedFileId: false,
                        keepingOfflineDownload: true
                    ),
                    resumePosition: currentPosition(state),
                    retainedLoadID: preparing.loadID
                )
            case .failed(let failure, _, _, let request, let position, let selections):
                // `suspendForBackground` needs only `lastLoadRequest`, and
                // `finalizeTerminalPlaybackError` keeps it — so backgrounding
                // the Apple TV on the error screen does suspend today (the
                // wake path at then awaits an explicit resume).
                // The failure travels with the context so the projection keeps
                // publishing `error`.
                guard let request else { return (state, []) }
                context = SuspendedContext(
                    request: recoveryRequest(
                        request,
                        selections: selections,
                        preferringSelectedFileId: false,
                        keepingOfflineDownload: true
                    ),
                    resumePosition: position,
                    failure: failure,
                    retainedLoadID: nil
                )
            case .idle, .suspended, .disposed:
                return (state, [])
            }
            let next = PlaybackState.suspended(context)
            var effects: [Effect] = suspendTimerCancellations()
            // `suspendForBackground` publishes here: the
            // buffering capsule and the loading overlay are cleared and
            // `isPlaying` goes false, after the sweep and before the dispose.
            // A suspended load produces no further engine ticks for the actor
            // to coalesce, and the wake screen awaits an explicit resume, so
            // without this publish the Apple TV would come back to a stale
            // "playing" projection — or to a loading overlay the suspend
            // interrupted mid-load.
            effects.append(.publish(presentation(for: next, loadingReason: "background_suspend", bufferingCause: "background_suspend")))
            if let loadID = state.loadID {
                // `suspendForBackground` disposes the backend and
                // deliberately leaves `sourceProxy` running — the resume's own
                // `beginLoad` is what stashes and stops it.
                effects.append(.disposeEngine(loadID, sourceCache: .retainProxy))
            }
            if let identity = state.identity {
                // Registered but swept by nothing: the bridge's identity guard
                // is what makes a resume that overtakes it safe.
                effects.append(
                    .stopSession(identity, position: context.resumePosition, isPaused: true)
                )
            }
            return (next, effects)

        case .active:
            // A suspended player awaits an explicit resume; only the controls
            // are revealed, which is view-model state.
            //
            // The re-arm guards only on `isBackgroundSuspended`
            // and a pending, `wasPlaying` interruption, so it also fires for a
            // load still in flight — one this arm itself interrupted, or one a
            // `preserveInterruptionState` reload carried the interruption into.
            guard let slot = interruptionSlot(state),
                  var interruption = slot.interruption,
                  interruption.isPending,
                  interruption.wasPlaying else {
                return (state, [])
            }
            interruption.recoveryDeadline = now.addingTimeInterval(interruptionRecoveryTimeout)
            let rearmed = interruption
            let next = mutatingInterruptionSlot(state) { slotInterruption, _ in
                slotInterruption = rearmed
            }
            // The `.active` arm sets only `isLoading = true; error = nil`
            // and then calls `avPlayerBackend?.play()`; the
            // resulting `onPauseChange` is what republishes `isPlaying`.
            return (
                next,
                [
                    .publish(presentation(for: next, isLoading: true)),
                    .transport(.play, slot.loadID),
                    .schedule(
                        .interruptionRecovery,
                        after: .seconds(interruptionRecoveryTimeout),
                        slot.loadID
                    ),
                ]
            )

        @unknown default:
            return (state, [])
        }
    }

    private static func macOSScenePhase(
        _ state: PlaybackState,
        phase: ScenePhase
    ) -> (PlaybackState, [Effect]) {
        switch phase {
        case .background:
            // Still "pause on background" (design §7 item 6: recorded, not
            // changed — changing it is a product call). issues
            // the pause and leaves `isPlaying` to `onPauseChange`.
            guard case .playing(let playing) = state, !playing.transport.isPaused else {
                return (state, [])
            }
            return (state, [.transport(.pause, playing.loadID)])
        case .inactive, .active:
            return (state, [])
        @unknown default:
            return (state, [])
        }
    }

    private static func iOSScenePhase(
        _ state: PlaybackState,
        phase: ScenePhase
    ) -> (PlaybackState, [Effect]) {
        switch phase {
        case .background:
            guard case .playing(let playing) = state, !playing.transport.isPaused else {
                return (state, [])
            }
            // AirPlay plays on the receiver and PiP keeps its floating window:
            // pausing either would stop what the user is watching.
            if playing.transport.isExternalPlaybackActive { return (state, []) }
            if playing.transport.isPictureInPictureEngaged { return (state, []) }
            // The third exemption — automatic PiP that has not published
            // `willStart` yet, held for one 1 s grace window — stays with the
            // iOS shell: `PictureInPictureCoordinator.isPossible` is not
            // control-plane state and its grace timer is a UI timer
            // (deliberately absent from `TimerID`).
            //
            // `pauseBackgroundPlaybackIfUnrouted` issues the
            // pause and leaves `isPlaying` to `onPauseChange`.
            return (state, [.transport(.pause, playing.loadID)])
        case .inactive, .active:
            // `.active` cancels the PiP background grace, which is that same
            // UI timer and therefore the shell's.
            return (state, [])
        @unknown default:
            return (state, [])
        }
    }

    /// `suspendForBackground`'s sweep, restricted to the control-plane keys:
    /// the interruption, ride-through and outage-recovery timers. The shell's
    /// half of the same suspend is `tasks.cancelAll(in: .interaction)`, which
    /// covers only the UI-affordance tasks.
    private static func suspendTimerCancellations() -> [Effect] {
        [
            .cancelTimer(.interruptionRecovery),
            .cancelTimer(.sourceOutageRideThrough),
            .cancelTimer(.serverOutageRecovery),
            .cancelTimer(.backgroundRenewal),
            .cancelTimer(.staleSessionRecovery),
            .cancelTimer(.freshLoad),
            .cancelTimer(.protocolV3Replan),
            .cancelTimer(.progress),
            .cancelTimer(.seekFilterTimeout),
        ]
    }

    // MARK: - Engine events

    /// Publish cadence: the high-frequency transport arms (`.time`,
    /// `.duration`, `.buffering`, `.bufferedAhead`) mutate `TransportState` and
    /// emit **no** `.publish`. That is deliberate, not a claim that those
    /// projections are unowned — `Presentation.currentTime`/`.duration`/
    /// `.isBuffering`/`.bufferedAheadSeconds`/`.playbackRunwaySeconds` are all
    /// populated by `presentation(for:)`. The time arm fires at the AVPlayer
    /// periodic-observer rate, so the session actor coalesces these into one
    /// main-actor publish per tick rather than the reducer emitting an effect
    /// per event.
    private static func engine(
        _ state: PlaybackState,
        event: EngineEvent,
        loadID: LoadID,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        // The identity guard that replaces the by-value generation compare.
        guard state.loadID == loadID else { return (state, []) }

        switch event {
        case .fileLoaded(let reason):
            return fileLoaded(state, loadID: loadID, reason: reason)

        case .firstFrame(let ms):
            guard let identity = state.identity else { return (state, []) }
            return (state, [.reportFirstFrame(identity, ms: ms)])

        case .time(let seconds):
            return time(state, seconds: seconds, now: now)

        case .duration(let seconds):
            guard case .playing(var playing) = state else { return (state, []) }
            // `onDurationChange` adopts a backend duration only
            // when the already-extracted pure predicate says so: never under a
            // `.transcode` delivery (a growing transcode playlist reports the
            // *published* length, which is shorter than the real one and would
            // shrink the scrubber and corrupt the near-end rule), and otherwise
            // only when it does not go backwards. One owner: the reducer calls
            // it rather than restating it.
            guard shouldAdoptBackendDuration(
                seconds,
                currentDuration: playing.transport.durationSeconds,
                delivery: playing.plan.delivery
            ) else {
                return (state, [])
            }
            playing.transport.durationSeconds = seconds
            return (.playing(playing), [])

        case .pauseChanged(let isPaused):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.transport.isPaused = isPaused
            let next = PlaybackState.playing(playing)
            // `onPauseChange` is the sole writer of `isPlaying` — and it wrote
            // nothing else. Base's `onPauseChange` wrote
            // `isPlaying` and never touched the loading overlay, so this
            // publish carries no overlay decision at all: `isLoading: nil`
            // means "leave it where it is". Deriving it from state here
            // under-reported the tvOS interruption-resume overlay (a field,
            // not a `Sub` case) and over-reported the quality-restart replan
            // (whose overlay is raised at the adopt, contract note (d)).
            return (
                next,
                [.publish(presentation(for: next, isLoading: nil))]
            )

        case .buffering(let isBuffering):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.transport.isBuffering = isBuffering
            return (.playing(playing), [])

        case .bufferedAhead(let buffered):
            guard case .playing(var playing) = state,
                  buffered.playableAheadSeconds.isFinite,
                  buffered.runwaySeconds.isFinite else {
                return (state, [])
            }
            playing.transport.bufferedAheadSeconds = max(0, buffered.playableAheadSeconds)
            playing.transport.runwaySeconds = max(0, buffered.runwaySeconds)
            return (.playing(playing), [])

        case .stats:
            // `PlaybackStatsComposer` on the shell is the single owner of the
            // stats row (it swaps the origin host back in and adds the
            // proxy/cache rows), so the control plane keeps no copy.
            return (state, [])

        case .externalPlayback(let active):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.transport.isExternalPlaybackActive = active
            return (.playing(playing), [])

        case .endOfFile:
            return endOfFile(state)

        case .failed(let failure):
            // Not decided here: the actor asks `RecoveryPolicy` and feeds the
            // decision back as `.recovery(action, loadID)`. The *text* is kept,
            // because the server-HLS fallback rung's replan carries it as its
            // `message` and `RecoveryAction` has no room for it (see
            // `Playing.lastFailureMessage`). It is recorded on `Preparing` too:
            // a startup failure arrives before the first `fileLoaded`, and the
            // fallback rung it feeds is reachable from there (see
            // `promotedForRecovery`).
            switch state {
            case .playing(var playing):
                playing.lastFailureMessage = failure.legacyMessage
                return (.playing(playing), [])
            case .preparing(var preparing):
                preparing.lastFailureMessage = failure.legacyMessage
                return (.preparing(preparing), [])
            case .idle, .suspended, .failed, .disposed:
                return (state, [])
            }

        case .tracks, .chapters, .timelineOffset, .sidecarTracksRegistered,
             .externalPlaybackAllowed, .externalPlaybackUnavailable:
            // Track, chapter, timeline and external-route projections belong
            // to the track coordinator and the presentation model.
            return (state, [])

        case .recoveryAction:
            // Wave 2b's shell-executed recovery arm. The actor unwraps it into
            // `PlayerEvent.recovery(action, loadID)` and re-enters through
            // `recovery(_:action:loadID:)`, which is where the decision is
            // turned into state — never here.
            return (state, [])
        }
    }

    private static func fileLoaded(
        _ state: PlaybackState,
        loadID: LoadID,
        reason: String
    ) -> (PlaybackState, [Effect]) {
        switch state {
        case .preparing(let preparing):
            guard let plan = preparing.plan, let identity = preparing.identity else {
                return (state, [])
            }
            // `handleFileLoaded` asserts the load is playing:
            // it clears the error and the EOF latch and sets `isPlaying = true`
            // before `onPauseChange` has said anything.
            var transport = preparing.transport
            transport.isPaused = false
            let playing = Playing(
                loadID: preparing.loadID,
                identity: identity,
                plan: plan,
                request: preparing.request,
                adoption: preparing.adoption,
                // The playhead and duration `adoptPreparedPlayback` established
                // before the engine load, carried on
                // `Preparing.transport` — publishing a blank `TransportState`
                // here would assert 0/0 on every load and every in-place
                // replan, and would report 0 on the next progress tick.
                transport: transport,
                sub: .steady,
                seek: nil,
                activeQualityId: preparing.activeQualityId,
                hasProtocolV3: preparing.hasProtocolV3,
                resumeSelections: preparing.resumeSelections,
                // A `preserveInterruptionState` load rides its pending
                // interruption across the reload; `fileLoaded` is what
                // completes it (below).
                interruption: preparing.interruption
            )
            var effects: [Effect] = [.cancelTimer(.serverOutageRecovery)]
            let recovered = completingInterruption(playing, effects: &effects)
            let next = PlaybackState.playing(recovered)
            effects.append(
                .schedule(.progress, after: .seconds(progressReportIntervalSeconds), loadID)
            )
            effects.append(.publish(presentation(for: next, loadingReason: reason)))
            return (next, effects)

        case .playing(var playing):
            // A replacement item inside the same load (in-route reload,
            // reanchor): the load is established again.
            playing.sub = .steady
            var effects: [Effect] = [.cancelTimer(.serverOutageRecovery)]
            let recovered = completingInterruption(playing, effects: &effects)
            let next = PlaybackState.playing(recovered)
            // `handleFileLoaded` calls `startProgressReporting()`
            // unconditionally, and that cancels and restarts the 10 s
            // heartbeat — so an in-route reload re-phases it here too, exactly
            // as the first `fileLoaded` of a load does. `.schedule` re-arms the
            // keyed timer, which is how the `.preparing` branch above spells
            // the same call.
            effects.append(
                .schedule(.progress, after: .seconds(progressReportIntervalSeconds), loadID)
            )
            effects.append(.publish(presentation(for: next, loadingReason: reason)))
            return (next, effects)

        case .idle, .suspended, .failed, .disposed:
            return (state, [])
        }
    }

    /// `handleFileLoaded`'s
    /// `completeInterruptionRecoveryIfNeeded(observedTime:requiresForwardProgress: false)`:
    /// a stream that reached `fileLoaded` **is** the recovery landing, so the
    /// pending interruption is completed
    /// there and then and the recovery timer is cancelled — it does not wait
    /// for a forward time report. Leaving it pending let a scene `.active` in
    /// that window re-publish the loading overlay and re-arm the timer.
    private static func completingInterruption(
        _ playing: Playing,
        effects: inout [Effect]
    ) -> Playing {
        guard let interruption = playing.interruption, interruption.isPending else {
            return playing
        }
        var playing = playing
        playing.interruption = nil
        effects.append(.cancelTimer(.interruptionRecovery))
        return playing
    }

    private static func time(
        _ state: PlaybackState,
        seconds: Double,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        // `seconds` is movie time: `PlaybackEngineSession` applies the backend's
        // timeline offset before the event leaves it (the conversion base ran
        // as `seconds + playbackTimelineOffset`), so the reducer
        // compares like with like — against the adopted `movieTime(for:)`
        // position, against `SeekRequest.targetSeconds`, and on the wire.
        guard case .playing(var playing) = state, seconds.isFinite else { return (state, []) }
        // `onTimeChange` drops reports once the EOF latch is set.
        if case .ended = playing.sub { return (state, []) }

        // Ahead of the seek filter: outside an explicit seek
        // playback time is monotonic, so a report that jumps backwards is a
        // loopback replacement item's anchor frame, not a playhead. Letting it
        // through would drag the scrubber and the progress reporter back —
        // the exact bug the predicate was added for. One owner: the reducer
        // calls the already-extracted pure predicate rather than restating it.
        if isUnexpectedBackwardPlaybackTime(
            seconds,
            currentTime: playing.transport.positionSeconds,
            explicitSeekInFlight: playing.seek != nil
        ) {
            return (state, [])
        }

        var effects: [Effect] = []
        if let request = playing.seek {
            guard seekHasLanded(request, observedSeconds: seconds) else {
                // Stale drainage frame: keep the optimistic target.
                return (state, [])
            }
            playing.seek = nil
            effects.append(.cancelTimer(.seekFilterTimeout))
        }
        playing.transport.positionSeconds = seconds

        // `completeInterruptionRecoveryIfNeeded`.
        if var interruption = playing.interruption,
           interruption.isPending,
           seconds >= interruption.positionSeconds + interruptionResumeSuccessThresholdSeconds {
            interruption.isPending = false
            playing.interruption = nil
            effects.append(.cancelTimer(.interruptionRecovery))
            // The one publish this high-frequency arm emits, and only on the
            // tick that completes a recovery: `completeInterruptionRecoveryIfNeeded`
            // took the loading overlay down under its own reason and dropped
            // the published deadline the tvOS resume banner reads.
            effects.append(
                .publish(
                    presentation(for: .playing(playing), loadingReason: "interruption_recovered")
                )
            )
        }
        return (.playing(playing), effects)
    }

    private static func endOfFile(_ state: PlaybackState) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }
        // `handleEndOfFile` returns immediately while server-outage recovery is
        // active. The recovery keeps the same `LoadID` while it
        // disposes the engine, so a late EOF from the engine being torn down
        // still passes the identity guard — accepting it would flip the load to
        // `.ended`, cancel the outage timer and strand the player on the
        // postroll with the recovery half-done.
        if case .recovering(let step) = playing.sub,
           step == .recoveringFromServerOutage || step == .waitingForServerReady {
            return (state, [])
        }
        // DIVERGENCE (documented): `handleEndOfFile` never touches
        // the replan slot or the renewal's session-id echo, so today an
        // item draining while a replacement is in flight sets the EOF latch
        // *and* lets the replacement land. `Sub` is exclusive, so accepting it
        // here would overwrite `.replanning`/`.renewingSource` and the
        // server's answer would then be refused — stranding the load behind
        // the loading overlay with no event able to clear it. The replacement
        // keeps the load; its `fileLoaded` re-establishes playback and, if the
        // stream really is at its end, the replacement drains too and the
        // latch is set then.
        switch playing.sub {
        case .replanning, .renewingSource: return (state, [])
        case .steady, .recovering, .ridingOutOutage, .ended: break
        }
        playing.sub = .ended
        // `handleEndOfFile` clears all three published transport bits together:
        // `clearLoadingOverlay`, `setBuffering(false, cause:
        // "end_of_file")` and the one documented explicit `isPlaying = false`.
        // Leaving `isBuffering` set carried the buffering capsule onto the
        // postroll, where nothing would ever clear it — the engine is drained,
        // so no further `.buffering(false)` arrives.
        playing.transport.isBuffering = false
        playing.transport.isPaused = true
        if playing.transport.durationSeconds.isFinite, playing.transport.durationSeconds > 0 {
            playing.transport.positionSeconds = playing.transport.durationSeconds
        }
        let next = PlaybackState.playing(playing)
        return (
            next,
            [
                .cancelTimer(.serverOutageRecovery),
                // Nothing left to ride out: the stream drained. Legacy kept
                // polling here but its escalation was a no-op behind
                // `attemptServerOutageRecovery`'s `!hasReachedEndOfFile` gate;
                // dropping the loop is that gate, and it keeps the carried
                // ride-through from being adopted by the autoplay that follows.
                .cancelTimer(.sourceOutageRideThrough),
                .transport(.pause, playing.loadID),
                .publish(presentation(for: next, loadingReason: "end_of_file", bufferingCause: "end_of_file")),
            ]
        )
    }

    // MARK: - Session events

    private static func session(
        _ state: PlaybackState,
        event: SessionEvent,
        identity: SessionIdentity,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        switch event {
        case .prepared(let prepared, let plan, let loadID):
            guard case .preparing(var preparing) = state,
                  preparing.loadID == loadID,
                  preparing.phase == .resolvingSession else {
                // A prepare for a superseded load: dropped structurally.
                return (state, [])
            }
            preparing.identity = identity
            preparing.plan = plan
            preparing.phase = .startingEngine
            preparing.transport = adopting(
                preparing.transport,
                prepared: prepared.value,
                adoption: preparing.adoption
            )
            preparing.activeQualityId = prepared.value.activeQualityId
            preparing.hasProtocolV3 = prepared.value.protocolV3 != nil
            preparing.request = adoptedRequest(preparing.request, prepared: prepared.value)
            preparing.resumeSelections.selectedFileId = prepared.value.selectedVersion.fileId
            var effects: [Effect] = []
            // `adoptPreparedPlayback` reports plan execution **before**
            // `loadStream`, so it is emitted here and not at `fileLoaded`: a
            // load that dies between the plan and
            // the first frame still reported that it started executing.
            if preparing.adoption.reportsPlanExecutionStarted {
                effects.append(.reportPlanExecutionStarted(identity))
            }
            effects.append(.loadEngine(plan, preparing.loadID, reuseEngine: false))
            return (.preparing(preparing), effects)

        case .replanned(let prepared, let plan):
            guard case .playing(let playing) = state,
                  case .replanning(let intent) = playing.sub,
                  identity.belongsToSameSession(as: playing.identity) else {
                return (state, [])
            }
            // The engine instance may survive (`prepareBackend(for:)`), the
            // load identity never does: callbacks re-bind to a new `LoadID`.
            let reuseEngine = intent.kind == .serverReplan && plan.engine == playing.plan.engine
            let loadID = LoadID()
            let adoption = PlaybackAdoption.replan(intent.kind)
            var resumeSelections = playing.resumeSelections
            resumeSelections.selectedFileId = prepared.value.selectedVersion.fileId
            let preparing = Preparing(
                loadID: loadID,
                identity: identity,
                phase: .startingEngine,
                // The replay request travels through the adopt, exactly as
                // `lastLoadRequest` does: the quality latch first, then the
                // authorised plan's own selections (see `adoptedRequest`).
                request: adoptedRequest(
                    playing.request,
                    prepared: prepared.value,
                    qualitySwitchOverride: qualitySwitchOverride(
                        for: intent,
                        prepared: prepared.value
                    )
                ),
                options: LoadOptions(),
                adoption: adoption,
                plan: plan,
                // A replan never resets the transport; `adoptPreparedPlayback`
                // re-anchors it at the replacement session's position and
                // duration (with the *current* duration as the fallback), which
                // is what a tvOS suspend landing mid-replan must resume from.
                transport: adopting(playing.transport, prepared: prepared.value, adoption: adoption),
                activeQualityId: prepared.value.activeQualityId,
                hasProtocolV3: prepared.value.protocolV3 != nil,
                resumeSelections: resumeSelections,
                interruption: playing.interruption
            )
            var effects: [Effect] = []
            // Same position as the fresh load: reported before the engine load.
            // The in-place transcode restart deliberately never
            // reports it ("preserved drift").
            if adoption.reportsPlanExecutionStarted {
                effects.append(.reportPlanExecutionStarted(identity))
            }
            effects.append(.loadEngine(plan, loadID, reuseEngine: reuseEngine))
            return (.preparing(preparing), effects)

        case .replanUnavailable:
            guard case .playing(let playing) = state,
                  case .replanning(let intent) = playing.sub,
                  identity.belongsToSameSession(as: playing.identity) else {
                return (state, [])
            }
            return fail(state, failure: PlaybackFailure(legacyMessage: intent.message))

        case .terminal(let failure):
            guard let current = state.identity,
                  identity.belongsToSameSession(as: current) else {
                return (state, [])
            }
            return fail(state, failure: PlaybackFailure(legacyMessage: failure.message))

        case .renewed(let prepared, let replacing):
            guard case .playing(var playing) = state,
                  case .renewingSource(let renewal) = playing.sub,
                  // The one mutation that rewrites `Playing.identity`, so it
                  // needs its own guard: a renewal mints a new server session
                  // by definition, which is why `belongsToSameSession` cannot
                  // be it. This is the active-session-id versus
                  // stale-session-id re-check, expressed over the identity the
                  // renewal was issued against.
                  renewal.issuedFor == replacing else {
                return (state, [])
            }
            // The proxy was retargeted in place; player, remuxer and cache are
            // untouched, so the load survives with a new session identity —
            // and with the renewed session's facts: a renewal can land on a
            // re-probed source, and `attemptBackgroundSessionRenewal` adopts
            // its duration, quality label and selected version too.
            // Keeping the outgoing ones would publish a
            // stale scrubber length and a stale quality label for the rest of
            // the load. The playhead is deliberately *not* adopted: the
            // retarget is silent, playback never stopped.
            playing.identity = identity
            playing.transport.durationSeconds = adoptedDuration(
                prepared.value,
                fallback: playing.transport.durationSeconds
            )
            playing.activeQualityId = prepared.value.activeQualityId
            playing.hasProtocolV3 = prepared.value.protocolV3 != nil
            // The renewal runs the same `adoptProtocolV3RenewalIntent` the
            // load and replan adopts do, so the replay request
            // tracks the renewed plan too.
            playing.request = adoptedRequest(playing.request, prepared: prepared.value)
            playing.resumeSelections.selectedFileId = prepared.value.selectedVersion.fileId
            playing.sub = .steady
            return (.playing(playing), [])

        case .renewalFailed:
            guard case .playing(var playing) = state,
                  case .renewingSource(let renewal) = playing.sub,
                  // Same guard as `.renewed`, for the same reason (design §4
                  // I2: every mutation is conditional on the identity the
                  // effect was issued against). A load can cycle
                  // `.playing` → `.preparing` → `.playing` → a second
                  // `.renewingSource` while the first renewal's failure is
                  // still in flight; without this, that stale answer would
                  // clear the *new* renewal's single-flight slot.
                  renewal.issuedFor == identity else {
                return (state, [])
            }
            // Escalation (transient counter, then the visible renewal) is
            // `RecoveryPolicy`'s call.
            playing.sub = .steady
            return (.playing(playing), [])
        }
    }

    // MARK: - Recovery actions

    private static func recovery(
        _ state: PlaybackState,
        action: RecoveryAction,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        // Startup reachability — see `promotedForRecovery`. The seven arms
        // listed here are the mid-ladder rungs, and each one takes ownership of
        // the load (a replan slot, a renewal slot, the visible recovery's
        // steps); they are `.playing`-shaped because the events that answer
        // them — `.replanned`, `.replanUnavailable`, `.renewed`, the
        // `.serverOutageRecovery` timer — are. Every other arm already has a
        // deliberate non-`.playing` behaviour (the ride-through continuation,
        // `inRouteRecovery`, `.autoRecoverInterruption`, `.fail`) and is left
        // exactly as it is.
        switch action {
        case .requestServerReplan, .switchRoute, .renewSourceInBackground,
             .renewSessionFresh, .recoverFromServerOutage, .waitForServerReady:
            if let promoted = promotedForRecovery(state) {
                return recovery(promoted, action: action, now: now)
            }
        default:
            break
        }
        switch action {
        case .requestServerReplan(let classification, let message):
            guard case .playing(let playing) = state else { return (state, []) }
            return requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: playing.transport.positionSeconds,
                    classification: classification,
                    message: message
                )
            )

        case .switchRoute(.serverHLS(let classification)):
            guard case .playing(let playing) = state else { return (state, []) }
            // `requestServerHLSRouteFallback` — the same replan call with the
            // route classification. `RecoveryAction` carries no failure text,
            // so the message is the one this load last reported
            // (`Playing.lastFailureMessage`), which is exactly what
            // `performServerHLSRouteFallback(classification:failure:)` passed:
            // it is the replan's wire `error_cause` and the wall text if the
            // server answers `replanUnavailable`.
            //
            // `.runRecovery` carries the shell's half, which is the
            // `[CMP-ROUTE] … requesting a server HLS replan` trace line: the
            // rung it names is what a console capture reads the fallback
            // ladder from. It is emitted only when the replan was actually
            // minted — `requestServerHLSReplan` logged after its
            // "no replan already running" guard, not before it.
            let (next, effects) = requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: playing.transport.positionSeconds,
                    classification: classification,
                    message: playing.lastFailureMessage ?? ""
                )
            )
            guard !effects.isEmpty else { return (next, effects) }
            return (next, [.runRecovery(action, playing.loadID)] + effects)

        case .switchRoute(.loopbackFallback):
            // The offline native-direct → loopback rung. The engine session
            // builds the fallback plan (the action carries none) and reloads
            // the engine in place.
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.switchingRoute)
            // rung 7: the progress loop is stopped for every rung at
            // or below the interruption rung, and only for those.
            return (
                .playing(playing),
                [.cancelTimer(.progress), .runRecovery(action, playing.loadID)]
            )

        case .renewSourceInBackground(let reason):
            guard case .playing(var playing) = state else { return (state, []) }
            // The structural half of the single-flight the `*SessionId` echo
            // provided, and the only half that can state it: a renewal must
            // not overwrite an in-flight **replan** either, which
            // `RecoveryPolicy` does not model on the `.sessionMissing` path.
            // The policy's `backgroundRenewalInFlight` closes the other window
            // — decision to reduction — which this switch cannot see.
            switch playing.sub {
            case .renewingSource, .replanning:
                return (state, [])
            case .steady, .recovering, .ridingOutOutage, .ended:
                break
            }
            let renewal = SourceRenewal(
                reason: reason,
                observedPosition: playing.transport.positionSeconds,
                startedAt: now,
                issuedFor: playing.identity
            )
            playing.sub = .renewingSource(renewal)
            return (.playing(playing), [.renewSource(renewal, playing.identity)])

        case .renewSessionFresh:
            // `attemptStaleSessionRenewal`: a visible renewal
            // is a fresh load of the *re-resolved* request at the observed
            // position, preceded by a content-scoped force-overwrite progress
            // write (the session it would otherwise report against is the one
            // that vanished).
            guard case .playing(let playing) = state else { return (state, []) }
            let position = playing.transport.positionSeconds.isFinite
                ? max(0, playing.transport.positionSeconds)
                : 0
            // `durationHint`: `duration` when it is usable, else the selected
            // version's. The version's duration lives with the
            // track/version half, so the plan-side fallback is 0 here — the
            // same value `currentSelectedVersion?.duration ?? 0` produces when
            // there is no version.
            let durationHint = playing.transport.durationSeconds.isFinite
                && playing.transport.durationSeconds > 0
                ? playing.transport.durationSeconds
                : 0
            let (next, effects) = beginLoad(
                from: state,
                request: recoveryRequest(
                    playing.request,
                    selections: playing.resumeSelections,
                    preferringSelectedFileId: true,
                    keepingOfflineDownload: false
                ),
                adoption: .freshLoad(.recovery),
                options: LoadOptions(
                    progressPosition: nil,
                    resumePosition: position,
                    allowNearEndResume: true,
                    preserveInterruptionState: true
                )
            )
            return (
                next,
                [
                    // `backgroundRenewalTask?.cancel()` first:
                    // a late `retargetOrigin` from the silent renewal would
                    // land mid-teardown. The reducer's structural drop of
                    // `.renewed` does not cover it — the actor performs the
                    // retarget inside `.renewSource` without coming back
                    // through the reducer.
                    .cancelTimer(.backgroundRenewal),
                    .syncProgress(
                        contentId: playing.request.contentId,
                        position: position,
                        duration: durationHint,
                        forceOverwrite: true
                    ),
                    // `self.progressTask?.cancel()` between the sync and the
                    // reload — the outgoing heartbeat would report
                    // against the session that vanished.
                    .cancelTimer(.progress),
                ] + effects
            )

        case .autoRecoverInterruption:
            // `triggerAutomaticInterruptionRecovery`, whose
            // guards are `lastLoadRequest`, an interruption and
            // `!didAutoRecover` — no state precondition, so a reload that is
            // itself interrupted recovers again from `.preparing`.
            guard let slot = interruptionSlot(state),
                  var interruption = slot.interruption,
                  !interruption.didAutoRecover,
                  let request = retryRequest(for: state) else {
                return (state, [])
            }
            interruption.didAutoRecover = true
            interruption.isPending = true
            let recovering = interruption
            // One of the three hand-written `isPlaying = false`s —
            // the engine that would otherwise report it is about to be
            // replaced. The recovery timer is cancelled by hand even though
            // the load keeps the interruption itself.
            let paused = mutatingInterruptionSlot(state) { slotInterruption, transportState in
                slotInterruption = recovering
                transportState.isPaused = true
            }
            let (next, effects) = beginLoad(
                from: paused,
                request: request,
                adoption: .freshLoad(.recovery),
                options: LoadOptions(
                    progressPosition: interruption.positionSeconds,
                    resumePosition: interruption.positionSeconds,
                    allowNearEndResume: true,
                    preserveInterruptionState: true
                )
            )
            return (
                next,
                [.cancelTimer(.interruptionRecovery), .cancelTimer(.progress)] + effects
            )

        case .rideThroughOutage(let probeAfter):
            // The ride-through outlives one load: a replan taken during an
            // outage moves the state to `.preparing` while the replacement
            // stream is negotiated, and the poll that owns the 90 s escalation
            // (and the release of the `origin_outage` hold) has to keep
            // running through that window — legacy's loop was view-model
            // scoped and did (`runOutageRideThrough` re-resolved the live
            // session every turn and was gated on nothing else). Re-arm it
            // without touching a state that is not `.playing`.
            guard case .playing(var playing) = state else {
                guard let loadID = state.loadID else { return (state, []) }
                // `.runRecovery` carries the shell's half, and an outage ENTRY
                // (`probeAfter == .zero`) can land here: an origin outage
                // detected between `.loadEngine` and the
                // first `fileLoaded` is reduced while the state is
                // `.preparing`. Without it the entry would skip the
                // `[CMP-OUTAGE] ride-through started` breadcrumb, the
                // once-per-outage notice reset and the out-of-runway re-feed of
                // `showSourceOutageReconnectingNotice()`. The shell arm is
                // idempotent and self-gated on `probeAfter == .zero`, so a
                // continuation costs nothing.
                return (
                    state,
                    [
                        .runRecovery(action, loadID),
                        .pollServerHealth(.sourceOutageRideThrough, after: probeAfter, loadID),
                    ]
                )
            }
            // `RecoveryPolicy` single-flights the ENTRY (decideOriginOutage guards
            // on `context.outage == nil`) and then re-emits `.rideThroughOutage`
            // after every health probe as the CONTINUATION of the loop (the
            // 0, 1, 2, 4, 8, 8 s sequence). The reducer therefore
            // accepts the action whether or not it is already riding, and
            // ALWAYS schedules the one-shot poll again. The budget's origin,
            // the backoff and the once-per-outage notice latch are
            // `RecoveryContext.OutageState`'s — the sub-state is the marker,
            // not a second copy of them.
            playing.sub = .ridingOutOutage
            return (
                .playing(playing),
                [
                    .runRecovery(action, playing.loadID),
                    .pollServerHealth(.sourceOutageRideThrough, after: probeAfter, playing.loadID),
                ]
            )

        case .endOutageRideThrough:
            // The origin recovered. The release is unconditional on the
            // sub-state: a replan taken during the ride-through overwrote
            // `.ridingOutOutage`, and refusing the exit there would strand the
            // carried ride-through — every later session would adopt its
            // `origin_outage` hold with no owner left to release it, which is
            // the failure `RecoveryDriver.adoptOutageRideThrough` documents.
            guard let loadID = state.loadID else { return (state, []) }
            var next = state
            if case .playing(var playing) = state, case .ridingOutOutage = playing.sub {
                playing.sub = .steady
                next = .playing(playing)
            }
            // `.runRecovery` first: the shell's half reads the once-per-outage
            // notice latch to decide whether to show "Reconnected", and the
            // cancel below is what clears it (`endOutageRideThrough` read it
            // before `clearSourceOutageRideThroughState()`).
            return (
                next,
                [.runRecovery(action, loadID), .cancelTimer(.sourceOutageRideThrough)]
            )

        case .recoverFromServerOutage(let reason):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.recoveringFromServerOutage)
            // One of the three hand-written `isPlaying = false`s —
            // the engine that would report it is being disposed in the same
            // breath, so nothing else would ever clear the playing capsule.
            playing.transport.isPaused = true
            let next = PlaybackState.playing(playing)
            return (
                next,
                [
                    // In this order and *before* the teardown:
                    // "Outage recovery tears the proxy down; cancel any
                    // in-flight silent renewal so its retarget can't land
                    // mid-teardown, and end the ride-through (its watchdog
                    // suppression must not outlive the proxy)."
                    //
                    // Overwriting `Sub` from `.renewingSource` to `.recovering`
                    // drops the renewal's `.renewed` *event* structurally, but
                    // the actor performs `retargetOrigin` inside `.renewSource`
                    // without returning through the reducer, so the effect has
                    // to be cancelled explicitly — the same hazard
                    // `.renewSessionFresh` already cancels for. The
                    // ride-through poll would otherwise keep probing under a
                    // superseded sub-state.
                    //
                    // `clearSourceOutageRideThroughState`'s half of the retired
                    // external-stall suppression handshake needs no effect of
                    // its own: the backend that holds the suppression is
                    // disposed two effects below.
                    .cancelTimer(.backgroundRenewal),
                    .cancelTimer(.sourceOutageRideThrough),
                    .cancelTimer(.progress),
                    // A `source_entity_changed` outage is the
                    // one case where the cached prefix is *known* to belong to
                    // the replaced entity, so it must not be offered to the
                    // recovery plan. Every other reason stashes.
                    .disposeEngine(
                        playing.loadID,
                        sourceCache: reason == sourceEntityChangedReason ? .discard : .stash
                    ),
                    // `waitForServerReady` probes *first* and
                    // sleeps afterwards, so entering the visible recovery
                    // issues an immediate probe; the loop's own delays arrive
                    // as `.waitForServerReady(probeAfter:)` from the policy,
                    // which is the same "sleep, then probe" contract
                    // `RecoveryAction` documents.
                    .pollServerHealth(
                        .serverOutageRecovery,
                        after: .zero,
                        playing.loadID
                    ),
                    .publish(presentation(for: next, isReconnecting: true, loadingReason: "server_outage")),
                ]
            )

        case .waitForServerReady(let probeAfter):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.waitingForServerReady)
            return (
                .playing(playing),
                [.pollServerHealth(.serverOutageRecovery, after: probeAfter, playing.loadID)]
            )

        case .treatAsNaturalEnd:
            // The reducer's own end-of-stream transition, plus the shell half
            // `handleEndOfFile` owes: the premature-EOF classification, the
            // terminal breadcrumb and the Next Up hand-off. Without the
            // `.runRecovery` a near-end failure would set the postroll latch
            // and never present the postroll.
            let (next, effects) = endOfFile(state)
            guard let loadID = state.loadID, !effects.isEmpty else { return (next, effects) }
            return (next, effects + [.runRecovery(action, loadID)])

        case .fail(let failure):
            return fail(state, failure: failure)

        case .rebuildLocalSession:
            return inRouteRecovery(state, action: action, step: .rebuildingLocalSession)

        case .reloadItem, .reloadStartupItem:
            return inRouteRecovery(state, action: action, step: .reloadingItem)

        // Single-shot in-route actions: executed by the engine session, the
        // load stays `.steady` — exactly as the backend ladders behave today.
        //
        // Listed explicitly rather than caught by `default:` **because wave 2
        // owns `RecoveryAction`**: under a `default:` a case it adds would
        // silently become a bare `.runRecovery` that leaves the load steady,
        // with no compiler signal — which is precisely wrong for a multi-step
        // action (`.reloadItem` / `.rebuildLocalSession` both needed
        // `.recovering(step)`). This way a new case fails to compile until
        // someone classifies it.
        case .reassertPlay, .nudgeStartup, .reanchor,
             .deferUntilPlay, .resumePlayback:
            guard let loadID = state.loadID else { return (state, []) }
            return (state, [.runRecovery(action, loadID)])
        }
    }

    /// A load whose engine failed **before its first frame**, seen as the live
    /// load it is.
    ///
    /// `AVPlayerBackend` fires `onFileLoaded` only from
    /// `finishInitialLoadIfNeeded` (the initial-display gate), so a startup
    /// failure reduces while the state is still
    /// `.preparing(.startingEngine)`. The adopt that precedes `.loadEngine` has
    /// already set `hasProtocolV3`, so `RecoveryPolicy.decideEngineFailed`
    /// rung 4 answers `.requestServerReplan` for
    /// every V3 load, and rungs 9/10 answer `.switchRoute` for the offline
    /// native-direct and loopback routes.
    ///
    /// Base ran the whole ladder regardless of load state: `handlePlaybackError`
    /// guarded only on `hasReachedEndOfFile` and
    /// `engineSession != nil`, and `attemptProtocolV3Replan`
    /// guarded only on "no replan already running" and a loaded watch detail —
    /// neither of which the startup window fails. Dropping the rung instead
    /// leaves the player on the loading overlay for ever, with no wall, no
    /// fallback and no timeout.
    ///
    /// A load in `.startingEngine` has everything `Playing` models: a plan, a
    /// session identity, the replay request, the adopted playhead and duration,
    /// and a live `PlaybackEngineSession`. Promoting it is therefore a widening,
    /// not an invention — and it is what keeps the *answer* reachable, because
    /// the replan's `.replanned`, the renewal's `.renewed` and the visible
    /// recovery's health-probe timer are all `.playing`-scoped. Nothing here
    /// publishes a bare `.playing` presentation, so the overlay is not dropped
    /// by the promotion: the arms that publish carry the overlay state they
    /// mean, and `fileLoaded`'s `.playing` arm (the in-place replacement item)
    /// is what takes it down when the replacement stream establishes.
    private static func promotedForRecovery(_ state: PlaybackState) -> PlaybackState? {
        guard case .preparing(let preparing) = state,
              preparing.phase == .startingEngine,
              let plan = preparing.plan,
              let identity = preparing.identity else {
            // `.resolvingSession` has no engine, so no engine can have failed
            // for it, and no rung below has anything to act on.
            return nil
        }
        return .playing(
            Playing(
                loadID: preparing.loadID,
                identity: identity,
                plan: plan,
                request: preparing.request,
                adoption: preparing.adoption,
                transport: preparing.transport,
                sub: .steady,
                seek: nil,
                activeQualityId: preparing.activeQualityId,
                hasProtocolV3: preparing.hasProtocolV3,
                resumeSelections: preparing.resumeSelections,
                interruption: preparing.interruption,
                lastFailureMessage: preparing.lastFailureMessage
            )
        )
    }

    private static func inRouteRecovery(
        _ state: PlaybackState,
        action: RecoveryAction,
        step: RecoveryStep
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else {
            guard let loadID = state.loadID else { return (state, []) }
            return (state, [.runRecovery(action, loadID)])
        }
        playing.sub = .recovering(step)
        return (.playing(playing), [.runRecovery(action, playing.loadID)])
    }

    // MARK: - Timers

    private static func timer(
        _ state: PlaybackState,
        timerID: TimerID,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        switch timerID {
        case .seekFilterTimeout:
            guard case .playing(var playing) = state, playing.seek != nil else {
                return (state, [])
            }
            // The safety valve: no post-seek report arrived, so stop pinning
            // the scrubber to the optimistic target.
            playing.seek = nil
            return (.playing(playing), [])

        case .progress:
            guard case .playing(let playing) = state else { return (state, []) }
            return (
                state,
                [
                    .reportProgress(
                        playing.identity,
                        position: playing.transport.positionSeconds,
                        isPaused: playing.transport.isPaused
                    ),
                    .schedule(
                        .progress,
                        after: .seconds(progressReportIntervalSeconds),
                        playing.loadID
                    ),
                ]
            )

        case .interruptionRecovery:
            // The deadline task has no state precondition, and
            // a `preserveInterruptionState` load deliberately leaves the timer
            // armed, so it can fire while the replacement load
            // is still `.preparing` — hence the slot (see `interruptionSlot`).
            guard let slot = interruptionSlot(state),
                  let interruption = slot.interruption,
                  interruption.isPending,
                  !interruption.didAutoRecover,
                  now >= interruption.recoveryDeadline else {
                return (state, [])
            }
            return recovery(state, action: .autoRecoverInterruption, now: now)

        case .serverOutageRecovery:
            // The one task slot whose completion *is* a transition: a health
            // probe that reaches the server ends the visible recovery's wait
            // (`RecoveryPolicy.decideServerHealthProbe` clears the slot and
            // answers nothing), and the tail of `attemptServerOutageRecovery`
            // was the replacement load — `waitForServerReady`'s `true` return
            // landed on a fresh load with the `.recovery` origin, at the
            // position the outage interrupted and with the request rebuilt from
            // the live selections. Without it the player waits on "Reconnecting"
            // forever. The actor ingests this only on a reachable probe.
            guard case .playing(let playing) = state,
                  case .recovering(let step) = playing.sub,
                  step == .recoveringFromServerOutage || step == .waitingForServerReady else {
                return (state, [])
            }
            let resumePosition = playing.transport.positionSeconds.isFinite
                ? max(0, playing.transport.positionSeconds)
                : 0
            return beginLoad(
                from: state,
                request: recoveryRequest(
                    playing.request,
                    selections: playing.resumeSelections,
                    preferringSelectedFileId: true,
                    keepingOfflineDownload: false
                ),
                adoption: .freshLoad(.recovery),
                options: LoadOptions(
                    progressPosition: nil,
                    resumePosition: resumePosition,
                    allowNearEndResume: true,
                    preserveInterruptionState: true
                )
            )

        case .freshLoad, .protocolV3Replan, .staleSessionRecovery, .backgroundRenewal,
             .sourceOutageRideThrough:
            // Task slots, not deadlines: their completion arrives as a session
            // event or as a `RecoveryPolicy` decision.
            return (state, [])
        }
    }

    // MARK: - Terminal

    private static func fail(
        _ state: PlaybackState,
        failure: PlaybackFailure
    ) -> (PlaybackState, [Effect]) {
        // `finalizeTerminalPlaybackError` never resets `currentTime`, so the
        // position survives into the error screen and `retry()` resumes from
        // it.
        let position = currentPosition(state)
        // `finalizeTerminalPlaybackError`'s teardown.
        //
        // It deliberately does **not** stop the server session: it drops
        // the view model's active-session-id mirror and lets the
        // session lapse. Emitting a `.stopSession` here would be a new server
        // call on a wire-visible path (design §4 I1), so the reducer does not
        // synthesise one.
        //
        // The identity is nevertheless carried on `.failed`: the bridge is
        // still holding that session, and the two things that follow on the
        // error screen do reach it — `cleanup()` stops it and
        // `retry()` reports `currentTime` against it. Dropping
        // it here is what silently lost both.
        var effects: [Effect] = [
            .cancelTimer(.progress),
            .cancelTimer(.staleSessionRecovery),
            .cancelTimer(.backgroundRenewal),
            .cancelTimer(.interruptionRecovery),
            .cancelTimer(.serverOutageRecovery),
            // Same reason as `beginLoad`'s: the load that was riding out an
            // outage is over, so the carried ride-through must not be adopted
            // — hold included — by whatever the user starts next.
            .cancelTimer(.sourceOutageRideThrough),
        ]
        if let loadID = state.loadID {
            // `finalizeTerminalPlaybackError` discards: the load
            // died, and `retry()` re-resolves the session from scratch, so the
            // prefix has no adopter worth holding disk spans for.
            effects.append(.disposeEngine(loadID, sourceCache: .discard))
        }
        let next = PlaybackState.failed(
            failure,
            state.loadID,
            identity: state.identity,
            request: retryRequest(for: state),
            position: position,
            selections: currentSelections(state)
        )
        effects.append(.publish(presentation(for: next, loadingReason: "failure")))
        return (next, effects)
    }

    private static func dismiss(_ state: PlaybackState) -> (PlaybackState, [Effect]) {
        var effects: [Effect] = TimerID.allCases.map { Effect.cancelTimer($0) }
        if let loadID = state.loadID {
            // `cleanup()` discards: the player is going away, so
            // nothing can adopt the prefix.
            effects.append(.disposeEngine(loadID, sourceCache: .discard))
        }
        if let identity = state.identity {
            effects.append(
                .stopSession(identity, position: currentPosition(state), isPaused: true)
            )
        }
        return (.disposed, effects)
    }

    private static func isDismiss(_ intent: PlayerIntent) -> Bool {
        if case .dismiss = intent { return true }
        return false
    }

    // MARK: - Projection

    /// The UI projection for a state. Wave 3 widens it as the view model's
    /// stored projections move; the fields the control plane does not own
    /// (metadata, stats composition, notices) keep their defaults here.
    /// `shouldAutoRecoverFromInterruption()`'s inputs, minus the clock: the
    /// deadline is published only while an interruption is still pending and
    /// has not already auto-recovered, so the shell's comparison against `now`
    /// is the whole remaining predicate.
    private static func pendingInterruptionDeadline(
        _ interruption: Playing.Interruption?
    ) -> Date? {
        guard let interruption, interruption.isPending, !interruption.didAutoRecover else {
            return nil
        }
        return interruption.recoveryDeadline
    }

    static func presentation(
        for state: PlaybackState,
        isLoading: Bool? = false,
        isReconnecting: Bool = false,
        loadingReason: String = "",
        bufferingCause: String = ""
    ) -> Presentation {
        switch state {
        case .idle, .disposed:
            return Presentation(loadingReason: loadingReason, bufferingCause: bufferingCause)

        case .preparing(let preparing):
            // `resetPublishedLoadState` raises the overlay and clears the
            // error but keeps `currentTime`, `duration` and the buffering flag,
            // so a load publishes the playhead it is resuming
            // from — not 0 — and after the adopt it publishes the new
            // session's position and duration.
            return Presentation(
                isPlaying: !preparing.transport.isPaused,
                currentTime: preparing.transport.positionSeconds,
                duration: preparing.transport.durationSeconds,
                isLoading: true,
                isBuffering: preparing.transport.isBuffering,
                error: nil,
                isReconnecting: isReconnecting,
                activeQualityId: preparing.activeQualityId,
                // `isQualitySwitching` is cleared when the replan task ends,
                // which is after the adopt issued the engine load
                // — i.e. once the load is `.preparing`.
                isQualitySwitching: false,
                bufferedAheadSeconds: preparing.transport.bufferedAheadSeconds,
                playbackRunwaySeconds: preparing.transport.runwaySeconds,
                loadingReason: loadingReason,
                bufferingCause: bufferingCause,
                hasEnded: false,
                isBackgroundSuspended: false,
                serverSessionId: preparing.identity?.serverSessionId,
                interruptionRecoveryDeadline: pendingInterruptionDeadline(preparing.interruption)
            )

        case .suspended(let context):
            return Presentation(
                currentTime: context.resumePosition,
                error: context.failure?.legacyMessage,
                loadingReason: loadingReason,
                bufferingCause: bufferingCause,
                hasEnded: false,
                isBackgroundSuspended: true,
                serverSessionId: nil
            )

        case .failed(let failure, _, let identity, _, let position, _):
            return Presentation(
                currentTime: position,
                error: failure.legacyMessage,
                loadingReason: loadingReason,
                bufferingCause: bufferingCause,
                hasEnded: false,
                isBackgroundSuspended: false,
                serverSessionId: identity?.serverSessionId
            )

        case .playing(let playing):
            // `activeQualityId` is the *adopted* label and it
            // persists — `attemptProtocolV3Replan` never sets it up front, and
            // a publish that re-derived it from the sub-state would clear the
            // quality the user sees on every steady-state publish.
            // `isQualitySwitching` is the in-flight bit and is derived: it is
            // raised by `switchQuality` and cleared when the
            // replan task ends.
            var isQualitySwitching = false
            if case .replanning(let intent) = playing.sub, intent.completesQualitySwitch {
                isQualitySwitching = true
            }
            return Presentation(
                isPlaying: !playing.transport.isPaused,
                currentTime: playing.transport.positionSeconds,
                duration: playing.transport.durationSeconds,
                isLoading: isLoading,
                isBuffering: playing.transport.isBuffering,
                error: nil,
                isReconnecting: isReconnecting,
                activeQualityId: playing.activeQualityId,
                isQualitySwitching: isQualitySwitching,
                bufferedAheadSeconds: playing.transport.bufferedAheadSeconds,
                playbackRunwaySeconds: playing.transport.runwaySeconds,
                loadingReason: loadingReason,
                bufferingCause: bufferingCause,
                hasEnded: playing.sub == .ended,
                isBackgroundSuspended: false,
                serverSessionId: playing.identity.serverSessionId,
                interruptionRecoveryDeadline: pendingInterruptionDeadline(playing.interruption)
            )
        }
    }
}
