//
//  RecoveryPolicy.swift
//
//  ONE owner for every recovery ladder. `RecoveryDriver` is its only caller.
//
//  A recovery decision used to be made in nine places: six in-route ladders
//  inside `AVPlayerBackend` (startup watchdog, playhead watchdog, item-death
//  evidence, edge watchdog, `.AVPlayerItemPlaybackStalled`, "Playlist File
//  unchanged"), and three inside `PlayerViewModel` (`handlePlaybackError`, the
//  origin-outage ride-through, the two session renewals) — coordinated by a
//  two-owner handshake (the retired recovery suspension pair and the
//  post-outage playback kick that went with them). Every constant, every latch
//  and every precedence rule from those nine sites lives here, unchanged.
//
//  `decide` is pure and total: no clock, no player, no I/O, one `switch` with
//  no `default`. `now` is a parameter so a test can drive a 90 s rolling window
//  in microseconds. It returns at most **one** action per observation — the
//  ladders never take two steps for one signal, and the one place that looks
//  like it might (the playhead tick's `.reassertPlay`, which falls through
//  instead of returning) is proved below to be single-action.
//

import Foundation

enum RecoveryPolicy {

    // MARK: - Constants
    //
    // Each is the literal at the cited line, with the name it has today.

    /// The startup ladder escalates (nudge seek → in-place item reload →
    /// report) only when the loopback server has served no request for this
    /// long. A dead loader stops fetching within seconds, so a genuine failure
    /// falls back *faster* than the fixed readiness timeout this replaced, while
    /// a slow heavy mux gets all the time it needs.
    static let loopbackStartupStallWindowSeconds: TimeInterval = 6.0
    /// The absolute backstop, measured from `StartupState.startedAt`. It bounds
    /// the pathological "fetches forever, never ready" consumer, which no stall
    /// window can catch.
    static let loopbackStartupAbsoluteBackstopSeconds: TimeInterval = 60.0
    /// The forward buffer the loopback item starts with
    /// (`AVPlayerBackend.loopbackStartupForwardBuffer`), reused here as the
    /// shared reanchor rung's pre-10 s `minimumGeneratedAhead`.
    static let loopbackStartupForwardBuffer: Double = 4.0

    /// AVPlayer believes it is playing but the playhead has not advanced for
    /// this long while generated media is available ahead: reanchor.
    static let playheadWatchdogStallSeconds: Double = 10.0
    /// Kept above the reanchor rung's own steady-state `generatedAhead`
    /// threshold (`reanchorSteadyStateGeneratedAhead`) so a watchdog trigger
    /// never bails inside recovery.
    static let playheadWatchdogMinGeneratedAhead: Double = 12.0
    /// After this many failed reanchors inside
    /// `playheadWatchdogReanchorWindowSeconds`, rebuild the complete Silo
    /// loopback pipeline at the rendered clock.
    static let playheadWatchdogMaxReanchors = 3
    static let playheadWatchdogReanchorWindowSeconds: Double = 90.0
    /// Starvation escalation: the reanchor rung requires generated media ahead
    /// of the playhead, so a *producer-dead* stall (e.g. the spill-gate
    /// deadlock) never qualified and the session froze forever. If AVPlayer has
    /// been waiting on an empty buffer this long while the store served nothing,
    /// rebuild the local pipeline at the rendered clock. The serve-quiet guard
    /// keeps ordinary slow-WAN rebuffers (segments still flowing) from tripping
    /// it.
    static let playheadWatchdogStarvationEscalateSeconds: Double = 30.0
    static let playheadWatchdogStarvationServeQuietSeconds: Double = 15.0

    /// The shared reanchor rung's cooldown, a literal `10` today.
    static let reanchorCooldownSeconds: Double = 10.0
    /// The playhead tick's fetch-high-water bail, a literal `4.0`.
    static let fetchHighWaterSeconds: Double = 4.0

    /// `serverOutageRecoveryInitialDelay`.
    static let serverOutageRecoveryInitialDelay: TimeInterval = 1
    /// `serverOutageRecoveryMaxDelay`.
    static let serverOutageRecoveryMaxDelay: TimeInterval = 8
    /// `serverOutageRecoveryTimeout`.
    static let serverOutageRecoveryTimeout: TimeInterval = 90
    /// `nearEndPlaybackErrorThresholdSeconds`.
    static let nearEndPlaybackErrorThresholdSeconds: Double = 8
    /// `nearEndPlaybackErrorMaxBufferedAheadSeconds`.
    static let nearEndPlaybackErrorMaxBufferedAheadSeconds: Double = 1
    /// `backgroundRenewalTransientFailureLimit`.
    static let backgroundRenewalTransientFailureLimit = 3

    // Rung thresholds that are inline literals today and have no name yet.

    /// The playhead advance epsilon; movement in **either** direction
    /// counts as alive.
    static let playheadAdvanceEpsilon: Double = 0.05
    /// `mediaAvailableAhead` for the item-death confirmation state.
    static let itemDeathMediaAvailableBufferedAhead: Double = 0.5
    /// The generated half of the same predicate.
    static let itemDeathMediaAvailableGeneratedAhead: Double = 2.0
    /// The starvation rung's empty-buffer test and the wedge
    /// qualifier's "legitimately waiting" test.
    static let playheadBufferedAheadStarvationCeiling: Double = 2.0
    /// The shared reanchor rung's buffered-edge requirement.
    static let reanchorBufferedEdgeCeiling: Double = 0.5
    /// Above this player time the rung wants a full steady-state
    /// runway instead of one fragment.
    static let reanchorSteadyStatePlayerSeconds: Double = 10
    /// The steady-state `minimumGeneratedAhead`.
    static let reanchorSteadyStateGeneratedAhead: Double = 10
    /// Edge-watchdog advance epsilons.
    static let edgeAdvanceEpsilon: Double = 0.25
    /// The loaded runway that qualifies as "the edge is at the
    /// playhead".
    static let edgeLoadedAheadCeiling: Double = 1.0
    /// Floor of the visible-runway requirement.
    static let edgeVisibleAheadFloor: Double = 6.0
    /// Floor of `max(3.0, targetDuration * 2 + 1)`.
    static let edgeWatchdogDelayFloor: Double = 3.0
    /// The target-duration multiplier and addend of the same
    /// expression.
    static let edgeWatchdogDelayTargetMultiple: Double = 2.0
    static let edgeWatchdogDelayTargetAddend: Double = 1.0
    /// The target duration is floored before it is used.
    static let edgeTargetDurationFloor: Double = 1.0
    /// The auto-resume rung's buffered-runway alternative to
    /// `isPlaybackLikelyToKeepUp`.
    static let autoResumeBufferedAheadFloor: Double = 0.5

