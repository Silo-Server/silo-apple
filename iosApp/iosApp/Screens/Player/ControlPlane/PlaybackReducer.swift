import Foundation
import SwiftUI

/// The playback control plane's decision function: pure, total, and the only
/// place a `PlayerIntent` or a `PlayerEvent` turns into state plus effects.
///
/// It reads no clock (`now` is a parameter), performs no I/O and holds no
/// reference to the view model, the bridge or the backend. Recovery decisions
/// are *not* made here — `RecoveryPolicy` decides, the session actor feeds the
/// decision back as `PlayerEvent.recovery(action, loadID)`, and the reducer
/// maps that action to state and effects (design §4 I3).
///
/// Nothing consumes it yet; wave 3 moves `PlayerViewModel`'s load, replan,
/// seek, scene-phase and progress code onto it.
enum PlaybackReducer {

    // MARK: - Constants (each equals today's literal)

    /// `AVPlayerBackend.seekCompletionDeadlineSeconds`.
    static let seekDeadlineSeconds: TimeInterval = 15.0
    /// `PlayerViewModel.seekFilterNanos` (5 s), the safety valve that drops a
    /// seek filter no post-seek time report ever released.
    static let seekFilterTimeoutSeconds: TimeInterval = 5.0
    /// `PlayerViewModel.interruptionRecoveryTimeout`.
    static let interruptionRecoveryTimeout: TimeInterval = 3.0
    /// `PlayerViewModel.interruptionResumeSuccessThresholdSeconds`.
    static let interruptionResumeSuccessThresholdSeconds: Double = 0.1
    /// The `startProgressReporting` heartbeat (`PVM` 10 s loop).
    static let progressReportIntervalSeconds: TimeInterval = 10.0
    /// `RecoveryAction.recoverFromServerOutage(reason:)`'s one meaningful
    /// discriminator: the token form of
    /// `PlaybackSourceInterruptionReason.sourceEntityChanged`, which is what
    /// picks `discardSourceCacheHandoff()` over `stashSourceCacheHandoff()`
    /// (PVM:4429-4434). Spelled here rather than imported from
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
            return beginSeek(state, targetSeconds: targetSeconds, origin: origin, now: now)

        case .changeQuality(let qualityId):
            // The V3 path of `switchQuality`. Its pre-V3 branches (source
            // reselection, transcode → direct) need version and plan knowledge
            // the control plane does not hold; they stay with the view model,
            // which issues `.load` for them.
            guard case .playing(let playing) = state else { return (state, []) }
            // `switchQuality` only takes the replan branch when a live V3 plan
            // owns the load (PVM:4600-4622). Without one it normalises the id
            // differently and runs the source-reselection / transcode branches,
            // which need version and plan knowledge the control plane does not
            // hold — so an offline or legacy load ignores this intent here and
            // the shell issues its `.load` instead.
            guard playing.hasProtocolV3 else { return (state, []) }
            // `switchQuality` resolves the id through
            // `ApplePlaybackQuality.protocolV3QualityId` on the V3 path and
            // then returns early when it already equals `activeQualityId`
            // (PVM:4603-4608), so re-picking the rung that is already playing
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
            // snapshot: `activePreparedProtocolV3` must be live (PVM:1082-1086).
            // `isMaterialOutputRouteChange` is a bare id inequality
            // (PlaybackSessionBridge.swift:923-927), and an offline identity
            // publishes `outputContextId: ""`, so without this an offline load
            // would find *every* route notification material and ask a server
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

        case .transport:
            // Proxy reports are recovery *observations*: `RecoveryPolicy`
            // decides on them and the decision arrives as `.recovery`.
            return (state, [])

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
    private static func beginLoad(
        from state: PlaybackState,
        request: PlayerViewModel.LoadRequest,
        adoption: PlaybackAdoption,
        options: LoadOptions
    ) -> (PlaybackState, [Effect]) {
        let loadID = LoadID()
        // `resetPublishedLoadState` (PVM:3475-3546) keeps `currentTime`,
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
            // adopt learns the real one (PVM:3510).
            activeQualityId: ApplePlaybackQuality.autoId,
            resumeSelections: .seeded(from: request),
            // `beginFreshLoad` clears the interruption unless the caller asked
            // to preserve it (PVM:3691-3693).
            interruption: options.preserveInterruptionState ? currentInterruption(state) : nil
        )

