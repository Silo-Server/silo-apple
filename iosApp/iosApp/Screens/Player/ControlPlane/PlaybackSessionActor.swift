//
//  PlaybackSessionActor.swift
//
//  The playback control plane's one owner: it holds `PlaybackState`, it is the
//  only caller of `PlaybackReducer`, and it runs the reducer's `[Effect]`.
//
//  What is *not* here is any decision. Load/seek/replan/scene-phase decisions
//  are `PlaybackReducer`'s; recovery decisions are `RecoveryPolicy`'s, reached
//  only through the load's `RecoveryDriver`. The actor routes and runs, and
//  hands the *presentation* half of every event to the view-model shell so the
//  console breadcrumbs, Now Playing pushes, next-up presentation and track
//  application stay exactly where they were.
//
//  **Effect identity.** Every effect is conditional on the identity it carries:
//  a `LoadID`, a `SessionIdentity`, or — for the four that carry neither of
//  those and mutate the shell, the registry or this actor's own state
//  (`.publish`, `.cancelTimer`, `.disposeEngine`, `.startSession`) — the
//  `transitionEpoch` of the transition that produced the batch. A batch is a
//  consequence of exactly one committed transition, and Swift actors are
//  re-entrant at every `await`, so a batch that suspends can find a newer
//  transition already committed and executed. It then stops where it is; it
//  never undoes what the newer one did. See `transitionEpoch`.
//
//  Isolation: a real `actor`. Its collaborators are not —
//  `PlaybackControlPlaneShell`'s one production conformer (`PlayerViewModel`),
//  `PlaybackEngineSession` and `AVPlayerBackend` are nonisolated, main-queue
//  affine classes — so every shell entry point the actor calls is `@MainActor`
//  and the `await` performs the hop. A view command therefore reaches the
//  engine a run-loop turn later than an inline backend call would.
//
//  Ordering between two shell commands is the *shell's* to guarantee, not this
//  actor's: an actor serialises execution, it does not order distinct
//  unstructured tasks. `PlayerViewModel` therefore has one ingress queue for
//  all three of its entry points here (`send`, `requestReplan`,
//  `reloadEngine`), drained by one task that awaits each command before it
//  takes the next — so a pair that must not invert, like the re-anchor seek and
//  the reload that carries it, arrives in the order it was issued.
//

import Foundation
import OSLog

/// What the reducer did with an engine event, handed to the shell alongside it.
///
/// The presentation half of an event runs after the control-plane half, so the
/// facts it used to read off the published state — "was this playing before?",
/// "did the reducer take this?" — have to travel with it.
struct EngineEventReduction: Sendable, Equatable {
    /// The reducer acted on the event rather than refusing it.
    var accepted: Bool
    /// The transport state *before* this event was reduced.
    var wasPlaying: Bool
}

/// Everything the control plane needs from its presentation shell.
///
/// `PlayerViewModel` is the only production conformer and the seam exists for
/// one reason: the actor's lifecycle rules are about *when* a shell call may
/// still be made, and the only way to pin "may not" is a shell whose calls can
/// be held open across a second transition
/// (`PlaybackSessionActorLifecycleTests`). It adds no indirection at runtime —
/// the actor calls the same methods it called before.
///
/// Every requirement is `async`: the shell is a main-queue-affine class, the
/// actor always pays the hop, and a synchronous `@MainActor` witness satisfies
/// an `async` requirement unchanged.
protocol PlaybackControlPlaneShell: AnyObject {

    // Presentation
    @MainActor func applyPresentation(_ presentation: Presentation, transportOnly: Bool) async
    @MainActor func applyEngineEventToPresentation(
        _ event: EngineEvent,
        reduction: EngineEventReduction
    ) async

    // Session lifecycle
    @MainActor func prepareFreshSession(
        request: LoadRequest,
        options: LoadOptions,
        origin: LoadOrigin
    ) async throws -> (prepared: PreparedPlayback, plan: PlaybackExecutionPlan, identity: SessionIdentity)
    @MainActor func presentLoadFailure(_ error: Error, origin: LoadOrigin) async -> String?
    @MainActor func recordOfflineProgressIfOffline() async -> Bool

    // Engine lifecycle
    @MainActor func installEngine(
        plan: PlaybackExecutionPlan,
        loadID: LoadID,
        reuseEngine: Bool,
        adoptingOutage outage: RecoveryContext.OutageState?
    ) async -> (events: AsyncStream<EngineEvent>?, failure: String?)
    @MainActor func teardownEngine(
        loadID: LoadID,
        sourceCache: SourceCacheDisposition,
        engineOnly: Bool
    ) async
    @MainActor func engineSeek(to seconds: Double) async
    @MainActor func engineTransport(_ command: TransportCommand) async

    // Recovery
    @MainActor func performEngineRecovery(_ action: RecoveryAction) async
    @MainActor func observeRecovery(_ observation: RecoveryObservation) async
    @MainActor func liveOutageState() async -> RecoveryContext.OutageState?
    @MainActor func clearOutageNoticeLatch() async
    @MainActor func clearServerOutageRecoverySlot() async
    @MainActor func probeServerHealthOnce(reporting timerID: TimerID) async -> Bool
    @MainActor func reprobeOrigin() async