    /// The terminal message when the server never came back.
    static let serverOutageTimeoutMessage = "The server did not come back online in time."

    // MARK: - Decide

    /// The single recovery decision point.
    ///
    /// - Parameters:
    ///   - observation: what happened.
    ///   - context: the load's recovery state.
    ///   - now: the wall clock. All windows, cooldowns and budgets are measured
    ///     against it; nothing here reads a clock of its own.
    /// - Returns: at most one action, and the next context. `nil` means "this
    ///   observation does not qualify" — the overwhelmingly common answer.
    static func decide(
        _ observation: RecoveryObservation,
        context: RecoveryContext,
        now: Date
    ) -> (action: RecoveryAction?, context: RecoveryContext) {
        var context = context
        switch observation {
        case let .startupTick(servedRequests, displayModeSwitchInProgress):
            return decideStartupTick(
                servedRequests: servedRequests,
                displayModeSwitchInProgress: displayModeSwitchInProgress,
                context: &context,
                now: now
            )

        case let .playheadTick(sample):
            return decidePlayheadTick(sample: sample, context: &context, now: now)

        case let .itemDeathEvidence(statusCode, description, weight, position, userPaused):
            return decideItemDeathEvidence(
                statusCode: statusCode,
                description: description,
                weight: weight,
                position: position,
                userPaused: userPaused,
                context: &context,
                now: now
            )

        case let .edgeSample(sample):
            return decideEdgeSample(sample: sample, context: &context, now: now)

        case .playbackStalled:
            // `recoverLocalLoopbackStallIfNeeded(item:)` with both
            // defaults.
            return reanchorIfNeeded(
                requireBufferedEdge: true,
                cause: .stall,
                context: &context,
                now: now
            )

        case let .itemFailedToEnd(position, userPaused):
            return decideItemFailedToEnd(
                position: position,
                userPaused: userPaused,
                context: &context,
                now: now
            )

        case let .playlistUnchanged(userPaused):
            return decidePlaylistUnchanged(userPaused: userPaused, context: &context, now: now)

        case let .likelyToKeepUp(rate, bufferedAhead, reachedEnd, likely):
            return decideLikelyToKeepUp(
                rate: rate,
                bufferedAhead: bufferedAhead,
                reachedEnd: reachedEnd,
                likely: likely,
                context: &context
            )

        case let .interactiveSeekDeadlineExpired(mediaTarget):
            return decideInteractiveSeekDeadlineExpired(
                mediaTarget: mediaTarget,
                context: &context
            )

        case let .engineFailed(failure):
            return decideEngineFailed(failure, context: &context, now: now)

        case let .originOutage(active):
            return decideOriginOutage(active: active, context: &context, now: now)

        case let .sourceInterrupted(reason):
            return beginServerOutageRecovery(
                reason: Self.token(for: reason),
                context: &context,
                now: now
            )

        case let .sessionMissing(source):
            return decideSessionMissing(source: source, context: &context)

        case let .serverHealthProbe(ok):
            return decideServerHealthProbe(ok: ok, context: &context, now: now)

        case .runwayExhaustedDuringOutage:
            // The runway gate. The notice itself is presentation; what the
            // policy owns is the once-per-outage latch, which is also what
            // decides whether the ride-through's exit shows "Reconnected" — the
            // caller reads `noticeShown` off the context it passed in, before
            // the exit clears the state.
            if var outage = context.outage, !outage.noticeShown {
                outage.noticeShown = true
                context.outage = outage
            }
            return (nil, context)
        }
    }

    // MARK: - S — startup ladder (`AVPlayerBackend.loopbackStartupWatchdogTick`)

    private static func decideStartupTick(
        servedRequests: UInt64,
        displayModeSwitchInProgress: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // The tick is loopback-only and pre-`didFireFileLoaded`.
        guard context.route == .siloPlayerLoopback,
              !context.playbackEstablished,
              var startup = context.startup else {
            return (nil, context)
        }

        // A served-request delta is forward progress, and an HDMI
        // display-mode switch rebases the progress clock so the stall window
        // cannot expire the instant the switch completes.
        if servedRequests != startup.lastRequestCount {
            startup.lastRequestCount = servedRequests
            startup.lastProgressAt = now
        }
        if displayModeSwitchInProgress {
            startup.lastProgressAt = now
        }
        context.startup = startup

        // `secondsSinceStart: now.timeIntervalSince(startedAt)`. The
        // backstop's clock is `StartupState.startedAt`
        // (`loopbackStartupWatchdogStartedAt`), which the tick never mutates,
        // so it reads the same before and after the progress rebasing above —
        // and the emitter owns none of the backstop decision.
        let verdict = LoopbackStartupRecoveryPolicy.verdict(
            secondsSinceProgress: now.timeIntervalSince(startup.lastProgressAt),
            secondsSinceStart: now.timeIntervalSince(startup.startedAt),
            displayModeSwitchInProgress: displayModeSwitchInProgress,
            stallWindow: loopbackStartupStallWindowSeconds,
            absoluteBackstop: loopbackStartupAbsoluteBackstopSeconds
        )
        switch verdict {
        case .wait:
            return (nil, context)
        case .escalate:
            return escalateStartupRecovery(trigger: "fetches_frozen", context: &context, now: now)
        case .failBackstop:
            // PINNED QUIRK: this arm does **not**
            // check suspension, unlike `escalateLoopbackStartupRecovery`
            // A backstop can therefore fire and report while a server
            // replan or an origin-outage ride-through holds the latch. Kept as
            // is, and pinned by
            // `testStartup_Backstop_FiresEvenWhileSuspended`.
            context.startup = nil
            return (
                .fail(.loopbackStartupBackstop(
                    seconds: Int(loopbackStartupAbsoluteBackstopSeconds),
                    requestsServed: servedRequests,
                    stage: "\(startup.stage)"
                )),
                context
            )
        }
    }

