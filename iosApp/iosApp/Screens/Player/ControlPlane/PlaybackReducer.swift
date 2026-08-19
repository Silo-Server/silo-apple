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
            return requestReplan(
                playing,
                intent: ReplanIntent(
                    kind: .serverReplan,
                    position: max(0, playing.transport.positionSeconds.isFinite ? playing.transport.positionSeconds : 0),
                    classification: "quality_changed",
                    message: "User selected playback quality \(qualityId).",
                    qualityPreference: qualityId,
                    completesQualitySwitch: true
                )
            )

        case .outputRouteChanged(let snapshot):
            guard case .playing(let playing) = state else { return (state, []) }
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
            return scenePhase(state, phase: phase, now: now)

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
        var effects: [Effect] = []

        if case .freshLoad(.userInitiated) = adoption {
            // `clearServerOutageRecoveryState()`, user-initiated loads only.
            effects.append(.cancelTimer(.serverOutageRecovery))
        }
        if !options.preserveInterruptionState {
            effects.append(.cancelTimer(.interruptionRecovery))
        }
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
            effects.append(.disposeEngine(previousLoadID))
        }

        let loadID = LoadID()
        effects.append(.startSession(request, options, loadID))

        let preparing = Preparing(
            loadID: loadID,
            identity: nil,
            phase: .resolvingSession,
            request: request,
            options: options,
            adoption: adoption,
            plan: nil,
            // `resetPublishedLoadState` never clears `currentTime`, so the
            // playhead survives the load and the tvOS suspend rule can still
            // snapshot it (PVM:3652).
            carriedPosition: currentPosition(state),
            // `beginFreshLoad` clears the interruption unless the caller asked
            // to preserve it (PVM:3691-3693).
            interruption: options.preserveInterruptionState ? currentInterruption(state) : nil
        )
        return (.preparing(preparing), effects)
    }

    private static func retryRequest(for state: PlaybackState) -> PlayerViewModel.LoadRequest? {
        switch state {
        case .idle, .disposed: return nil
        case .preparing(let preparing): return preparing.request
        case .playing(let playing): return playing.request
        case .suspended(let context): return context.request
        case .failed(_, _, let request, _): return request
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
        case .preparing(let preparing): position = preparing.options.resumePosition ?? preparing.carriedPosition
        case .suspended(let context): position = context.resumePosition
        case .failed(_, _, _, let failedPosition): position = failedPosition
        case .idle, .disposed: return 0
        }
        return position.isFinite ? max(0, position) : 0
    }

    private static func currentInterruption(_ state: PlaybackState) -> Playing.Interruption? {
        switch state {
        case .playing(let playing): return playing.interruption
        case .preparing(let preparing): return preparing.interruption
        case .idle, .suspended, .failed, .disposed: return nil
        }
    }

    // MARK: - Transport

    private static func transport(
        _ state: PlaybackState,
        command: TransportCommand
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }
        playing.transport.isPaused = command == .pause
        let next = PlaybackState.playing(playing)
        return (next, [.transport(command, playing.loadID), .publish(presentation(for: next))])
    }

    // MARK: - Seeking

    private static func beginSeek(
        _ state: PlaybackState,
        targetSeconds: Double,
        origin: SeekOrigin,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        guard case .playing(var playing) = state else { return (state, []) }

        let request = SeekRequest(
            id: UUID(),
            fromSeconds: playing.transport.positionSeconds,
            targetSeconds: targetSeconds,
            origin: origin,
            deadline: now.addingTimeInterval(seekDeadlineSeconds)
        )
        // `commitSeek`: the EOF latch is cleared and the scrubber jumps to the
        // target optimistically while the filter drops stale drainage frames.
        playing.sub = .seeking(request)
        playing.transport.positionSeconds = targetSeconds

        var effects: [Effect] = [.seek(request, playing.loadID)]
        if origin != .reanchor {
            // `beginReanchorSeekUI` deliberately arms the filter with no
            // safety timeout; every other seek gets `commitSeek`'s.
            effects.append(
                .schedule(
                    .seekFilterTimeout,
                    after: .seconds(seekFilterTimeoutSeconds),
                    playing.loadID
                )
            )
        }
        return (.playing(playing), effects)
    }

    /// `makeCallbacks().onTimeChange`'s seek filter: reports still closer to
    /// the pre-seek position than to the target are stale drainage frames; the
    /// first report past the midpoint means the seek landed.
    static func seekHasLanded(_ request: SeekRequest, observedSeconds: Double) -> Bool {
        abs(observedSeconds - request.fromSeconds) >= abs(observedSeconds - request.targetSeconds)
    }

    // MARK: - Replan

    private static func requestReplan(
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
        case .steady, .recovering, .seeking, .ridingOutOutage, .ended:
            break
        }
        var playing = playing
        playing.sub = .replanning(intent)
        var effects: [Effect] = []
        if case .serverReplan = intent.kind {
            // `attemptProtocolV3Replan`'s prologue (PVM:1614-1616): the 10 s
            // progress heartbeat is cancelled for the whole round trip (it is
            // restarted by the adopt path's `startProgressReporting`), the
            // loading overlay is raised, and the buffering flag is cleared.
            // `restartCurrentTranscodeHLS` has a different prologue
            // (PVM:5219-5222: it takes the fresh-load slot and reports
            // progress against the outgoing session), so the transcode restart
            // deliberately gets neither.
            playing.transport.isBuffering = false
            effects.append(.cancelTimer(.progress))
            effects.append(.publish(presentation(for: .playing(playing), isLoading: true)))
        }
        effects.append(.replan(intent, playing.identity))
        return (.playing(playing), effects)
    }

    // MARK: - Scene phase

    private static func scenePhase(
        _ state: PlaybackState,
        phase: ScenePhase,
        now: Date
    ) -> (PlaybackState, [Effect]) {
        #if os(tvOS)
        switch phase {
        case .inactive:
            // `pauseForForegroundInterruptionIfNeeded`.
            guard case .playing(var playing) = state, !playing.transport.isPaused else {
                return (state, [])
            }
            playing.interruption = Playing.Interruption(
                wasPlaying: true,
                positionSeconds: playing.transport.positionSeconds,
                recoveryDeadline: now,
                didAutoRecover: false,
                isPending: true
            )
            playing.transport.isPaused = true
            return (
                .playing(playing),
                [.cancelTimer(.interruptionRecovery), .transport(.pause, playing.loadID)]
            )

        case .background:
            // `suspendForBackground`. It suspends from a load in flight too:
            // `makeSuspendedPlaybackContext` only needs `lastLoadRequest`.
            let context: SuspendedContext
            switch state {
            case .playing(let playing):
                context = SuspendedContext(
                    request: playing.request,
                    resumePosition: playing.transport.positionSeconds
                )
            case .preparing(let preparing):
                // `makeSuspendedPlaybackContext` snapshots `currentTime`
                // (PVM:3652), which a load in flight still has: the resume
                // override once the session resolved, the outgoing playhead
                // before that.
                context = SuspendedContext(
                    request: preparing.request,
                    resumePosition: preparing.options.resumePosition ?? preparing.carriedPosition
                )
            case .failed(let failure, _, let request, let position):
                // `suspendForBackground` needs only `lastLoadRequest`, and
                // `finalizeTerminalPlaybackError` keeps it — so backgrounding
                // the Apple TV on the error screen does suspend today (the
                // wake path at PVM:4720-4724 then awaits an explicit resume).
                // The failure travels with the context so the projection keeps
                // publishing `error`.
                guard let request else { return (state, []) }
                context = SuspendedContext(
                    request: request,
                    resumePosition: position,
                    failure: failure
                )
            case .idle, .suspended, .disposed:
                return (state, [])
            }
            var effects: [Effect] = suspendTimerCancellations()
            if let loadID = state.loadID {
                effects.append(.disposeEngine(loadID))
            }
            if let identity = state.identity {
                // Registered but swept by nothing: the bridge's identity guard
                // is what makes a resume that overtakes it safe.
                effects.append(
                    .stopSession(identity, position: context.resumePosition, isPaused: true)
                )
            }
            return (.suspended(context), effects)

        case .active:
            // A suspended player awaits an explicit resume; only the controls
            // are revealed, which is view-model state.
            guard case .playing(var playing) = state,
                  var interruption = playing.interruption,
                  interruption.isPending,
                  interruption.wasPlaying else {
                return (state, [])
            }
            interruption.recoveryDeadline = now.addingTimeInterval(interruptionRecoveryTimeout)
            playing.interruption = interruption
            playing.transport.isPaused = false
            let next = PlaybackState.playing(playing)
            return (
                next,
                [
                    .publish(presentation(for: next, isLoading: true)),
                    .transport(.play, playing.loadID),
                    .schedule(
                        .interruptionRecovery,
                        after: .seconds(interruptionRecoveryTimeout),
                        playing.loadID
                    ),
                ]
            )

        @unknown default:
            return (state, [])
        }
        #elseif os(macOS)
        switch phase {
        case .background:
            guard case .playing(var playing) = state, !playing.transport.isPaused else {
                return (state, [])
            }
            playing.transport.isPaused = true
            return (.playing(playing), [.transport(.pause, playing.loadID)])
        case .inactive, .active:
            return (state, [])
        @unknown default:
            return (state, [])
        }
        #else
        switch phase {
        case .background:
            guard case .playing(var playing) = state, !playing.transport.isPaused else {
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
            playing.transport.isPaused = true
            return (.playing(playing), [.transport(.pause, playing.loadID)])
        case .inactive, .active:
            return (state, [])
        @unknown default:
            return (state, [])
        }
        #endif
    }

    #if os(tvOS)
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
    #endif

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
            let playing = Playing(
                loadID: preparing.loadID,
                identity: identity,
                plan: plan,
                request: preparing.request,
                adoption: preparing.adoption,
                transport: TransportState(),
                sub: .steady,
                // A `preserveInterruptionState` load rides its pending
                // interruption across the reload so the first forward time
                // report can complete it (PVM:3976-3996).
                interruption: preparing.interruption
            )
            let next = PlaybackState.playing(playing)
            var effects: [Effect] = [.cancelTimer(.serverOutageRecovery)]
            if preparing.adoption.reportsPlanExecutionStarted {
                effects.append(.reportPlanExecutionStarted(identity))
            }
            effects.append(
                .schedule(.progress, after: .seconds(progressReportIntervalSeconds), loadID)
            )
            effects.append(.publish(presentation(for: next)))
            return (next, effects)

        case .playing(var playing):
            // A replacement item inside the same load (in-route reload,
            // reanchor): the load is established again.
            playing.sub = .steady
            let next = PlaybackState.playing(playing)
            return (next, [.cancelTimer(.serverOutageRecovery), .publish(presentation(for: next))])

        case .idle, .suspended, .failed, .disposed:
            return (state, [])
        }
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
        let explicitSeekInFlight: Bool
        if case .seeking = playing.sub { explicitSeekInFlight = true } else { explicitSeekInFlight = false }
        if PlayerViewModel.isUnexpectedBackwardPlaybackTime(
            seconds,
            currentTime: playing.transport.positionSeconds,
            explicitSeekInFlight: explicitSeekInFlight
        ) {
            return (state, [])
        }

        var effects: [Effect] = []
        if case .seeking(let request) = playing.sub {
            guard seekHasLanded(request, observedSeconds: seconds) else {
                // Stale drainage frame: keep the optimistic target.
                return (state, [])
            }
            playing.sub = .steady
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
        playing.sub = .ended
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
        case .prepared(_, let plan, let loadID):
            guard case .preparing(var preparing) = state,
                  preparing.loadID == loadID,
                  preparing.phase == .resolvingSession else {
                // A prepare for a superseded load: dropped structurally.
                return (state, [])
            }
            preparing.identity = identity
            preparing.plan = plan
            preparing.phase = .startingEngine
            return (
                .preparing(preparing),
                [.loadEngine(plan, preparing.loadID, reuseEngine: false)]
            )

        case .replanned(_, let plan):
            guard case .playing(let playing) = state,
                  case .replanning(let intent) = playing.sub,
                  identity.belongsToSameSession(as: playing.identity) else {
                return (state, [])
            }
            // The engine instance may survive (`prepareBackend(for:)`), the
            // load identity never does: callbacks re-bind to a new `LoadID`.
            let reuseEngine = intent.kind == .serverReplan && plan.engine == playing.plan.engine
            let loadID = LoadID()
            let preparing = Preparing(
                loadID: loadID,
                identity: identity,
                phase: .startingEngine,
                request: playing.request,
                options: LoadOptions(),
                adoption: .replan(intent.kind),
                plan: plan,
                // A replan never resets `currentTime`; it re-anchors the same
                // title at the live playhead, which is what a tvOS suspend
                // landing mid-replan must resume from.
                carriedPosition: playing.transport.positionSeconds,
                interruption: playing.interruption
            )
            return (
                .preparing(preparing),
                [.loadEngine(plan, loadID, reuseEngine: reuseEngine)]
            )

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

        case .renewed(_, let replacing):
            guard case .playing(var playing) = state,
                  case .renewingSource(let renewal) = playing.sub,
                  // The one mutation that rewrites `Playing.identity`, so it
                  // needs its own guard: a renewal mints a new server session
                  // by definition, which is why `belongsToSameSession` cannot
                  // be it. This is PVM:4123-4130's
                  // `activePlaybackSessionId == staleSessionId` re-check,
                  // expressed over the identity the renewal was issued against.
                  // (`.renewalFailed` needs no equivalent: one `.renewSource`
                  // effect produces exactly one answer, and a second renewal
                  // cannot start while `.renewingSource` holds the load.)
                  renewal.issuedFor == replacing else {
                return (state, [])
            }
            // The proxy was retargeted in place; player, remuxer and cache are
            // untouched, so the load survives with a new session identity.
            playing.identity = identity
            playing.sub = .steady
            return (.playing(playing), [])

        case .renewalFailed:
            guard case .playing(var playing) = state,
                  case .renewingSource = playing.sub else {
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
            case .steady, .recovering, .seeking, .ridingOutOutage, .ended:
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
            // `attemptStaleSessionRenewal`: a visible renewal is a fresh load
            // of the same request at the observed position.
            guard case .playing(let playing) = state else { return (state, []) }
            let position = playing.transport.positionSeconds.isFinite
                ? max(0, playing.transport.positionSeconds)
                : 0
            return beginLoad(
                from: state,
                request: playing.request,
                adoption: .freshLoad(.recovery),
                options: LoadOptions(
                    progressPosition: nil,
                    resumePosition: position,
                    allowNearEndResume: true,
                    preserveInterruptionState: true
                )
            )

        case .autoRecoverInterruption:
            // `triggerAutomaticInterruptionRecovery`.
            guard case .playing(var playing) = state,
                  var interruption = playing.interruption,
                  !interruption.didAutoRecover else {
                return (state, [])
            }
            interruption.didAutoRecover = true
            interruption.isPending = true
            playing.interruption = interruption
            return beginLoad(
                from: .playing(playing),
                request: playing.request,
                adoption: .freshLoad(.recovery),
                options: LoadOptions(
                    progressPosition: interruption.positionSeconds,
                    resumePosition: interruption.positionSeconds,
                    allowNearEndResume: true,
                    preserveInterruptionState: true
                )
            )

        case .rideThroughOutage(let probeAfter):
            guard case .playing(var playing) = state else { return (state, []) }
            if case .ridingOutOutage = playing.sub { return (state, []) }
            let outage = OutageRideThrough(
                startedAt: now,
                nextProbeDelay: probeAfter,
                noticeShown: false
            )
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

        case .recoverFromServerOutage:
            guard case .playing(var playing) = state else { return (state, []) }
            playing.sub = .recovering(.recoveringFromServerOutage)
            playing.transport.isPaused = true
            let next = PlaybackState.playing(playing)
            return (
                next,
                [
                    .cancelTimer(.progress),
                    .disposeEngine(playing.loadID),
                    .pollServerHealth(
                        .serverOutageRecovery,
                        after: .seconds(1),
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

        default:
            // Single-shot in-route actions (reassert, nudge, reanchor,
            // producer restart, defer-until-play, auto-resume): executed by
            // the engine session, the load stays steady — exactly as the
            // backend ladders behave today.
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
            guard case .playing(var playing) = state, case .seeking = playing.sub else {
                return (state, [])
            }
            // The safety valve: no post-seek report arrived, so stop pinning
            // the scrubber to the optimistic target.
            playing.sub = .steady
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
            guard case .playing(let playing) = state,
                  let interruption = playing.interruption,
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
        // `finalizeTerminalPlaybackError`'s teardown, plus the stop the design
        // adds so a terminal failure does not strand the server session.
        var effects: [Effect] = [
            .cancelTimer(.progress),
            .cancelTimer(.staleSessionRecovery),
            .cancelTimer(.backgroundRenewal),
            .cancelTimer(.interruptionRecovery),
            .cancelTimer(.serverOutageRecovery),
        ]
        if let loadID = state.loadID {
            effects.append(.disposeEngine(loadID))
        }
        if let identity = state.identity {
            effects.append(
                .stopSession(
                    identity,
                    position: position,
                    isPaused: true
                )
            )
        }
        let next = PlaybackState.failed(
            failure,
            state.loadID,
            request: retryRequest(for: state),
            position: position
        )
        effects.append(.publish(presentation(for: next)))
        return (next, effects)
    }

    private static func dismiss(_ state: PlaybackState) -> (PlaybackState, [Effect]) {
        var effects: [Effect] = TimerID.allCases.map { Effect.cancelTimer($0) }
        if let loadID = state.loadID {
            effects.append(.disposeEngine(loadID))
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

        case .preparing:
            return Presentation(isLoading: true)

        case .suspended(let context):
            return Presentation(
                currentTime: context.resumePosition,
                error: context.failure?.legacyMessage
            )

        case .failed(let failure, _, _, let position):
            return Presentation(currentTime: position, error: failure.legacyMessage)

        case .playing(let playing):
            var isQualitySwitching = false
            var activeQualityId: String?
            // Only a quality-switch replan touches the two quality
            // projections; every other replan leaves them alone.
            if case .replanning(let intent) = playing.sub, intent.completesQualitySwitch {
                isQualitySwitching = true
                activeQualityId = intent.qualityPreference
            }
            return Presentation(
                isPlaying: !playing.transport.isPaused,
                currentTime: playing.transport.positionSeconds,
                duration: playing.transport.durationSeconds,
                isLoading: isLoading,
                isBuffering: playing.transport.isBuffering,
                error: nil,
                isReconnecting: isReconnecting,
                activeQualityId: activeQualityId,
                isQualitySwitching: isQualitySwitching,
                bufferedAheadSeconds: playing.transport.bufferedAheadSeconds,
                playbackRunwaySeconds: playing.transport.runwaySeconds,
                playbackStats: playing.transport.stats,
                metadata: nil
            )
        }
    }
}