    // Replan and silent renewal
    @MainActor func prepareReplan(
        _ intent: ReplanIntent
    ) async throws -> (prepared: PreparedPlayback, plan: PlaybackExecutionPlan, identity: SessionIdentity)?
    @MainActor func releaseReplanSuspension(completingQualitySwitch: Bool) async
    @MainActor func prepareRenewal(
        _ renewal: SourceRenewal
    ) async throws -> (prepared: PreparedPlayback, identity: SessionIdentity)?
    @MainActor func noteRenewalSucceeded() async
    @MainActor func noteRenewalFailure(_ error: Error, reason: String) async -> Bool
}

extension PlayerViewModel: PlaybackControlPlaneShell {}

actor PlaybackSessionActor {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlaybackSessionActor"
    )

    /// The control plane's state. Every mutation goes through the reducer.
    private(set) var state: PlaybackState = .idle

    /// The server session actor, shared with the shell (the track half still
    /// reaches it directly for subtitle work).
    private let bridge: PlaybackSessionBridge
    /// The presentation model. Weak, because `PlayerView` replaces a disposed
    /// view model and a live effect must not resurrect one.
    private weak var shell: (any PlaybackControlPlaneShell)?

    /// The control-plane half of `PlayerTaskRegistry` (one key per `TimerID`,
    /// plus the engine-event loop). UI timers stay on the shell's own registry.
    private let tasks = PlayerTaskRegistry()

    /// Which transition an effect batch belongs to.
    ///
    /// `send`/`ingest` commit the reduced state and *then* run its effects, and
    /// an actor is re-entrant at every `await`: while a batch is parked in a
    /// main-actor hop or a server round trip, another intent or event can be
    /// reduced, committed and fully executed. The parked batch then resumes
    /// holding a picture of the world that has been superseded — and before
    /// this counter it went on to publish that picture, cancel the newer load's
    /// task in `startSession` and install its own, stranding the state in
    /// `.preparing` with nothing left to finish it.
    ///
    /// The epoch is bumped by exactly the transitions that supersede a batch:
    /// one that binds the state to a different load, or moves it to a different
    /// phase of the player's life (see `supersedes`). A mutation *within* a
    /// load — a time frame, a buffering edge, a pause, a sub-state change —
    /// deliberately does not bump it: those interleave constantly with the
    /// heartbeat and the load prologue, and invalidating a batch on one would
    /// drop the `.startSession` that load is waiting for.
    private var transitionEpoch: UInt64 = 0

    /// The load `Effect.loadEngine` installed, or is installing. It is the
    /// second half of the engine-event identity: a newer load mints it where
    /// the legacy code bumped the stream-load generation, well before the
    /// replacement session exists.
    private var pendingLoadID: LoadID?

    /// The last `Presentation` handed to the shell, so the coalesced transport
    /// publish can skip a tick that changed nothing.
    private var lastPublished = Presentation()

    // MARK: - Actor-scoped outage state

    /// The origin-outage ride-through, scoped to the *player* rather than to a
    /// single engine session.
    ///
    /// A session-scoped ride-through survives an in-place replan (the reused
    /// backend adopts it together with its `origin_outage` hold) but not a
    /// **route-change** one, which builds a fresh backend: the ride-through
    /// would die with the retired session, so a still-failing origin would
    /// restart it on a fresh 90 s budget instead of escalating at the original
    /// deadline, and re-entry would stop being a no-op. It is held here so that
    /// every session this actor installs adopts the live ride-through together
    /// with the hold that releases it — a hold is never adopted without its
    /// releaser.
    private(set) var carriedOutage: RecoveryContext.OutageState?

    /// The post-outage-reload engine-failure suppression window.
    ///
    /// It has to outlive the session that raised the outage: the visible
    /// recovery owns the load until the *replacement* stream reports
    /// `fileLoaded`, and every engine failure in between is the server coming
    /// back, not a playback fault. A gate on the session's own
    /// `RecoveryContext.serverOutageRecovery` cannot answer for that window,
    /// because the replacement session does not have one. It is released with
    /// the `.serverOutageRecovery` timer, which `fileLoaded` cancels.
    private(set) var suppressesEngineFailuresAfterOutage = false

    #if DEBUG
    /// Every effect the actor ran, in order — and only those: an effect a
    /// superseded batch never reached is absent, which is how
    /// `PlaybackSessionActorLifecycleTests` reads the epoch guard.
    ///
    /// `PlaybackSessionActorTests` drives an actor with `shell: nil`, where the
    /// reducer and the whole effect-routing path run and the main-actor arms
    /// are no-ops; the lifecycle tests drive one with a fake
    /// `PlaybackControlPlaneShell` whose calls they can hold open.
    private(set) var recordedEffects: [Effect] = []

    /// Drop everything recorded so far, so a test can assert on one step.
    func clearRecordedEffects() { recordedEffects.removeAll() }
    #endif

    init(bridge: PlaybackSessionBridge, shell: (any PlaybackControlPlaneShell)?) {
        self.bridge = bridge
        self.shell = shell
    }

    // MARK: - Entry points

    /// A view (or the platform) asked for something.
    func send(_ intent: PlayerIntent) async {
        let (next, effects) = PlaybackReducer.reduce(state, intent: intent, now: Date())
        let epoch = commit(next)
        await run(effects, epoch: epoch)
    }

    /// Something happened. `event` already carries the identity it happened for.
    func ingest(_ event: PlayerEvent) async {
        noteBeforeReducing(event)
        let (next, effects) = PlaybackReducer.reduce(state, event: event, now: Date())
        let epoch = commit(next)
        await noteAfterReducing(event)
        await run(effects, epoch: epoch)
    }

    /// Commit one reduction and answer the epoch its effects belong to.
    ///
    /// The epoch is captured here rather than at the top of `run` on purpose:
    /// `ingest` awaits the shell between the commit and the effects, and a
    /// transition that lands in *that* window supersedes the batch just as much
    /// as one that lands inside it.
    private func commit(_ next: PlaybackState) -> UInt64 {
        if Self.supersedes(next, state) { transitionEpoch &+= 1 }
        state = next
        return transitionEpoch
    }

    /// Whether moving from `previous` to `next` invalidates every effect batch
    /// still in flight.
    ///
    /// Two things do: binding the state to a different load (or to none), and
    /// moving to a different phase of the player's life. Both mean the premises
    /// an in-flight batch was computed from — which load it is preparing, which
    /// engine it is retiring, which surface it is publishing — no longer hold.
    /// Everything else is a mutation *inside* the same load and leaves those
    /// premises intact.
    private static func supersedes(_ next: PlaybackState, _ previous: PlaybackState) -> Bool {
        if next.loadID != previous.loadID { return true }
        switch (previous, next) {
        case (.idle, .idle), (.preparing, .preparing), (.playing, .playing),
             (.suspended, .suspended), (.failed, .failed), (.disposed, .disposed):
            return false
        default:
            return true
        }
    }

    /// Read-only snapshot for the shell's synchronous projections.
    func currentState() -> PlaybackState { state }

    /// The suppression window, raised *before* the reduction so the effects
    /// that same event produces already run under it.
    private func noteBeforeReducing(_ event: PlayerEvent) {
        guard case let .recovery(action, loadID) = event,
              state.loadID == loadID,
              case .recoverFromServerOutage = action else {
            return
        }
        if let carried = carriedOutage,
           Date().timeIntervalSince(carried.rideThroughStart)
            >= RecoveryPolicy.serverOutageRecoveryTimeout {
            // The ride-through's own escalation point, and *only* that one.
            // Legacy logged this line from the poll loop's expiry branch;
            // `RecoveryPolicy.beginServerOutageRecovery` has two other entries
            // that are reachable during a live ride-through (the failure
            // ladder's premature-source-end rung and `.sourceInterrupted`), and
            // neither is a budget expiry — so the deadline, not the mere
            // presence of a carry, is what qualifies the line.
            Self.logger.error(
                "[CMP-OUTAGE] ride-through budget exhausted; escalating to visible recovery"
            )
        }
        // The visible recovery owns the load until its replacement stream
        // reports `fileLoaded`; every engine failure in between is the server
        // going away, not a playback fault.
        suppressesEngineFailuresAfterOutage = true
    }

    /// Snapshot the ride-through the policy just entered (or continued), so a
    /// route-change replan later in this load resumes the *same* 90 s budget
    /// instead of starting a second one.
    ///
    /// `RecoveryContext.OutageState` is the ride-through's one representation
    /// and this is a mirror of it: the live driver's `context.outage` is what
    /// `decideServerHealthProbe` reads for the 90 s escalation and what it has
    /// just written, notice latch included. Between two engines of a
    /// route-change replan no session can answer for it, and there the mirror
    /// falls back on the action that policy emitted — the same numbers, not a
    /// second copy of the state. Either way the existing start wins: a
    /// continuation must never restart the budget.
    private func noteAfterReducing(_ event: PlayerEvent) async {
        guard case let .recovery(action, _) = event,
              case let .rideThroughOutage(probeAfter) = action else {
            return
        }
        let live = await shell?.liveOutageState()
        // The entry (`probeAfter == .zero`) is what mints the carry; a
        // continuation only ever moves one that already exists, so a probe that
        // outlived its ride-through cannot resurrect the hold it released.
        guard probeAfter == .zero || carriedOutage != nil || live != nil else { return }
        carriedOutage = RecoveryContext.OutageState(
            rideThroughStart: carriedOutage?.rideThroughStart
                ?? live?.rideThroughStart
                ?? Date(),
            nextProbeDelay: live?.nextProbeDelay ?? Self.seconds(probeAfter),
            noticeShown: live?.noticeShown ?? carriedOutage?.noticeShown ?? false
        )
    }

    /// `Duration` as the `TimeInterval` `RecoveryContext` stores.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }

    // MARK: - Effect runner

    /// Run one batch. It stops at the first effect a newer transition has
    /// superseded — it does not skip that effect and carry on, because the rest
    /// of the batch is the same superseded picture of the world.
    private func run(_ effects: [Effect], epoch: UInt64) async {
        for effect in effects {
            guard epoch == transitionEpoch else { return }
            await perform(effect, epoch: epoch)
        }
    }

    private func perform(_ effect: Effect, epoch: UInt64) async {
        // Re-checked here as well as in `run` because `loadEngine`,
        // `abandonLoad` and `reloadEngine` reach single effects directly.
        guard epoch == transitionEpoch else { return }
        #if DEBUG
        recordedEffects.append(effect)
        #endif
        switch effect {
        case let .startSession(request, options, loadID):
            startSession(request: request, options: options, loadID: loadID)

        case let .stopSession(identity, position, isPaused):
            await stopSession(identity, position: position, isPaused: isPaused)

        case let .loadEngine(plan, loadID, reuseEngine):
            await loadEngine(plan.value, loadID: loadID, reuseEngine: reuseEngine, epoch: epoch)

        case let .disposeEngine(loadID, sourceCache):
            await disposeEngine(loadID, sourceCache: sourceCache)

        case let .seek(request, loadID):
            guard pendingLoadID == loadID else { return }
            await shell?.engineSeek(to: request.targetSeconds)

        case let .replan(intent, identity):
            replan(intent, identity: identity)

        case let .renewSource(renewal, identity):
            renewSource(renewal, identity: identity)

        case let .runRecovery(action, loadID):
            guard pendingLoadID == loadID else { return }
            await shell?.performEngineRecovery(action)

        case let .pollServerHealth(timerID, delay, loadID):
            pollServerHealth(timerID, after: delay, loadID: loadID)

        case let .schedule(timerID, delay, loadID):
            schedule(timerID, after: delay, loadID: loadID)

        case let .cancelTimer(timerID):
            await cancel(timerID)

        case let .reportProgress(identity, position, isPaused):
            await reportProgress(identity, position: position, isPaused: isPaused)

        case let .syncProgress(contentId, position, duration, forceOverwrite):
            // Awaited here, not dispatched: it must complete *before* the
            // `.startSession` that follows it in the same effect list, which is
            // the `await` ordering inside the legacy stale-session task.
            //
            // It carries no identity to check because it has none to check
            // against: it is a *content*-scoped write about the load being left
            // behind, emitted by the same transition that binds the state to
            // the replacement. Comparing it with `state.loadID` — which that
            // transition has already moved on — is what dropped it. Staleness
            // is the batch epoch's job.
            _ = await bridge.syncProgress(
                contentId: contentId,
                position: position,
                duration: duration,
                forceOverwrite: forceOverwrite
            )

        case let .reportFirstFrame(identity, ms):
            guard identityIsCurrent(identity) else { return }
            await bridge.reportProtocolV3FirstFrame(milliseconds: ms)

        case let .reportPlanExecutionStarted(identity):
            guard identityIsCurrent(identity) else { return }
            await bridge.reportProtocolV3PlanExecutionStarted()

        case let .transport(command, loadID):
            // Fire and forget: the resulting `EngineEvent.pauseChanged` comes
            // back through the reducer, and the actor must never synthesise
            // one.
            guard pendingLoadID == loadID else { return }
            await shell?.engineTransport(command)

        case let .publish(presentation):
            await publish(presentation)
        }
    }

    /// A session-scoped report only runs against the session the state is bound
    /// to — a value compare, not a `*SessionId` echo.
    ///
    /// It answers for effects that report *about the current load*
    /// (`.reportFirstFrame`, `.reportPlanExecutionStarted`). The progress
    /// reports are deliberately not among them: theirs is the **outgoing**
    /// session at a load boundary, so they are checked against the session the
    /// bridge is holding instead (see `reportProgress`).
    private func identityIsCurrent(_ identity: SessionIdentity) -> Bool {
        guard let current = state.identity else { return false }
        return identity.belongsToSameSession(as: current)
    }

    // MARK: - Publish

    private func publish(_ presentation: Presentation) async {
        lastPublished = presentation
        await shell?.applyPresentation(presentation, transportOnly: false)
    }

    /// The one publish the high-frequency arms owe the UI.
    ///
    /// The high-frequency arms (`.time`, `.duration`, `.bufferedAhead`,
    /// `.stats`) emit no `.publish` of their own, so one merge per ingested tick
    /// carries the playhead — including `commitSeek`'s optimistic jump — and the
    /// buffer gauges to the UI. It is a **merge**, never an assign: the shell
    /// owns metadata, notices and everything `Presentation` stubs.
    private func publishTransportIfChanged() async {
        let next = PlaybackReducer.presentation(for: state)
        guard next.currentTime != lastPublished.currentTime
            || next.duration != lastPublished.duration
            || next.bufferedAheadSeconds != lastPublished.bufferedAheadSeconds
            || next.playbackRunwaySeconds != lastPublished.playbackRunwaySeconds else {
            return
        }
        lastPublished.currentTime = next.currentTime
        lastPublished.duration = next.duration
        lastPublished.bufferedAheadSeconds = next.bufferedAheadSeconds
        lastPublished.playbackRunwaySeconds = next.playbackRunwaySeconds
        await shell?.applyPresentation(next, transportOnly: true)
    }

    // MARK: - Session lifecycle

    /// `beginFreshLoad`'s task body, minus the prologue the reducer already
    /// emitted as effects (its timer cancels, the outgoing progress report and
    /// the outgoing engine dispose).
    private func startSession(request: LoadRequest, options: LoadOptions, loadID: LoadID) {
        // The one slot every fresh load competes for, so the load that owns the
        // state is the only one allowed to take it. The batch epoch already
        // stops a superseded batch before it gets here; this is the same rule
        // stated over the value the effect carries, and it is what keeps the
        // *cancel* below from ever retiring a newer load's task.
        guard loadID == state.loadID else { return }
        // The origin travels on the state the reducer just produced: only a
        // `.freshLoad` adoption ever emits `.startSession`.
        var origin = LoadOrigin.userInitiated
        if case let .preparing(preparing) = state,
           case let .freshLoad(loadOrigin) = preparing.adoption {
            origin = loadOrigin
        }
        tasks[.freshLoad]?.cancel()
        tasks[.freshLoad] = Task { [weak self] in
            guard let self else { return }
            guard let shell = await self.shell else { return }
            do {
                let resolved = try await shell.prepareFreshSession(
                    request: request,
                    options: options,
                    origin: origin
                )
                guard !Task.isCancelled else { return }
                await self.ingest(
                    .session(
                        .prepared(
                            PreparedPlaybackRef(resolved.prepared),
                            ExecutionPlanRef(resolved.plan),
                            for: loadID
                        ),
                        resolved.identity
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // `handleBeginFreshLoadFailure`'s three-way branch, kept in the
                // shell because two of its arms are pure presentation (the Next
                // Up postroll, a warning notice). It answers with the message
                // the error wall should carry, or `nil` when this origin keeps
                // the player on a recoverable surface instead.
                let message = await shell.presentLoadFailure(error, origin: origin)
                await self.abandonLoad(loadID, message: message, origin: origin)
            }
        }
    }

    /// A load that resolved to nothing.
    ///
    /// The state machine has no other resting place for a load with no session,
    /// so the terminal transition runs either way; what differs is whether the
    /// error wall is published. `message == nil` is the autoplay/recovery arm,
    /// which deliberately leaves the player on a recoverable surface.
    private func abandonLoad(_ loadID: LoadID, message: String?, origin: LoadOrigin) async {
        guard state.loadID == loadID else { return }
        let failure = PlaybackFailure(legacyMessage: message ?? "")
        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .recovery(.fail(failure), loadID),
            now: Date()
        )
        let epoch = commit(next)
        for effect in effects {
            guard epoch == transitionEpoch else { return }
            if case let .publish(presentation) = effect, message == nil {
                var recoverable = presentation
                recoverable.error = nil
                // `handleBeginFreshLoadFailure` took the overlay down under the
                // origin's own reason, which is what a console capture reads
                // these two recoverable outcomes apart by.
                recoverable.loadingReason = origin == .autoplay
                    ? "autoplay_failure"
                    : "recovery_failure"
                await publish(recoverable)
                continue
            }
            await perform(effect, epoch: epoch)
        }
    }

    private func stopSession(_ identity: SessionIdentity, position: Double?, isPaused: Bool) async {
        guard let serverSessionId = identity.serverSessionId else { return }
        await bridge.stopSession(
            expectedSessionId: serverSessionId,
            position: position ?? 0,
            isPaused: isPaused
        )
    }

    /// The 10 s heartbeat, the transcode restart's parting write — and the one
    /// the load prologue owes the session it is *leaving*.
    ///
    /// That last one is why the identity is compared with the bridge's session
    /// rather than with `state.identity`: `beginLoad` emits it carrying the
    /// outgoing identity from the same transition that commits
    /// `.preparing(identity: nil)`, so a check against the state could only
    /// ever refuse it — which is exactly what used to happen, and it cost every
    /// next-episode, retry and tvOS resume the last heartbeat's worth of
    /// resume position. The bridge still holds the outgoing session at this
    /// point (`.startSession` runs after this effect and mints the next one),
    /// so its own session id is both the right question and the final gate.
    private func reportProgress(
        _ identity: SessionIdentity,
        position: Double,
        isPaused: Bool
    ) async {
        guard let shell else { return }
        if await shell.recordOfflineProgressIfOffline() { return }
        guard await bridge.currentSessionId == identity.serverSessionId else { return }
        let result = await bridge.reportProgress(position: position, isPaused: isPaused)
        guard result == .missingSession else { return }
        // Which renewal this heartbeat's missing session deserves — silent,
        // visible, or neither because one is already in flight — is
        // `RecoveryPolicy.decideSessionMissing`'s.
        await observeOnLiveSession(.sessionMissing(source: .progressHeartbeat))
    }

    // MARK: - Engine lifecycle

    private func loadEngine(
        _ plan: PlaybackExecutionPlan,
        loadID: LoadID,
        reuseEngine: Bool,
        epoch: UInt64
    ) async {
        pendingLoadID = loadID
        if let carried = carriedOutage {
            // The replacement session adopts the ride-through together with the
            // `origin_outage` hold it releases, so the poll that owns both is
            // re-armed against this load. Without it the loop that survived the
            // replan would keep answering for a `LoadID` that no longer exists.
            await perform(
                .pollServerHealth(
                    .sourceOutageRideThrough,
                    after: .seconds(carried.nextProbeDelay),
                    loadID
                ),
                epoch: epoch
            )
        }
        guard let shell else { return }
        // The outgoing load's event pump is retired at the *commit*, not here:
        // the install prepares its replacement without touching the live
        // session, so until it commits that session is still the one playing
        // and its stream is still its own. `pumpEngineEvents` cancels the old
        // pump as it installs the new one; in between, `pendingLoadID` (moved
        // above) is already what `ingestEngineEvent` refuses the outgoing
        // stream's events against.
        let outage = carriedOutage
        let installed = await shell.installEngine(
            plan: plan,
            loadID: loadID,
            reuseEngine: reuseEngine,
            adoptingOutage: outage
        )
        guard pendingLoadID == loadID else { return }
        guard let events = installed.events else {
            // The source proxy or the plan could not be executed. A `nil`
            // message means the load was already superseded, so there is
            // nothing to fail.
            if let failure = installed.failure {
                await ingest(
                    .recovery(.fail(PlaybackFailure(legacyMessage: failure)), loadID)
                )
            }
            return
        }
        pumpEngineEvents(events, loadID: loadID)
    }

    private func disposeEngine(_ loadID: LoadID, sourceCache: SourceCacheDisposition) async {
        guard let shell else { return }
        // `disposeEngineOnly`: the visible server-outage recovery keeps the
        // session alive as this load's recovery owner while it waits out the
        // server. Every other site retires the session.
        var engineOnly = false
        if case let .playing(playing) = state,
           playing.loadID == loadID,
           case let .recovering(step) = playing.sub,
           step == .recoveringFromServerOutage {
            engineOnly = true
        }
        if pendingLoadID == loadID, !engineOnly { pendingLoadID = nil }
        await shell.teardownEngine(
            loadID: loadID,
            sourceCache: sourceCache,
            engineOnly: engineOnly
        )
    }

    /// One registered task per `LoadID`, consuming that session's event stream.
    ///
    /// The stream belongs to one `PlaybackEngineSession`, ends when that session
    /// is disposed, and every element is stamped with the load it belongs to
    /// before the reducer sees it — which is why a late event from a superseded
    /// load is dropped structurally rather than by a captured generation
    /// number. Installing the new pump retires the old one, and it happens at
    /// the install's commit, never before it.
    private func pumpEngineEvents(_ events: AsyncStream<EngineEvent>, loadID: LoadID) {
        tasks[.engineEvents]?.cancel()
        tasks[.engineEvents] = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.ingestEngineEvent(event, loadID: loadID)
            }
        }
    }

    /// One engine event, stamped with the load that produced it. Internal
    /// because it *is* the pump's body: a test drives the same path the stream
    /// does rather than a parallel one.
    func ingestEngineEvent(_ event: EngineEvent, loadID: LoadID) async {
        guard pendingLoadID == loadID else { return }

        // The shell-executed recovery arm. The load's `RecoveryDriver` already
        // decided, so it enters as `.recovery` — never as an engine event.
        if case let .recoveryAction(action) = event {
            await ingest(.recovery(action, loadID))
            return
        }

        // The one event the actor still gates before the reducer: the
        // post-outage-reload suppression window. The reduction runs first all
        // the same — it decides nothing, it only records the failure text the
        // server-HLS fallback rung replans with.
        if case let .failed(failure) = event {
            await ingest(.engine(event, loadID))
            await handleEngineFailure(failure)
            return
        }

        let before = state
        await ingest(.engine(event, loadID))
        await publishTransportIfChanged()

        await shell?.applyEngineEventToPresentation(
            event,
            reduction: Self.reduction(of: event, from: before, to: state)
        )
    }

    /// What the reduction did with the event the shell is about to see.
    ///
    /// The shell half runs *after* the reducer's, so the two arms that used to
    /// read the pre-event value off the published state cannot: `isPlaying` has
    /// already been merged by the `.pauseChanged` publish, and an event the
    /// reducer **refused** (a stale time frame, a duration a `.transcode`
    /// delivery must not adopt, an end-of-file during a visible outage
    /// recovery) would otherwise still run its presentation half in full.
    private static func reduction(
        of event: EngineEvent,
        from before: PlaybackState,
        to after: PlaybackState
    ) -> EngineEventReduction {
        EngineEventReduction(
            accepted: accepted(event, from: before, to: after),
            wasPlaying: isPlaying(before)
        )
    }

    private static func accepted(
        _ event: EngineEvent,
        from before: PlaybackState,
        to after: PlaybackState
    ) -> Bool {
        switch event {
        case .time:
            // `onTimeChange` drops stale drainage frames and backward loader
            // frames but still keeps Now Playing fresh, so the two outcomes are
            // not interchangeable.
            return playheadAdvanced(from: before, to: after)
        case .duration:
            return duration(of: before) != duration(of: after)
        case .endOfFile:
            // `handleEndOfFile` returned at its first statement while a visible
            // server-outage recovery owned the load; the reducer expresses the
            // same refusal by leaving the sub-state alone.
            guard case let .playing(playing) = after else { return false }
            return playing.sub == .ended
        default:
            return true
        }
    }

    private static func playheadAdvanced(from before: PlaybackState, to after: PlaybackState) -> Bool {
        guard case let .playing(old) = before, case let .playing(new) = after else { return false }
        return old.transport.positionSeconds != new.transport.positionSeconds
    }

    private static func duration(of state: PlaybackState) -> Double? {
        guard case let .playing(playing) = state else { return nil }
        return playing.transport.durationSeconds
    }

    private static func isPlaying(_ state: PlaybackState) -> Bool {
        switch state {
        case .playing(let playing): return !playing.transport.isPaused
        case .preparing(let preparing): return !preparing.transport.isPaused
        case .idle, .suspended, .failed, .disposed: return false
        }
    }

    /// `handlePlaybackError`'s remainder: rung 1's load-state gate, then the
    /// hand-off to the load's recovery owner.
    private func handleEngineFailure(_ failure: PlaybackFailure) async {
        if case let .playing(playing) = state, case .ended = playing.sub {
            Self.logger.info(
                "Ignoring playback error after EOF: \(failure.legacyMessage, privacy: .public)"
            )
            return
        }
        if suppressesEngineFailuresAfterOutage {
            Self.logger.info(
                "Ignoring playback error while server outage recovery is active: \(failure.legacyMessage, privacy: .public)"
            )
            return
        }
        await observeOnLiveSession(.engineFailed(failure))
    }

    /// Feed one shell-owned observation to the live load's `RecoveryDriver` and
    /// route whatever it decides back through the reducer. The driver is the
    /// only runtime caller of `RecoveryPolicy.decide`; this is the actor's
    /// single entry to it.
    private func observeOnLiveSession(_ observation: RecoveryObservation) async {
        guard let shell, state.loadID != nil else { return }
        await shell.observeRecovery(observation)
    }

    // MARK: - Replan

    private func replan(_ intent: ReplanIntent, identity: SessionIdentity) {
        tasks[.protocolV3Replan]?.cancel()
        tasks[.protocolV3Replan] = Task { [weak self] in
            guard let self else { return }
            guard let shell = await self.shell else { return }
            do {
                let resolved = try await shell.prepareReplan(intent)
                guard !Task.isCancelled else {
                    await self.finishReplan(intent)
                    return
                }
                if let resolved {
                    await self.ingest(
                        .session(
                            .replanned(
                                PreparedPlaybackRef(resolved.prepared),
                                ExecutionPlanRef(resolved.plan)
                            ),
                            resolved.identity
                        )
                    )
                } else {
                    await self.ingest(.session(.replanUnavailable, identity))
                }
                await self.finishReplan(intent)
            } catch is CancellationError {
                await self.finishReplan(intent)
            } catch {
                Self.logger.error(
                    "Protocol V3 replan failed: \(String(describing: error), privacy: .public)"
                )
                await self.finishReplan(intent)
                if PlaybackSessionBridge.isPlaybackSessionMissing(error) {
                    // This source never tries the silent renewal first —
                    // `RecoveryPolicy.decideSessionMissing` short-circuits
                    // `.replanCatch` onto the visible renewal.
                    await self.observeOnLiveSession(.sessionMissing(source: .replanCatch))
                    return
                }
                await self.ingest(
                    .session(
                        .terminal(
                            PlaybackV3TerminalFailure(
                                reason: "replan_failed",
                                message: error.localizedDescription,
                                retryable: false
                            )
                        ),
                        identity
                    )
                )
            }
        }
    }

    /// `attemptProtocolV3Replan`'s two `defer`s: release the in-route
    /// suspension the replan held for the whole round trip — on whichever
    /// session owns the backend when it ends — and clear the quality spinner.
    private func finishReplan(_ intent: ReplanIntent) async {
        await shell?.releaseReplanSuspension(
            completingQualitySwitch: intent.completesQualitySwitch
        )
    }

    // MARK: - Silent source renewal

    private func renewSource(_ renewal: SourceRenewal, identity: SessionIdentity) {
        tasks[.backgroundRenewal]?.cancel()
        tasks[.backgroundRenewal] = Task { [weak self] in
            guard let self else { return }
            guard let shell = await self.shell else { return }
            do {
                let renewed = try await shell.prepareRenewal(renewal)
                guard !Task.isCancelled else { return }
                guard let renewed else {
                    // Superseded while in flight: the load moved on, so the
                    // answer belongs to nothing.
                    return
                }
                await self.ingest(
                    .session(
                        .renewed(PreparedPlaybackRef(renewed.prepared), replacing: identity),
                        renewed.identity
                    )
                )
                // Sub-state first, policy flag second, exactly as the failure
                // arm below — and for the same reason. The success note used to
                // be `prepareRenewal`'s own last statement, two awaits (the
                // realtime unbind/bind) and an actor hop before this reduction,
                // so every silent renewal left the same stranding window open
                // on the path that runs far more often.
                await shell.noteRenewalSucceeded()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Sub-state first, policy flag second, never the other way
                // round: a `.sessionMissing` landing between the two releases
                // must find one of them still closed. Clearing
                // `backgroundRenewalInFlight` first let the policy decide a
                // renewal the reducer then swallowed against the sub-state this
                // reduction had not cleared yet — stranding the flag, and every
                // later silent renewal, for the rest of the load.
                //
                // The transient budget lives in `RecoveryContext`; the shell
                // notes the failure on the driver and reports whether the silent
                // path is spent.
                await self.ingest(.session(.renewalFailed, identity))
                let escalates = await shell.noteRenewalFailure(error, reason: renewal.reason)
                guard escalates,
                      let source = Self.sessionMissingSource(forReason: renewal.reason) else {
                    return
                }
                await self.observeOnLiveSession(.sessionMissing(source: source))
            }
        }
    }

    /// The typed source behind a renewal's `reason` token, so an escalation
    /// re-enters `RecoveryPolicy.decideSessionMissing` on the rung the silent
    /// renewal was decided from.
    private static func sessionMissingSource(forReason reason: String) -> SessionMissingSource? {
        switch reason {
        case SessionMissingSource.playerError.reason: return .playerError
        case SessionMissingSource.proxy404.reason: return .proxy404
        case SessionMissingSource.progressHeartbeat.reason: return .progressHeartbeat
        case SessionMissingSource.replanCatch.reason: return .replanCatch
        default: return nil
        }
    }

    // MARK: - Timers

    private func key(for timerID: TimerID) -> PlayerTaskRegistry.Key {
        switch timerID {
        case .freshLoad: return .freshLoad
        case .protocolV3Replan: return .protocolV3Replan
        case .staleSessionRecovery: return .staleSessionRecovery
        case .backgroundRenewal: return .backgroundRenewal
        case .sourceOutageRideThrough: return .sourceOutageRideThrough
        case .serverOutageRecovery: return .serverOutageRecovery
        case .interruptionRecovery: return .interruptionRecovery
        case .seekFilterTimeout: return .seekFilterTimeout
        case .progress: return .progress
        }
    }

    private func cancel(_ timerID: TimerID) async {
        let key = key(for: timerID)
        tasks[key]?.cancel()
        tasks[key] = nil
        switch timerID {
        case .sourceOutageRideThrough:
            // `clearSourceOutageRideThroughState()`. Dropping the carried
            // ride-through *is* the release of the `origin_outage` hold for
            // every session installed after this point — the engine session
            // survives an outage recovery, so nothing else would release it.
            carriedOutage = nil
            await shell?.clearOutageNoticeLatch()
        case .serverOutageRecovery:
            // `clearServerOutageRecoveryState()`: the policy's slot has to be
            // released with the task that owned the wait, and the suppression
            // window closes with it.
            suppressesEngineFailuresAfterOutage = false
            await shell?.clearServerOutageRecoverySlot()
        default:
            break
        }
    }

    private func schedule(_ timerID: TimerID, after delay: Duration, loadID: LoadID) {
        let key = key(for: timerID)
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.ingest(.timer(timerID, loadID))
        }
    }

    // MARK: - Server health polls

    /// Both wait loops — the origin-outage ride-through
    /// (`.sourceOutageRideThrough`) and the visible server-outage recovery
    /// (`.serverOutageRecovery`). Each probes once, feeds the result to the live
    /// load's recovery owner, and lets the policy decide whether to continue,
    /// escalate or finish; a continuation arrives as another
    /// `Effect.pollServerHealth`, which is the shape `runOutageRideThrough` and
    /// `waitForServerReady` had.
    ///
    /// The live session is re-resolved on **every** turn and never captured,
    /// which is what lets the `origin_outage` hold be released across an
    /// in-place replan.
    private func pollServerHealth(_ timerID: TimerID, after delay: Duration, loadID: LoadID) {
        let key = key(for: timerID)
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            await self.runHealthProbe(timerID, loadID: loadID)
        }
    }

    private func runHealthProbe(_ timerID: TimerID, loadID: LoadID) async {
        guard let shell else { return }
        // The visible recovery is load-scoped — it keeps the `LoadID` it
        // started under while it disposes the engine — but the ride-through is
        // **not**: a replan (in place or route-changing) mints a new one and
        // the loop has to survive it, exactly as `runOutageRideThrough` did by
        // being gated on the ride-through's own liveness rather than on the
        // load. Its state is the carry (adopted, with the `origin_outage` hold,
        // by every session the actor installs while it is set).
        if timerID == .sourceOutageRideThrough {
            let live = await shell.liveOutageState()
            guard state.loadID != nil, live != nil || carriedOutage != nil else { return }
        } else {
            guard state.loadID == loadID else { return }
        }
        let reachable = await shell.probeServerHealthOnce(reporting: timerID)
        guard !Task.isCancelled, let currentLoadID = state.loadID else { return }
        if timerID == .sourceOutageRideThrough {
            let stillRiding = await shell.liveOutageState() != nil
            guard carriedOutage != nil || stillRiding else { return }
            if reachable {
                Self.logger.info("[CMP-OUTAGE] server healthy; nudging origin re-probe")
                await shell.reprobeOrigin()
            }
        } else if currentLoadID != loadID {
            return
        }
        await observeOnLiveSession(.serverHealthProbe(ok: reachable))
        guard timerID == .serverOutageRecovery, reachable else { return }
        // `waitForServerReady`'s `true` return: the policy cleared its slot and
        // answered nothing, because the tail of the visible recovery is the
        // replacement load — the one thing that takes the "Reconnecting"
        // surface back down. The reducer owns which load that is.
        let resumePosition = PlaybackReducer.presentation(for: state).currentTime
        Self.logger.info(
            "[CMP-RECOVERY] server ready; restarting playback position=\(resumePosition, privacy: .public)"
        )
        await ingest(.timer(.serverOutageRecovery, currentLoadID))
    }

    // MARK: - Replans and reloads the shell mints

    /// A replan the shell decided (both seek re-anchor paths). `requestReplan`
    /// is `internal` on the reducer for exactly this: no `PlayerIntent` mints a
    /// `.transcodeRestart`, and the seek re-anchor's precondition — the plan's
    /// delivery and the server's `seek_reanchor` feature — is shell knowledge.
    /// The single replan slot, the prologue and the effects are still the
    /// reducer's.
    func requestReplan(_ intent: ReplanIntent) async {
        guard case let .playing(playing) = state else { return }
        let (next, effects) = PlaybackReducer.requestReplan(playing, intent: intent)
        let epoch = commit(next)
        await run(effects, epoch: epoch)
    }

    /// Re-install the engine for the load that is already playing, under a
    /// replacement plan the shell minted (contract note (e)): the
    /// native-direct -> loopback fallback and the loopback seek-before-anchor
    /// rebuild both replace the local execution route without touching the
    /// server session, which is the case the reducer's `fileLoaded` `.playing`
    /// arm already models as "a replacement item inside the same load".
    /// Keeping the `LoadID` is what makes that arm reachable — a fresh one
    /// would strand the outstanding re-anchor filter.
    ///
    /// The plan is written onto `Playing` before the load is issued, so the
    /// rules that read it — `reuseEngine` and the transcode duration guard —
    /// see the plan the engine is actually running rather than the retired
    /// one.
    func reloadEngine(with plan: PlaybackExecutionPlan) async {
        guard case var .playing(playing) = state else { return }
        let replacement = ExecutionPlanRef(plan)
        playing.plan = replacement
        let epoch = commit(.playing(playing))
        await perform(.loadEngine(replacement, playing.loadID, reuseEngine: false), epoch: epoch)
    }

    // MARK: - Teardown

    /// `cleanup()`'s control-plane half: `.dismiss` cancels every timer,
    /// disposes the engine and stops the session, and this drops the loops the
    /// registry owns.
    func shutdown() async {
        await send(.dismiss)
        tasks.cancelAll(in: .teardown)
        pendingLoadID = nil
    }
}