    /// The startup ladder's escalation. Also the direct entry from the item
    /// error log's `-15628` loader-poison signature, which arrives as
    /// `.itemDeathEvidence` before `playbackEstablished`.
    private static func escalateStartupRecovery(
        trigger: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // The ladder itself is muzzled while any owner holds the latch.
        guard !context.isRecoverySuspended, var startup = context.startup else {
            return (nil, context)
        }
        switch startup.stage {
        case .initial:
            startup.stage = .nudged
            startup.lastProgressAt = now
            context.startup = startup
            return (.nudgeStartup, context)
        case .nudged:
            startup.stage = .reloaded
            startup.lastProgressAt = now
            context.startup = startup
            return (.reloadStartupItem, context)
        case .reloaded:
            // Cancel the watchdog, then report.
            context.startup = nil
            return (.fail(.loopbackStartupStalled(trigger: trigger)), context)
        }
    }

    // MARK: - P — playhead watchdog (`AVPlayerBackend.loopbackPlayheadWatchdogTick`)

    private static func decidePlayheadTick(
        sample: PlayheadSample,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // Loopback, established, finite position. (`!isDisposed`,
        // `currentItem` and `!isSeekPending` are the observation source's.)
        guard context.route == .siloPlayerLoopback,
              sample.playbackEstablished,
              sample.position.isFinite else {
            return (nil, context)
        }
        context.playhead.lastSample = sample
        context.playbackEstablished = sample.playbackEstablished
        context.userPaused = sample.userPaused

        // Rung 0 — advance tracking. Movement in EITHER direction
        // counts as alive; comparing with `>` alone left the mark stale across
        // backward in-item seeks.
        if let last = context.playhead.lastAdvancePosition,
           abs(sample.position - last) <= playheadAdvanceEpsilon {
            // Stationary: keep the existing `stationarySince`.
        } else {
            context.playhead.lastAdvancePosition = sample.position
            context.playhead.stationarySince = now
        }
        let stationaryFor = context.playhead.stationarySince.map { now.timeIntervalSince($0) } ?? 0

        // Rung 1 is telemetry only and stays at the observation source.

        // Rung 2 — item-death confirmation. Runs BEFORE the suspension
        // gate but takes suppression as an input, so it degrades to `.none`.
        //
        // The backend passes `isRecoverySuspended || isWaitingForInitialVideoDisplay`.
        // The second term is dead here: `isWaitingForInitialVideoDisplay` is
        // cleared immediately before `finishInitialLoadIfNeeded` sets
        // `didFireFileLoaded`, on every one of that function's three call sites
        // (two of them reach it only when the gate is already clear), and the
        // gate is re-armed only from `startPlaybackIfNeeded`, after a `load()`
        // has reset `didFireFileLoaded` to false. The
        // tick's `didFireFileLoaded` guard therefore implies the term is false.
        let confirmation = context.itemDeathConfirmation.evaluate(
            now: now.timeIntervalSinceReferenceDate,
            position: sample.position,
            playbackEstablished: sample.playbackEstablished,
            userPaused: sample.userPaused,
            transportState: sample.timeControl.transportState,
            recoverySuppressed: context.isRecoverySuspended,
            mediaAvailableAhead: sample.bufferedAhead >= itemDeathMediaAvailableBufferedAhead
                || sample.generatedAhead >= itemDeathMediaAvailableGeneratedAhead
        )
        switch confirmation {
        case .none:
            break
        case .reassertPlay:
            // The rung issues `avPlayer.play()` and falls through. Returning here
            // is equivalent: `.reassertPlay` is only produced when
            // `transportState == .paused`, and every rung below is unreachable
            // in that state — the starvation rung requires `.waiting`
            // and the wedge qualifier requires `.playing` or `.waiting`
            // so its `guard` returns.
            return (.reassertPlay, context)
        case let .confirmed(trigger):
            let action = context.itemDeath.confirm(
                position: sample.position,
                userPaused: sample.userPaused
            )
            return performItemDeathAction(
                action,
                position: sample.position,
                trigger: trigger.rawValue,
                context: &context,
                now: now
            )
        }

        // Rung 3 — suspension gate. Everything below is muzzled.
        guard !context.isRecoverySuspended else { return (nil, context) }

        // Rung 4 — producer-dead starvation.
        if !sample.userPaused,
           sample.timeControl == .waiting,
           sample.bufferedAhead < playheadBufferedAheadStarvationCeiling,
           stationaryFor >= playheadWatchdogStarvationEscalateSeconds,
           sample.secondsSinceLastServe >= playheadWatchdogStarvationServeQuietSeconds,
           !context.playhead.didEscalateStarvation {
            context.playhead.didEscalateStarvation = true
            return rebuildLocalSession(
                atPlayerSeconds: sample.position,
                cause: .starvation,
                context: &context,
                now: now
            )
        }

        // Rung 5 — wedge qualification.
        let believesPlayable = sample.timeControl == .playing
            || (sample.timeControl == .waiting
                && sample.bufferedAhead >= playheadBufferedAheadStarvationCeiling)
        guard !sample.userPaused,
              believesPlayable,
              stationaryFor >= playheadWatchdogStallSeconds,
              sample.generatedAhead >= playheadWatchdogMinGeneratedAhead else {
            return (nil, context)
        }

        // Rung 6 — rolling window reset.
        if context.playhead.windowStart.map({
            now.timeIntervalSince($0) > playheadWatchdogReanchorWindowSeconds
        }) ?? true {
            context.playhead.windowStart = now
            context.playhead.reanchorCount = 0
            context.playhead.didEscalateStarvation = false
        }

        // Rung 7 — exhaustion.
        if context.playhead.reanchorCount >= playheadWatchdogMaxReanchors {
            guard !context.playhead.didEscalateStarvation else { return (nil, context) }
            context.playhead.didEscalateStarvation = true
            return rebuildLocalSession(
                atPlayerSeconds: sample.position,
                cause: .playheadWatchdogExhausted,
                context: &context,
                now: now
            )
        }

        // Rung 8 — fetch-high-water bail. The consumer is filling
        // after a seek, not wedged. (`secondsSinceLastServe` is `.infinity`
        // when there is no store, matching the backend's optional chain, which
        // does not bail.)
        guard sample.secondsSinceLastServe >= fetchHighWaterSeconds else {
            return (nil, context)
        }

        // Rung 9 — reanchor attempt, executed by
        // `AVPlayerBackend.performVODStallRecovery(anchorPlayerSeconds:attempt:)`.
        //
        // `vodPendingSeekMediaTarget.map(playerTime(forMediaTime:)) ??
        // frozenPosition` — an unlanded seek target wins, because a wedged
        // zero-tolerance seek leaves the frozen clock at the PRE-seek position,
        // and anchoring there would discard the user's seek. The
        // latch is already media-timeline, which is the axis the action carries,
        // so it needs no conversion; the engine converts back with the exact
        // inverse the legacy sinks use.
        context.playhead.reanchorCount += 1
        let anchor = sample.pendingSeekMediaTarget
            ?? context.mediaSeconds(forPlayerSeconds: sample.position)
        if context.playhead.reanchorCount <= 1 {
            return (.reanchor(atMediaSeconds: anchor, cause: .vodStallNudge), context)
        }
        return (.reloadItem(atMediaSeconds: anchor, cause: .vodStall), context)
    }