        var effects: [Effect] = []
        if case .freshLoad(.userInitiated) = adoption {
            // `clearServerOutageRecoveryState()`, user-initiated loads only.
            effects.append(.cancelTimer(.serverOutageRecovery))
        }
        if !options.preserveInterruptionState {
            effects.append(.cancelTimer(.interruptionRecovery))
        }
        // `resetPublishedLoadState`'s first two statements are
        // `isLoading = true; error = nil` — the loading overlay every fresh
        // load, retry, resume, interruption recovery and visible session
        // renewal raises. It sits here, between the interruption clear and the
        // two task cancels, because that is where `beginFreshLoad` calls it
        // (PVM:3691-3701).
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

        if let previousLoadID = state.loadID, !adoption.reusesActiveEngine {
            // Both halves of a fresh load stash: `resetPublishedLoadState`
            // (PVM:3524) and `loadStream` (PVM:2759) hand the outgoing proxy's
            // cached prefix to the replacement, which `SourceCacheAdoptionPolicy`
            // then accepts or rejects against the incoming plan.
            effects.append(.disposeEngine(previousLoadID, sourceCache: .stash))
        }

        effects.append(.startSession(request, options, loadID))
        return (.preparing(preparing), effects)
    }

    /// `adoptPreparedPlayback`'s transport adoption (PVM:2610-2619), which runs
    /// **before** `loadStream` (PVM:2716) — so by the time the engine reports
    /// `fileLoaded` the playhead and the duration are already the new
    /// session's, and the scrubber never blinks back to 0/0.
    private static func adopting(
        _ transport: TransportState,
        prepared: PreparedPlayback,
        adoption: PlaybackAdoption
    ) -> TransportState {
        var transport = transport
        // `fallbackDuration`: a fresh load has nothing to fall back to, a
        // replan keeps the duration it already published (PVM:2609-2612).
        let fallbackDuration: Double
        if case .freshLoad = adoption { fallbackDuration = 0 } else { fallbackDuration = transport.durationSeconds }
        transport.durationSeconds = adoptedDuration(prepared, fallback: fallbackDuration)
        transport.positionSeconds = movieTime(for: prepared.session)
        return transport
    }

    /// The one duration rule every adopt shares: the session's, else the
    /// selected version's, else what is already published (PVM:2612 for the
    /// load/replan adopt, PVM:4149 for the silent renewal).
    private static func adoptedDuration(_ prepared: PreparedPlayback, fallback: Double) -> Double {
        prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? fallback
    }

    /// `adoptProtocolV3RenewalIntent` (PVM:3596-3621): every adopt rewrites
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
    /// when `completesQualitySwitch` (PVM:1652-1654) and
    /// `restartCurrentTranscodeHLS` sets it to the requested `qualityId`
    /// (PVM:5264-5266), both *before* `adoptPreparedPlayback` runs. On the V3
    /// path the adoption below overwrites it with the same value; the latch is
    /// what keeps the user's choice when the prepare carries no plan.
    private static func adoptedRequest(
        _ request: PlayerViewModel.LoadRequest,
        prepared: PreparedPlayback,
        qualitySwitchOverride: String? = nil
    ) -> PlayerViewModel.LoadRequest {
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

    /// `PlayerViewModel.movieTime(for:)` (PVM:3130-3134), which is `private`
    /// there. Wave 3 deletes that copy with the rest of the load path.
    static func movieTime(for session: PlaybackSessionResponse) -> Double {
        let playerTime = session.position.isFinite ? session.position : 0
        let offset = session.timelineOffsetSeconds.isFinite ? session.timelineOffsetSeconds : 0
        return max(0, playerTime + offset)
    }

    /// The request a recovery re-loads or a suspend stores.
    ///
    /// `makeSuspendedPlaybackContext` (PVM:3643-3657) and
    /// `attemptStaleSessionRenewal` (PVM:4236-4242) both rebuild the request
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
        _ request: PlayerViewModel.LoadRequest,
        selections: TrackResumeSelections,
        preferringSelectedFileId: Bool,
        keepingOfflineDownload: Bool
    ) -> PlayerViewModel.LoadRequest {
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

    private static func retryRequest(for state: PlaybackState) -> PlayerViewModel.LoadRequest? {
        switch state {
        case .idle, .disposed: return nil
        case .preparing(let preparing): return preparing.request
        case .playing(let playing): return playing.request
        case .suspended(let context): return context.request
        case .failed(_, _, _, let request, _, _): return request
        }
    }

    /// The playhead a state resumes or reports from — today's `currentTime`,
    /// which neither `finalizeTerminalPlaybackError` (PVM:4027-4071) nor
    /// `suspendForBackground` (PVM:7592-7638) resets, so `retry()` and the
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
        // states below genuinely has: it is the view model's initial value
        // (PVM:185), `finalizeTerminalPlaybackError` sets it (PVM:4072) and
        // `suspendForBackground` sets it (PVM:7621). `resetPublishedLoadState`
        // never writes `isPlaying`, so a cold start, a Retry and an explicit
        // resume all stay "not playing" until `handleFileLoaded` (PVM:1518).
        // Two arms read the bit off `Preparing.transport` and would otherwise
        // treat those loads as playing: `presentation(for:)` (which would
        // publish a playing capsule under the loading overlay) and the tvOS
        // `.inactive` interruption arm, whose original guard is exactly
        // `guard isPlaying` (PVM:7573) — a cold start interrupted by a scene
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
    ///   * `pauseForForegroundInterruptionIfNeeded` (PVM:7571-7589) guards only
    ///     on `!isBackgroundSuspended` and `isPlaying`;
    ///   * the `.active` re-arm (PVM:4725-4750) guards only on
    ///     `isBackgroundSuspended` and a pending, `wasPlaying` interruption;
    ///   * `triggerAutomaticInterruptionRecovery` (PVM:4005-4025) and the
    ///     deadline task that calls it (PVM:4738-4747) guard only on
    ///     `lastLoadRequest`, `isPending` and `!didAutoRecover`.
    ///
    /// None of them looks at whether a load is in flight, and neither
    /// `playbackInterruption` nor `isPlaying` is cleared by
    /// `resetPublishedLoadState` (PVM:3475-3546) — a `preserveInterruptionState`
    /// load deliberately keeps the interruption (PVM:3691-3693). So the Apple TV
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
    /// (PVM:4573-4576: "let that be the single writer so the UI can't drift
    /// out of sync with the actual pipeline state on error paths"). An
    /// optimistic flip here would republish a paused/playing capsule the
    /// pipeline never reached, and it also feeds `.timer(.progress)`'s
    /// `reportProgress(isPaused:)` and the three scene-phase pause guards, so
    /// the drift would reach the server too. Exactly three sites write
    /// `isPlaying` by hand today and all three are ported where they live, not
    /// here: `handleEndOfFile` (PVM:3424, in `endOfFile`),
    /// `triggerAutomaticInterruptionRecovery` (PVM:4016) and
    /// `attemptServerOutageRecovery` (PVM:4438).
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
        origin: SeekOrigin,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }
        // The postroll latch. `seek(to:)` PVM:5300, `seekTo(seconds:)`
        // PVM:5315, `skipForward` PVM:4846 and `skipBackward` PVM:4858 all
        // `guard !hasReachedEndOfFile`, so `commitSeek` clearing the latch
        // (PVM:5037) is only ever reached by a caller that proved it was unset.
        // Exactly two call sites clear it *themselves* and then seek, and they
        // are the two origins allowed here: `keepWatchingCurrentEpisode`
        // (PVM:2093-2110 — leaving the terminal postroll replays the last 10 s,
        // and resuming at exact EOF would present the postroll again) and
        // `beginReanchorSeekUI` (PVM:5063-5064).
        if case .ended = playing.sub {
            switch origin {
            case .nextUpKeepWatching, .reanchor:
                playing.sub = .steady
            case .user, .scrub, .skip, .chapter, .intro, .credits, .recovery:
                return (state, [])
            }
        }

        let request = SeekRequest(
            id: UUID(),
            fromSeconds: playing.transport.positionSeconds,
            targetSeconds: targetSeconds,
            origin: origin,
            deadline: now.addingTimeInterval(seekDeadlineSeconds)
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
            // `beginReanchorSeekUI` (PVM:5063-5076) arms the filter, moves the
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
            return (.playing(playing), [.cancelTimer(.seekFilterTimeout)])
        }
        return (
            .playing(playing),
            [
                .seek(request, playing.loadID),
                // `commitSeek`'s safety valve: drop the filter if no post-seek
                // report ever releases it.
                .schedule(
                    .seekFilterTimeout,
                    after: .seconds(seekFilterTimeoutSeconds),
                    playing.loadID
                ),
            ]
        )
    }

    /// `makeCallbacks().onTimeChange`'s seek filter: reports still closer to
    /// the pre-seek position than to the target are stale drainage frames; the
    /// first report past the midpoint means the seek landed.
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
            // `attemptProtocolV3Replan`'s prologue (PVM:1614-1616): the 10 s
            // progress heartbeat is cancelled for the whole round trip (it is
            // restarted by the adopt path's `startProgressReporting`), the
            // loading overlay is raised, and the buffering flag is cleared.
            playing.transport.isBuffering = false
            effects.append(.cancelTimer(.progress))
            effects.append(.publish(presentation(for: .playing(playing), isLoading: true)))
        case .transcodeRestart(let restart):
            // `restartCurrentTranscodeHLS` has a different prologue: it takes
            // the fresh-load slot (so no heartbeat cancel) and reports
            // progress against the *outgoing* session at the position it is
            // leaving (PVM:5234-5236), guarded the same way. A quality restart
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

    /// `handleScenePhase` (PVM:4711-4794) as three data tables.
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
            // `pauseForForegroundInterruptionIfNeeded` (PVM:7571-7589). Its
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
                    resumePosition: currentPosition(state)
                )
            case .preparing(let preparing):
                // `makeSuspendedPlaybackContext` snapshots `currentTime`
                // (PVM:3652), which a load in flight still has: the outgoing
                // playhead before the session resolves, the new session's
                // position after `adoptPreparedPlayback` set it.
                context = SuspendedContext(
                    request: recoveryRequest(
                        preparing.request,
                        selections: preparing.resumeSelections,
                        preferringSelectedFileId: false,
                        keepingOfflineDownload: true
                    ),
                    resumePosition: currentPosition(state)
                )
            case .failed(let failure, _, _, let request, let position, let selections):
                // `suspendForBackground` needs only `lastLoadRequest`, and
                // `finalizeTerminalPlaybackError` keeps it — so backgrounding
                // the Apple TV on the error screen does suspend today (the
                // wake path at PVM:4720-4724 then awaits an explicit resume).
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
                    failure: failure
                )
            case .idle, .suspended, .disposed:
                return (state, [])
            }
            let next = PlaybackState.suspended(context)
            var effects: [Effect] = suspendTimerCancellations()
            // `suspendForBackground` publishes here (PVM:7616-7623): the
            // buffering capsule and the loading overlay are cleared and
            // `isPlaying` goes false, after the sweep and before the dispose.
            // A suspended load produces no further engine ticks for the actor
            // to coalesce, and the wake screen awaits an explicit resume, so
            // without this publish the Apple TV would come back to a stale
            // "playing" projection — or to a loading overlay the suspend
            // interrupted mid-load.
            effects.append(.publish(presentation(for: next)))
            if let loadID = state.loadID {
                // `suspendForBackground` disposes the backend (PVM:7627) and
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
            // The re-arm (PVM:4725-4750) guards only on `isBackgroundSuspended`
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
            // (PVM:4728-4730) and then calls `avPlayerBackend?.play()`; the
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
            // changed — changing it is a product call). PVM:4753-4756 issues
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
            // `pauseBackgroundPlaybackIfUnrouted` (PVM:4829-4835) issues the
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

    /// `suspendForBackground`'s sweep: the interruption, ride-through and
    /// outage-recovery state it clears by hand plus
    /// `tasks.cancelAll(in: .interaction, .activeStream, .sessionRecovery)`,
    /// restricted to the control-plane keys.
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
    /// `.duration`, `.buffering`, `.bufferedAhead`, `.stats`) mutate
    /// `TransportState` and emit **no** `.publish`. That is deliberate and it
    /// is wave 3's job, not a claim that those projections are unowned —
    /// `Presentation.currentTime`/`.duration`/`.isBuffering`/
    /// `.bufferedAheadSeconds`/`.playbackRunwaySeconds`/`.playbackStats` are
    /// all populated by `presentation(for:)`. Today's `onTimeChange` fires at
    /// the AVPlayer periodic-observer rate; the session actor coalesces these
    /// into one main-actor publish per tick rather than the reducer emitting an
    /// effect per event.
    private static func engine(
        _ state: PlaybackState,
        event: EngineEvent,
        loadID: LoadID,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        // The identity guard that replaces `isCurrentStreamCallback`.
        guard state.loadID == loadID else { return (state, []) }

        switch event {
        case .fileLoaded:
            return fileLoaded(state, loadID: loadID)

        case .firstFrame(let ms):
            guard let identity = state.identity else { return (state, []) }
            return (state, [.reportFirstFrame(identity, ms: ms)])

        case .time(let seconds):
            return time(state, seconds: seconds, now: now)

        case .duration(let seconds):
            guard case .playing(var playing) = state else { return (state, []) }
            // `onDurationChange` (PVM:1265-1278) adopts a backend duration only
            // when the already-extracted pure predicate says so: never under a
            // `.transcode` delivery (a growing transcode playlist reports the
            // *published* length, which is shorter than the real one and would
            // shrink the scrubber and corrupt the near-end rule), and otherwise
            // only when it does not go backwards. One owner: the reducer calls
            // it rather than restating it.
            guard PlayerViewModel.shouldAdoptBackendDuration(
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
            // `onPauseChange` is the sole writer of `isPlaying`.
            return (next, [.publish(presentation(for: next))])

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

        case .stats(let stats):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.transport.stats = stats
            return (.playing(playing), [])

        case .externalPlayback(let active):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.transport.isExternalPlaybackActive = active
            return (.playing(playing), [])

        case .endOfFile:
            return endOfFile(state)

        case .failed:
            // Not decided here: the actor asks `RecoveryPolicy` and feeds the
            // decision back as `.recovery(action, loadID)`.
            return (state, [])

        case .tracks, .chapters, .timelineOffset, .sidecarTracksRegistered,
             .externalPlaybackAllowed, .externalPlaybackUnavailable:
            // Track, chapter, timeline and external-route projections belong
            // to the track coordinator and the presentation model.
            return (state, [])
        }
    }

    private static func fileLoaded(
        _ state: PlaybackState,
        loadID: LoadID
    ) -> (PlaybackState, [Effect]) {
        switch state {
        case .preparing(let preparing):
            guard let plan = preparing.plan, let identity = preparing.identity else {
                return (state, [])
            }
            // `handleFileLoaded` (PVM:1509-1531) asserts the load is playing:
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
                // before the engine load (PVM:2612-2613), carried on
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
            effects.append(.publish(presentation(for: next)))
            return (next, effects)

        case .playing(var playing):
            // A replacement item inside the same load (in-route reload,
            // reanchor): the load is established again.
            playing.sub = .steady
            var effects: [Effect] = [.cancelTimer(.serverOutageRecovery)]
            let recovered = completingInterruption(playing, effects: &effects)
            let next = PlaybackState.playing(recovered)
            // `handleFileLoaded` calls `startProgressReporting()` (PVM:7466-7495)
            // unconditionally, and that cancels and restarts the 10 s
            // heartbeat — so an in-route reload re-phases it here too, exactly
            // as the first `fileLoaded` of a load does. `.schedule` re-arms the
            // keyed timer, which is how the `.preparing` branch above spells
            // the same call.
            effects.append(
                .schedule(.progress, after: .seconds(progressReportIntervalSeconds), loadID)
            )
            effects.append(.publish(presentation(for: next)))
            return (next, effects)

        case .idle, .suspended, .failed, .disposed:
            return (state, [])
        }
    }

    /// `handleFileLoaded`'s
    /// `completeInterruptionRecoveryIfNeeded(observedTime:requiresForwardProgress: false)`
    /// (PVM:1513-1516 → PVM:3976-3996): a stream that reached `fileLoaded`
    /// **is** the recovery landing, so the pending interruption is completed
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
        // `seconds` is already movie time: the engine session applies the
        // session's timeline offset (`playbackTimelineOffset`) before the event
        // leaves it, so the reducer compares like with like.
        guard case .playing(var playing) = state, seconds.isFinite else { return (state, []) }
        // `onTimeChange` drops reports once the EOF latch is set.
        if case .ended = playing.sub { return (state, []) }

        // PVM:1228-1235, ahead of the seek filter: outside an explicit seek
        // playback time is monotonic, so a report that jumps backwards is a
        // loopback replacement item's anchor frame, not a playhead. Letting it
        // through would drag the scrubber and the progress reporter back —
        // the exact bug the predicate was added for. One owner: the reducer
        // calls the already-extracted pure predicate rather than restating it.
        if PlayerViewModel.isUnexpectedBackwardPlaybackTime(
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
        }
        return (.playing(playing), effects)
    }

    private static func endOfFile(_ state: PlaybackState) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }
        // `handleEndOfFile` returns immediately while server-outage recovery is
        // active (PVM:3344-3347). The recovery keeps the same `LoadID` while it
        // disposes the engine, so a late EOF from the engine being torn down
        // still passes the identity guard — accepting it would flip the load to
        // `.ended`, cancel the outage timer and strand the player on the
        // postroll with the recovery half-done.
        if case .recovering(let step) = playing.sub,
           step == .recoveringFromServerOutage || step == .waitingForServerReady {
            return (state, [])
        }
        // DIVERGENCE (documented): `handleEndOfFile` never touches
        // `protocolV3ReplanTask` or `backgroundRenewalSessionId`, so today an
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
        // `handleEndOfFile` clears all three published transport bits together
        // (PVM:3422-3424): `clearLoadingOverlay`, `setBuffering(false, cause:
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
                .transport(.pause, playing.loadID),
                .publish(presentation(for: next)),
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
            // `loadStream` (PVM:2704/2708 vs PVM:2716), so it is emitted here
            // and not at `fileLoaded`: a load that dies between the plan and
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
            // Same position as the fresh load: reported before the engine load
            // (PVM:2708). The in-place transcode restart deliberately never
            // reports it (PVM:2709-2715, "preserved drift").
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

        case .sessionMissing:
            // An observation, not a decision: `RecoveryPolicy` chooses between
            // the silent and the visible renewal.
            return (state, [])

        case .renewed(let prepared, let replacing):
            guard case .playing(var playing) = state,
                  case .renewingSource(let renewal) = playing.sub,
                  // The one mutation that rewrites `Playing.identity`, so it
                  // needs its own guard: a renewal mints a new server session
                  // by definition, which is why `belongsToSameSession` cannot
                  // be it. This is PVM:4123-4130's
                  // `activePlaybackSessionId == staleSessionId` re-check,
                  // expressed over the identity the renewal was issued against.
                  renewal.issuedFor == replacing else {
                return (state, [])
            }
            // The proxy was retargeted in place; player, remuxer and cache are
            // untouched, so the load survives with a new session identity —
            // and with the renewed session's facts: a renewal can land on a
            // re-probed source, and `attemptBackgroundSessionRenewal` adopts
            // its duration, quality label and selected version too
            // (PVM:4142/4149-4151). Keeping the outgoing ones would publish a
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
            // load and replan adopts do (PVM:4146), so the replay request
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
            // route classification. The failure text the ladder passed as
            // `message` is not carried on the action, so the classification
            // stands in for it; wave 2 threads the real one if the server
            // needs it.
            return requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: playing.transport.positionSeconds,
                    classification: classification,
                    message: classification
                )
            )

        case .switchRoute(.loopbackFallback):
            // The offline native-direct → loopback rung. The engine session
            // builds the fallback plan (the action carries none) and reloads
            // the engine in place.
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.switchingRoute)
            return (.playing(playing), [.runRecovery(action, playing.loadID)])

        case .renewSourceInBackground(let reason):
            guard case .playing(var playing) = state else { return (state, []) }
            // Single-flight: the sub-state is the guard the `*SessionId` echo
            // used to provide.
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
            // `attemptStaleSessionRenewal` (PVM:4225-4270): a visible renewal
            // is a fresh load of the *re-resolved* request at the observed
            // position, preceded by a content-scoped force-overwrite progress
            // write (the session it would otherwise report against is the one
            // that vanished).
            guard case .playing(let playing) = state else { return (state, []) }
            let position = playing.transport.positionSeconds.isFinite
                ? max(0, playing.transport.positionSeconds)
                : 0
            // `durationHint`: `duration` when it is usable, else the selected
            // version's (PVM:4234-4236). The version's duration lives with the
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
                    // `backgroundRenewalTask?.cancel()` first (PVM:4224-4227):
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
                        forceOverwrite: true,
                        playing.loadID
                    ),
                    // `self.progressTask?.cancel()` between the sync and the
                    // reload (PVM:4269) — the outgoing heartbeat would report
                    // against the session that vanished.
                    .cancelTimer(.progress),
                ] + effects
            )

        case .autoRecoverInterruption:
            // `triggerAutomaticInterruptionRecovery` (PVM:4005-4025), whose
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
            // One of the three hand-written `isPlaying = false`s (PVM:4016) —
            // the engine that would otherwise report it is about to be
            // replaced. The recovery timer is cancelled by hand even though
            // the load keeps the interruption itself (PVM:4012-4013).
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
            return (next, [.cancelTimer(.interruptionRecovery)] + effects)

        case .rideThroughOutage(let probeAfter):
            guard case .playing(var playing) = state else { return (state, []) }
            // `RecoveryPolicy` single-flights the ENTRY (decideOriginOutage guards
            // on `context.outage == nil`) and then re-emits `.rideThroughOutage`
            // after every health probe as the CONTINUATION of the loop (the
            // 0, 1, 2, 4, 8, 8 s sequence, PVM:4299-4310). The reducer therefore
            // accepts the action whether or not it is already riding: a
            // continuation keeps `startedAt`/`noticeShown` and only moves the
            // next delay, and ALWAYS schedules the one-shot poll again.
            let outage: OutageRideThrough
            if case .ridingOutOutage(let existing) = playing.sub {
                outage = OutageRideThrough(
                    startedAt: existing.startedAt,
                    nextProbeDelay: probeAfter,
                    noticeShown: existing.noticeShown
                )
            } else {
                outage = OutageRideThrough(
                    startedAt: now,
                    nextProbeDelay: probeAfter,
                    noticeShown: false
                )
            }
            playing.sub = .ridingOutOutage(outage)
            return (
                .playing(playing),
                [.pollServerHealth(.sourceOutageRideThrough, after: probeAfter, playing.loadID)]
            )

        case .endOutageRideThrough:
            guard case .playing(var playing) = state,
                  case .ridingOutOutage = playing.sub else {
                return (state, [])
            }
            playing.sub = .steady
            return (
                .playing(playing),
                [.cancelTimer(.sourceOutageRideThrough), .runRecovery(action, playing.loadID)]
            )

        case .recoverFromServerOutage(let reason):
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.recoveringFromServerOutage)
            // One of the three hand-written `isPlaying = false`s (PVM:4438) —
            // the engine that would report it is being disposed in the same
            // breath, so nothing else would ever clear the playing capsule.
            playing.transport.isPaused = true
            let next = PlaybackState.playing(playing)
            return (
                next,
                [
                    // PVM:4405-4410, in this order and *before* the teardown:
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
                    // `clearSourceOutageRideThroughState`'s
                    // `setExternalStallSuppression(false)` needs no effect of
                    // its own: the backend that holds the suppression is
                    // disposed two effects below.
                    .cancelTimer(.backgroundRenewal),
                    .cancelTimer(.sourceOutageRideThrough),
                    .cancelTimer(.progress),
                    // PVM:4429-4434: a `source_entity_changed` outage is the
                    // one case where the cached prefix is *known* to belong to
                    // the replaced entity, so it must not be offered to the
                    // recovery plan. Every other reason stashes.
                    .disposeEngine(
                        playing.loadID,
                        sourceCache: reason == sourceEntityChangedReason ? .discard : .stash
                    ),
                    // `waitForServerReady` (PVM:4493-4504) probes *first* and
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
                    .publish(presentation(for: next, isReconnecting: true)),
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
            return endOfFile(state)

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
        case .reassertPlay, .nudgeStartup, .reanchor, .restartProducer,
             .deferUntilPlay, .resumePlayback:
            guard let loadID = state.loadID else { return (state, []) }
            return (state, [.runRecovery(action, loadID)])
        }
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
            // The deadline task (PVM:4738-4747) has no state precondition, and
            // a `preserveInterruptionState` load deliberately leaves the timer
            // armed (PVM:3691-3693), so it can fire while the replacement load
            // is still `.preparing` — hence the slot (see `interruptionSlot`).
            guard let slot = interruptionSlot(state),
                  let interruption = slot.interruption,
                  interruption.isPending,
                  !interruption.didAutoRecover,
                  now >= interruption.recoveryDeadline else {
                return (state, [])
            }
            return recovery(state, action: .autoRecoverInterruption, now: now)

        case .freshLoad, .protocolV3Replan, .staleSessionRecovery, .backgroundRenewal,
             .sourceOutageRideThrough, .serverOutageRecovery:
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
        // it (PVM:4557-4566).
        let position = currentPosition(state)
        // `finalizeTerminalPlaybackError`'s teardown (PVM:4027-4071).
        //
        // It deliberately does **not** stop the server session: it drops
        // the view model's `activePlaybackSessionId` mirror and lets the
        // session lapse. Emitting a `.stopSession` here would be a new server
        // call on a wire-visible path (design §4 I1), so the reducer does not
        // synthesise one.
        //
        // The identity is nevertheless carried on `.failed`: the bridge is
        // still holding that session, and the two things that follow on the
        // error screen do reach it — `cleanup()` stops it (PVM:6358/6404) and
        // `retry()` reports `currentTime` against it (PVM:4557-4566). Dropping
        // it here is what silently lost both.
        var effects: [Effect] = [
            .cancelTimer(.progress),
            .cancelTimer(.staleSessionRecovery),
            .cancelTimer(.backgroundRenewal),
            .cancelTimer(.interruptionRecovery),
            .cancelTimer(.serverOutageRecovery),
        ]
        if let loadID = state.loadID {
            // `finalizeTerminalPlaybackError` discards (PVM:4063): the load
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
        effects.append(.publish(presentation(for: next)))
        return (next, effects)
    }

    private static func dismiss(_ state: PlaybackState) -> (PlaybackState, [Effect]) {
        var effects: [Effect] = TimerID.allCases.map { Effect.cancelTimer($0) }
        if let loadID = state.loadID {
            // `cleanup()` discards (PVM:6386): the player is going away, so
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
    static func presentation(
        for state: PlaybackState,
        isLoading: Bool = false,
        isReconnecting: Bool = false
    ) -> Presentation {
        switch state {
        case .idle, .disposed:
            return Presentation()

        case .preparing(let preparing):
            // `resetPublishedLoadState` raises the overlay and clears the
            // error but keeps `currentTime`, `duration` and the buffering flag
            // (PVM:3476-3546), so a load publishes the playhead it is resuming
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
                // (PVM:1632-1633) — i.e. once the load is `.preparing`.
                isQualitySwitching: false,
                bufferedAheadSeconds: preparing.transport.bufferedAheadSeconds,
                playbackRunwaySeconds: preparing.transport.runwaySeconds,
                playbackStats: preparing.transport.stats,
                metadata: nil
            )

        case .suspended(let context):
            return Presentation(
                currentTime: context.resumePosition,
                error: context.failure?.legacyMessage
            )

        case .failed(let failure, _, _, _, let position, _):
            return Presentation(currentTime: position, error: failure.legacyMessage)

        case .playing(let playing):
            // `activeQualityId` is the *adopted* label (PVM:2619) and it
            // persists — `attemptProtocolV3Replan` never sets it up front, and
            // a publish that re-derived it from the sub-state would clear the
            // quality the user sees on every steady-state publish.
            // `isQualitySwitching` is the in-flight bit and is derived: it is
            // raised by `switchQuality` (PVM:4611/4699) and cleared when the
            // replan task ends (PVM:1611/1633).
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
                playbackStats: playing.transport.stats,
                metadata: nil
            )
        }
    }
}