    // MARK: - D — item death (the item error log and the failed-to-end tail)

    private static func decideItemDeathEvidence(
        statusCode: Int?,
        description: String,
        weight: Int,
        position: Double,
        userPaused: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // Both evidence sources classify before reporting.
        guard LoopbackItemDeathRecoveryState.isItemDeath(
            statusCode: statusCode,
            errorDescription: description
        ) else {
            return (nil, context)
        }
        // `-15628` before the file-loaded edge is the loader-poison
        // signature, and it drives the *startup* ladder instead.
        guard context.playbackEstablished else {
            guard statusCode == -15628, context.route == .siloPlayerLoopback else {
                return (nil, context)
            }
            return escalateStartupRecovery(
                trigger: "errorLog_-15628",
                context: &context,
                now: now
            )
        }
        guard context.route == .siloPlayerLoopback, !context.isRecoverySuspended else {
            return (nil, context)
        }
        let action = context.itemDeath.record(
            position: position,
            evidenceWeight: weight,
            userPaused: userPaused
        )
        // The trigger names the evidence source.
        let trigger = statusCode == nil ? "failed_to_end" : "error_log"
        return performItemDeathAction(
            action,
            position: position,
            trigger: trigger,
            context: &context,
            now: now
        )
    }

    /// `performLoopbackItemDeathRecoveryAction`.
    private static func performItemDeathAction(
        _ action: LoopbackItemDeathRecoveryState.Action,
        position: Double,
        trigger: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        switch action {
        case .waitForConfirmation:
            // Log only.
            return (nil, context)
        case let .reload(attempt):
            context.itemDeathConfirmation.resetCandidate()
            return (
                .reloadItem(
                    atMediaSeconds: context.mediaSeconds(forPlayerSeconds: position),
                    cause: .itemDeath(trigger: trigger, attempt: attempt)
                ),
                context
            )
        case .escalate:
            context.itemDeathConfirmation.resetCandidate()
            return rebuildLocalSession(
                atPlayerSeconds: position,
                cause: .itemDeathRepeated,
                context: &context,
                now: now
            )
        }
    }

    // MARK: - E — edge watchdog (`AVPlayerBackend.sampleLocalLoopbackEdge`)

    private static func decideEdgeSample(
        sample: EdgeSample,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        guard context.route == .siloPlayerLoopback,
              context.playbackEstablished,
              !context.userPaused,
              sample.referenceTime.isFinite else {
            return (nil, context)
        }

        // The first sample only seeds.
        guard var watch = context.edge else {
            context.edge = RecoveryContext.EdgeWatchState(
                lastLoadedEnd: sample.loadedEnd,
                lastLoadedEndAdvancedAt: now,
                lastPlaylistEnd: sample.playlistEnd,
                lastPlaylistHash: sample.playlistHash
            )
            return (nil, context)
        }

        let loadedAdvanced = sample.loadedEnd > watch.lastLoadedEnd + edgeAdvanceEpsilon
        if loadedAdvanced {
            watch.lastLoadedEnd = sample.loadedEnd
            watch.lastLoadedEndAdvancedAt = now
        }
        let playlistAdvanced = sample.playlistEnd > watch.lastPlaylistEnd + edgeAdvanceEpsilon
            || sample.playlistHash != watch.lastPlaylistHash
        watch.lastPlaylistEnd = max(watch.lastPlaylistEnd, sample.playlistEnd)
        watch.lastPlaylistHash = sample.playlistHash
        let lastAdvancedAt = watch.lastLoadedEndAdvancedAt
        context.edge = watch

        let targetDuration = max(edgeTargetDurationFloor, sample.targetDuration)
        let watchdogDelay = max(
            edgeWatchdogDelayFloor,
            targetDuration * edgeWatchdogDelayTargetMultiple + edgeWatchdogDelayTargetAddend
        )
        guard playlistAdvanced,
              !loadedAdvanced,
              sample.loadedAhead <= edgeLoadedAheadCeiling,
              sample.visibleAhead >= max(edgeVisibleAheadFloor, targetDuration + sample.longestSegment),
              now.timeIntervalSince(lastAdvancedAt) >= watchdogDelay else {
            return (nil, context)
        }

        return reanchorIfNeeded(
            requireBufferedEdge: true,
            cause: .edgeWatchdog,
            context: &context,
            now: now
        )
    }

    // MARK: - D — explicit item failure (`AVPlayerBackend.itemFailedToEndObserver`)

    /// Every `.AVPlayerItemFailedToPlayToEndTime` on an
    /// established loopback item arms the item-death confirmation candidate and
    /// returns — no classification, no evidence counter, no immediate action.
    /// The candidate then either confirms on the next tick that is ≥ 3 s old
    /// and still parked within 0.5 s of the failure position (rung 2 of
    /// `decidePlayheadTick`), or is cancelled by the playhead moving.
    ///
    /// This is the ONLY entry point of the confirmation state's `.failedToEnd`
    /// trigger. It deliberately does not go through
    /// `LoopbackItemDeathRecoveryState.record`: that mechanism gates on
    /// `isItemDeath(statusCode:errorDescription:)` and, at weight 2, reloads at
    /// once, which is a different (and much blunter) recovery than the 3 s
    /// window this arm opens.
    private static func decideItemFailedToEnd(
        position: Double,
        userPaused: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // Loopback only, and only after the file-loaded edge.
        // Anything else falls through to the "Playlist File unchanged" /
        // `-12888` tail of `AVPlayerBackend.itemFailedToEndObserver`, which
        // arrives as `.playlistUnchanged`.
        guard context.route == .siloPlayerLoopback, context.playbackEstablished else {
            return (nil, context)
        }
        context.userPaused = userPaused
        // `noteExplicitFailure` clears the candidate itself when
        // the user is paused, which is why `userPaused` is passed rather than
        // guarded on.
        context.itemDeathConfirmation.noteExplicitFailure(
            position: position,
            now: now.timeIntervalSinceReferenceDate,
            playbackEstablished: true,
            userPaused: userPaused
        )
        return (nil, context)
    }

    // MARK: - Y — "Playlist File unchanged" (the failed-to-end tail)

    /// Reached only for a failed-to-end notification that
    /// `decideItemFailedToEnd` did not consume — that arm's early return means
    /// this tail never runs on an established loopback item today, and the
    /// rungs it calls carry that gate themselves (`reanchorIfNeeded` requires
    /// exactly `route == .siloPlayerLoopback && playbackEstablished`), so the
    /// precedence holds however the two observations are ordered.
    private static func decidePlaylistUnchanged(
        userPaused: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        context.userPaused = userPaused
        if userPaused {
            // Latch the media time; `AVPlayerBackend.play()` consumes it
            // with a full reanchoring load. Note this arm has no suspension
            // gate and no cooldown today — it only records intent.
            guard let position = context.playhead.lastSample?.position, position.isFinite else {
                return (nil, context)
            }
            return (
                .deferUntilPlay(mediaSeconds: context.mediaSeconds(forPlayerSeconds: position)),
                context
            )
        }
        return reanchorIfNeeded(
            requireBufferedEdge: false,
            cause: .playlistUnchanged,
            context: &context,
            now: now
        )
    }

    // MARK: - Shared reanchor rung (`AVPlayerBackend.performLoopbackReanchor`)

    private static func reanchorIfNeeded(
        requireBufferedEdge: Bool,
        cause: RecoveryAction.Cause,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        guard context.route == .siloPlayerLoopback,
              context.playbackEstablished,
              !context.userPaused,
              !context.isRecoverySuspended else {
            return (nil, context)
        }
        // The 10 s cooldown. `nil` is the backend's zero-initialised
        // `lastLocalLoopbackStallRecoveryAt`, which never blocks the first call.
        if let last = context.playhead.lastStallRecoveryAt,
           now.timeIntervalSince(last) < reanchorCooldownSeconds {
            return (nil, context)
        }
        guard let sample = context.playhead.lastSample, sample.position.isFinite else {
            return (nil, context)
        }
        // The buffered edge must sit at the playhead.
        guard !requireBufferedEdge || sample.bufferedAhead <= reanchorBufferedEdgeCeiling else {
            return (nil, context)
        }
        // The backend does not clamp `generatedAhead` here (the
        // tick does); the difference is unobservable because both a clamped 0
        // and a negative value fail the `>` test against a minimum of 4 or 10.
        let minimumGeneratedAhead = sample.position < reanchorSteadyStatePlayerSeconds
            ? loopbackStartupForwardBuffer
            : reanchorSteadyStateGeneratedAhead
        guard sample.generatedAhead > minimumGeneratedAhead else { return (nil, context) }

        context.playhead.lastStallRecoveryAt = now
        return (
            .reanchor(
                atMediaSeconds: context.mediaSeconds(forPlayerSeconds: sample.position),
                cause: cause
            ),
            context
        )
    }

    // MARK: - Auto-resume rung (`AVPlayerBackend.sampleLoopbackAutoResume`)

    private static func decideLikelyToKeepUp(
        rate: Double,
        bufferedAhead: Double,
        reachedEnd: Bool,
        likely: Bool,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // The `!reachedEnd` term (the backend's `hasReachedItemEnd`) is
        // load-bearing: a buffer KVO arriving after end-of-file must not
        // restart transport behind the hand-off.
        guard context.route == .siloPlayerLoopback,
              context.playbackEstablished,
              !context.userPaused,
              !reachedEnd,
              !context.isRecoverySuspended,
              rate == 0 else {
            return (nil, context)
        }
        guard likely || bufferedAhead > autoResumeBufferedAheadFloor else {
            return (nil, context)
        }
        return (.resumePlayback, context)
    }

    // MARK: - Seek deadlines (`AVPlayerBackend.handleSeekDeadline`)

    private static func decideInteractiveSeekDeadlineExpired(
        mediaTarget: Double,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // On loopback the latched seek target is the anchor, and the recovery is
        // `performVODStallRecovery(attempt: 1, …)` — i.e. the same recipe
        // `.reanchor(cause: .vodStallNudge)` names. There is deliberately no
        // cooldown and no suspension gate on this path.
        if context.route == .siloPlayerLoopback {
            return (
                .reanchor(atMediaSeconds: mediaTarget, cause: .vodStallNudge),
                context
            )
        }
        guard !context.userPaused else { return (nil, context) }
        return (.resumePlayback, context)
    }

    // MARK: - Rebuild (`AVPlayerBackend.performLoopbackReanchor`, rebuilding)

    private static func rebuildLocalSession(
        atPlayerSeconds playerSeconds: Double,
        cause: RecoveryAction.Cause,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        guard context.route == .siloPlayerLoopback,
              playerSeconds.isFinite,
              !context.userPaused else {
            return (nil, context)
        }
        // Every rebuild resets the latches that decided to
        // rebuild, so without the budget the same wedge rebuilds forever.
        guard context.rebuildBudget.consume() else {
            return (
                .fail(.loopbackRebuildBudgetExhausted(
                    reason: cause.token,
                    rebuilds: context.rebuildBudget.used
                )),
                context
            )
        }
        context.itemDeath.reset()
        context.itemDeathConfirmation.resetCandidate()
        context.playhead.reanchorCount = 0
        context.playhead.windowStart = now
        context.playhead.didEscalateStarvation = false
        return (
            .rebuildLocalSession(
                atMediaSeconds: context.mediaSeconds(forPlayerSeconds: playerSeconds),
                cause: cause
            ),
            context
        )
    }

    // MARK: - The view model's failure ladder (`PlayerViewModel.handlePlaybackError`)

    private static func decideEngineFailed(
        _ failure: PlaybackFailure,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // Rung 1 (`hasReachedEndOfFile`) is a load-state gate, not a
        // recovery decision: after end-of-file the load is in its terminal
        // state and the engine does not report failures into recovery at all
        // (`PlaybackState` carries the `.ended` sub-state).

        // Rung 2 — a visible outage recovery already owns the load. The wider
        // window is `PlaybackSessionActor.suppressesEngineFailuresAfterOutage`,
        // which reaches into the *replacement* load and so cannot live in a
        // per-load context; this rung catches the failures already queued on
        // the engine's stream when the recovery was decided, which the actor
        // dequeues before it raises that window.
        guard context.serverOutageRecovery == nil else { return (nil, context) }

        // Rung 3 — `shouldTreatPlaybackErrorAsNaturalEnd`.
        if let nearEnd = context.nearEnd, shouldTreatAsNaturalEnd(nearEnd) {
            return (.treatAsNaturalEnd, context)
        }

        // Rung 4 — while Protocol V3 is active the server owns
        // delivery and fallback, so every rung below is online-unreachable.
        if context.isProtocolV3Active {
            return (
                .requestServerReplan(
                    classification: failure.classification,
                    message: failure.legacyMessage
                ),
                context
            )
        }

        // Rung 5 — the server no longer knows this session.
        if failure.isPlaybackSessionMissing {
            return decideSessionMissing(source: .playerError, context: &context)
        }

        // Rung 6 — ingest ended short of the known content.
        if failure.isPrematureSourceEnd {
            return beginServerOutageRecovery(
                reason: token(for: .networkUnavailable),
                context: &context,
                now: now
            )
        }

        // Rung 7 (`progressTask?.cancel()`) is an effect, not a
        // decision — but it is NOT unconditional. It sits *below* the rungs
        // above, so it runs only when the ladder reaches rung 8 or lower: it is
        // part of executing `.autoRecoverInterruption`, `.switchRoute` and
        // `.fail`, and it must NOT be performed when this ladder returns
        // `.renewSourceInBackground`. A silent renewal that failed transiently
        // deliberately re-arms nothing — "so the next trigger (progress
        // heartbeat or stream 404) retries" — so cancelling the 10 s progress
        // loop here would kill the only thing that retries it. The rungs above
        // that do want the loop stopped stop it themselves inside their own
        // execution: the replan, the visible renewal and the server-outage
        // recovery.

        // Rung 8 — `shouldAutoRecoverFromInterruption`.
        if context.canAutoRecoverInterruption {
            return (.autoRecoverInterruption, context)
        }

        // Rung 9 — `attemptNativeDirectRouteRecovery`.
        if context.route == .avPlayerNativeDirect, !context.attemptedNativeDirectFallback {
            if context.canBuildLoopbackFallback {
                context.attemptedNativeDirectFallback = true
                return (.switchRoute(.loopbackFallback), context)
            }
            // Nothing local can remux this source, so the only
            // rung left is a server-produced HLS rendition — and the latch is
            // set only if that replan was actually accepted
            // (`requestServerHLSRouteFallback` needs a watch detail to replan
            // against and no replan already running;
            // without one `attemptNativeDirectRouteRecovery` returns false and
            // the ladder falls through to rung 10, which fails the same guard).
            if context.hasWatchDetail, !context.isReplanInFlight {
                context.attemptedNativeDirectFallback = true
                return (
                    .switchRoute(.serverHLS(classification: "native_direct_avplayer_failed")),
                    context
                )
            }
        }

        // Rung 10 — `attemptSiloRouteHLSFallback`, which
        // also goes through `requestServerHLSRouteFallback`'s guard.
        if context.route == .siloPlayerLoopback,
           !context.attemptedLoopbackHLSFallback,
           context.hasWatchDetail,
           !context.isReplanInFlight {
            context.attemptedLoopbackHLSFallback = true
            return (
                .switchRoute(.serverHLS(classification: "silo_loopback_failed")),
                context
            )
        }

        // Terminal.
        return (.fail(failure), context)
    }

    /// `shouldTreatPlaybackErrorAsNaturalEnd`, verbatim.
    static func shouldTreatAsNaturalEnd(_ inputs: RecoveryContext.NearEndInputs) -> Bool {
        guard inputs.duration.isFinite, inputs.duration > 0,
              inputs.currentTime.isFinite, inputs.currentTime > 0 else {
            return false
        }
        guard !inputs.sourceOutageActive else { return false }
        if inputs.bufferedAhead.isFinite,
           inputs.bufferedAhead > nearEndPlaybackErrorMaxBufferedAheadSeconds {
            return false
        }
        return inputs.duration - inputs.currentTime <= nearEndPlaybackErrorThresholdSeconds
    }

    // MARK: - Session renewal (silent retarget, then visible re-load)

    private static func decideSessionMissing(
        source: SessionMissingSource,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // Three of the four sources try the silent renewal
        // first; the V3 replan's `catch` does not. It calls
        // `attemptStaleSessionRenewal` directly and deliberately:
        // states that once the server has re-planned "only a full visible
        // renewal can pick up the new plan", while the silent path keeps the
        // existing plan, session and backend alive and merely retargets the
        // proxy's origin. The silent path's preconditions are all
        // satisfiable where this fires (a V3 session on `.direct` delivery with
        // a live proxy and a loaded watch detail), so without this
        // short-circuit the rung would divert a replan failure into a retarget
        // of the stale plan.
        if case .replanCatch = source {
            return renewSessionFresh(reason: source.reason, context: &context)
        }
        // A silent renewal only exists on a proxied direct
        // source that is online and has a watch detail loaded.
        if context.canRenewSourceInBackground {
            // The decide-time half of the single-flight: an already-decided
            // renewal counts as handled and takes no new action. It covers the
            // window `Sub.renewingSource` cannot — this decision to the
            // reduction that records it — and is released by the driver's
            // renewal notes, always *after* the reduction that clears the
            // sub-state (`PlaybackSessionActor.renewSource`).
            if context.backgroundRenewalInFlight { return (nil, context) }
            // `failBackgroundRenewal`: once the
            // transient budget is spent, escalate to the visible renewal with
            // the `_bg_renewal_failed` suffix.
            //
            // How the engine reports a failed silent renewal matters, because
            // the two failure classes behave differently today:
            //  * transient (below the limit) — clear
            //    `backgroundRenewalInFlight`, increment
            //    `backgroundRenewalTransientFailures`, and do NOTHING else. The
            //    legacy `catch` deliberately re-arms nothing 'so the next
            //    trigger (progress heartbeat or stream 404) retries'; an engine
            //    that re-emitted `.sessionMissing` here would turn a 10 s-paced
            //    retry into a tight renewal loop against a server that is
            //    already failing.
            //  * escalating (`DirectSessionRenewalError`, an unusable
            //    renewed stream URL, or the limit-th transient
            //    failure) — `failBackgroundRenewal` escalates at once, so the
            //    engine clears the in-flight flag, sets the counter to the
            //    limit, and re-emits this observation, which lands on the
            //    branch below.
            if context.backgroundRenewalTransientFailures >= backgroundRenewalTransientFailureLimit {
                context.backgroundRenewalTransientFailures = 0
                return renewSessionFresh(reason: "\(source.reason)_bg_renewal_failed", context: &context)
            }
            context.backgroundRenewalInFlight = true
            return (.renewSourceInBackground(reason: source.reason), context)
        }
        return renewSessionFresh(reason: source.reason, context: &context)
    }

    /// `attemptStaleSessionRenewal`. The `lastLoadRequest != nil`
    /// precondition is structural: a session can only go missing
    /// after a load started.
    private static func renewSessionFresh(
        reason: String,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // Single-flight.
        if context.freshRenewalInFlight { return (nil, context) }
        context.freshRenewalInFlight = true
        // A visible renewal supersedes any in-flight silent one.
        context.backgroundRenewalInFlight = false
        return (.renewSessionFresh(reason: reason), context)
    }

    // MARK: - Origin-outage ride-through

    private static func decideOriginOutage(
        active: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        if active {
            // A full visible recovery already owns this outage,
            // and a second `active` while riding is a no-op.
            guard context.serverOutageRecovery == nil, context.outage == nil else {
                return (nil, context)
            }
            context.outage = RecoveryContext.OutageState(
                rideThroughStart: now,
                nextProbeDelay: serverOutageRecoveryInitialDelay,
                noticeShown: false
            )
            // The loop probes *immediately* and only then sleeps
            // `delay` (primed at `serverOutageRecoveryInitialDelay`), so its
            // probes land at t = 0, 1, 3, 7, 15, 23, … Under this action's one
            // contract — "sleep `probeAfter`, then probe" — the entry probe is
            // `probeAfter: 0`; every later sleep comes back from
            // `decideServerHealthProbe`, which emits the delay in force at that
            // probe before doubling it.
            return (.rideThroughOutage(probeAfter: .zero), context)
        }
        // Exit — clear the state, then kick the item whose
        // segment fetches died during the outage. (The caller reads
        // `noticeShown` off the context it passed in to decide whether to show
        // "Reconnected", exactly as the retired ladder read it before
        // clearing.)
        guard context.outage != nil else { return (nil, context) }
        context.outage = nil
        return (.endOutageRideThrough, context)
    }

    // MARK: - Health probes (the ride-through loop and `waitForServerReady`)

    private static func decideServerHealthProbe(
        ok: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // The visible recovery supersedes the ride-through (it clears it when
        // it starts), so it owns the probe when both look present.
        if var wait = context.serverOutageRecovery {
            if ok {
                // The probe succeeded (or reached auth), so the
                // wait is over. Completing the reload is the engine's tail of
                // `.recoverFromServerOutage`, exactly as `waitForServerReady`'s
                // `true` return lands back inside `attemptServerOutageRecovery`.
                context.serverOutageRecovery = nil
                return (nil, context)
            }
            // Budget spent ⇒ terminal.
            let remaining = serverOutageRecoveryTimeout - now.timeIntervalSince(wait.waitStart)
            guard remaining > 0 else {
                context.serverOutageRecovery = nil
                return (.fail(.unknown(serverOutageTimeoutMessage)), context)
            }
            let sleepFor = min(wait.nextDelay, remaining)
            wait.nextDelay = min(wait.nextDelay * 2, serverOutageRecoveryMaxDelay)
            context.serverOutageRecovery = wait
            return (.waitForServerReady(probeAfter: .seconds(sleepFor)), context)
        }

        guard var outage = context.outage else { return (nil, context) }
        // The loop re-checks its 90 s deadline once per probe;
        // when it has expired the ride-through escalates to the visible
        // recovery. The legacy check is at the top of the loop body, i.e. at the
        // same clock instant as this one (a probe time) but just *before* the
        // probe rather than just after it — so the escalation happens at the
        // same instant, at the cost of one extra `/api/v1/health` GET on the
        // boundary iteration. (`ok: true` nudges `sourceProxy.reprobeOrigin()` —
        // the engine's job at probe time — and does not shorten the backoff: the
        // legacy loop doubles `delay` on every iteration regardless of the
        // result.)
        guard now.timeIntervalSince(outage.rideThroughStart) < serverOutageRecoveryTimeout else {
            context.outage = nil
            return beginServerOutageRecovery(
                reason: token(for: .networkUnavailable),
                context: &context,
                now: now
            )
        }
        // Sleep the delay in force at *this* probe, then double
        // it. With the entry action's `probeAfter: 0` the emitted sequence is
        // 0, 1, 2, 4, 8, 8, … — probes at t = 0, 1, 3, 7, 15, 23, ….
        let sleepFor = outage.nextProbeDelay
        outage.nextProbeDelay = min(outage.nextProbeDelay * 2, serverOutageRecoveryMaxDelay)
        context.outage = outage
        return (.rideThroughOutage(probeAfter: .seconds(sleepFor)), context)
    }

    // MARK: - Visible server-outage recovery

    private static func beginServerOutageRecovery(
        reason: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // `!hasReachedEndOfFile` is a load-state gate, not a recovery
        // decision — the same gate `decideEngineFailed`'s rung 1 delegates: after
        // end-of-file the load is terminal and the engine reports nothing into
        // recovery, so none of this function's three entries (the failure
        // ladder's premature-source-end rung, `.sourceInterrupted`, and the
        // ride-through's budget expiry) can reach it. `PlaybackState` carries
        // that `.ended` sub-state; a proxy interruption arriving after EOF must
        // be dropped there, not answered with `.recoverFromServerOutage`.
        //
        // Single-flight.
        guard context.serverOutageRecovery == nil else { return (nil, context) }
        context.serverOutageRecovery = RecoveryContext.ServerOutageRecoveryState(
            waitStart: now,
            nextDelay: serverOutageRecoveryInitialDelay
        )
        // Cancel any in-flight silent renewal (its retarget must
        // not land mid-teardown) and end the ride-through (its watchdog
        // suppression must not outlive the proxy).
        context.backgroundRenewalInFlight = false
        context.outage = nil
        return (.recoverFromServerOutage(reason: reason), context)
    }

    /// The token form of `PlaybackSourceInterruptionReason`. The visible
    /// recovery logs the reason and branches on `.sourceEntityChanged`, so the
    /// token has to keep that case distinguishable.
    static func token(for reason: PlaybackSourceInterruptionReason) -> String {
        switch reason {
        case let .serverUnavailable(statusCode):
            return "server_unavailable_\(statusCode)"
        case .networkUnavailable:
            return "network_unavailable"
        case let .prematureEOF(offset, expectedEnd):
            return "premature_eof_\(offset)_\(expectedEnd)"
        case .sourceEntityChanged:
            return "source_entity_changed"
        }
    }
}

private extension PlayheadSample.TimeControl {
    /// The tick's mapping onto the confirmation state's input.
    var transportState: LoopbackItemDeathConfirmationState.TransportState {
        switch self {
        case .paused: return .paused
        case .waiting: return .waiting
        case .playing: return .playing
        case .unknown: return .unknown
        }
    }
}
