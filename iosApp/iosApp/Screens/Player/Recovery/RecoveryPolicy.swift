//
//  RecoveryPolicy.swift
//
//  Stage 2 — ONE owner for every recovery ladder.
//
//  Before Stage 2 a recovery decision could be made in nine places: six
//  in-route ladders inside `AVPlayerBackend` (startup watchdog, playhead
//  watchdog, item-death evidence, edge watchdog, `.AVPlayerItemPlaybackStalled`,
//  "Playlist File unchanged"), and three inside `PlayerViewModel`
//  (`handlePlaybackError`, the origin-outage ride-through, the two session
//  renewals) — coordinated by a two-owner handshake (the retired recovery
//  suspension pair and the post-outage playback kick that went with them).
//  Every constant, every latch and every precedence rule from those nine sites
//  lives here now, unchanged.
//
//  `decide` is pure and total: no clock, no player, no I/O, one `switch` with
//  no `default`. `now` is a parameter so a test can drive a 90 s rolling window
//  in microseconds. It returns at most **one** action per observation — the
//  legacy ladders never take two steps for one signal, and the one place that
//  looks like it might (the playhead tick's `.reassertPlay`, which falls
//  through instead of returning) is proved below to be single-action.
//
//  Nothing consumes this yet. Wave 2 makes the engine session emit
//  `RecoveryObservation`s and execute `RecoveryAction`s; the backend's ladders
//  are deleted in the same wave.
//
//  Line anchors below (`B:` = `AVPlayerRoute/AVPlayerBackend.swift`, `PVM:` =
//  `PlayerViewModel.swift`) are from the Stage 2 wave-1 base.
//

import Foundation

enum RecoveryPolicy {

    // MARK: - Constants
    //
    // Each is the literal at the cited line, with the name it has today.

    /// B:440 `loopbackStartupWatchdogTickSeconds`.
    static let loopbackStartupWatchdogTickSeconds: TimeInterval = 1.0
    /// B:441 `loopbackStartupStallWindowSeconds`.
    static let loopbackStartupStallWindowSeconds: TimeInterval = 6.0
    /// B:442 `loopbackStartupAbsoluteBackstopSeconds`.
    static let loopbackStartupAbsoluteBackstopSeconds: TimeInterval = 60.0
    /// B:443 `seekCompletionDeadlineSeconds`.
    static let seekCompletionDeadlineSeconds: TimeInterval = 15.0
    /// B:428 `loopbackStartupForwardBuffer` — also the shared reanchor rung's
    /// pre-10 s `minimumGeneratedAhead` (B:3686).
    static let loopbackStartupForwardBuffer: Double = 4.0

    /// B:491 `playheadWatchdogTickSeconds`.
    static let playheadWatchdogTickSeconds: TimeInterval = 1.0
    /// B:492 `playheadWatchdogStallSeconds`.
    static let playheadWatchdogStallSeconds: Double = 10.0
    /// B:495 `playheadWatchdogMinGeneratedAhead`.
    static let playheadWatchdogMinGeneratedAhead: Double = 12.0
    /// B:496 `playheadWatchdogMaxReanchors`.
    static let playheadWatchdogMaxReanchors = 3
    /// B:497 `playheadWatchdogReanchorWindowSeconds`.
    static let playheadWatchdogReanchorWindowSeconds: Double = 90.0
    /// B:505 `playheadWatchdogStarvationEscalateSeconds`.
    static let playheadWatchdogStarvationEscalateSeconds: Double = 30.0
    /// B:506 `playheadWatchdogStarvationServeQuietSeconds`.
    static let playheadWatchdogStarvationServeQuietSeconds: Double = 15.0

    /// B:3677 — the shared reanchor rung's cooldown, a literal `10` today.
    static let reanchorCooldownSeconds: Double = 10.0
    /// B:3183 — the playhead tick's fetch-high-water bail, a literal `4.0`.
    static let fetchHighWaterSeconds: Double = 4.0

    /// PVM:954 `serverOutageRecoveryInitialDelay`.
    static let serverOutageRecoveryInitialDelay: TimeInterval = 1
    /// PVM:955 `serverOutageRecoveryMaxDelay`.
    static let serverOutageRecoveryMaxDelay: TimeInterval = 8
    /// PVM:956 `serverOutageRecoveryTimeout`.
    static let serverOutageRecoveryTimeout: TimeInterval = 90
    /// PVM:960 `nearEndPlaybackErrorThresholdSeconds`.
    static let nearEndPlaybackErrorThresholdSeconds: Double = 8
    /// PVM:964 `nearEndPlaybackErrorMaxBufferedAheadSeconds`.
    static let nearEndPlaybackErrorMaxBufferedAheadSeconds: Double = 1
    /// PVM:601 `backgroundRenewalTransientFailureLimit`.
    static let backgroundRenewalTransientFailureLimit = 3

    // Rung thresholds that are inline literals today and have no name yet.

    /// B:3028 — the playhead advance epsilon; movement in **either** direction
    /// counts as alive.
    static let playheadAdvanceEpsilon: Double = 0.05
    /// B:3097 — `mediaAvailableAhead` for the item-death confirmation state.
    static let itemDeathMediaAvailableBufferedAhead: Double = 0.5
    /// B:3097 — the generated half of the same predicate.
    static let itemDeathMediaAvailableGeneratedAhead: Double = 2.0
    /// B:3136 / B:3153 — the starvation rung's empty-buffer test and the wedge
    /// qualifier's "legitimately waiting" test.
    static let playheadBufferedAheadStarvationCeiling: Double = 2.0
    /// B:3681 — the shared reanchor rung's buffered-edge requirement.
    static let reanchorBufferedEdgeCeiling: Double = 0.5
    /// B:3686 — above this player time the rung wants a full steady-state
    /// runway instead of one fragment.
    static let reanchorSteadyStatePlayerSeconds: Double = 10
    /// B:3686 — the steady-state `minimumGeneratedAhead`.
    static let reanchorSteadyStateGeneratedAhead: Double = 10
    /// B:3224 / B:3229 — edge-watchdog advance epsilons.
    static let edgeAdvanceEpsilon: Double = 0.25
    /// B:3241 — the loaded runway that qualifies as "the edge is at the
    /// playhead".
    static let edgeLoadedAheadCeiling: Double = 1.0
    /// B:3242 — floor of the visible-runway requirement.
    static let edgeVisibleAheadFloor: Double = 6.0
    /// B:3236 — floor of `max(3.0, targetDuration * 2 + 1)`.
    static let edgeWatchdogDelayFloor: Double = 3.0
    /// B:3236 — the target-duration multiplier and addend of the same
    /// expression.
    static let edgeWatchdogDelayTargetMultiple: Double = 2.0
    static let edgeWatchdogDelayTargetAddend: Double = 1.0
    /// B:3235 — the target duration is floored before it is used.
    static let edgeTargetDurationFloor: Double = 1.0
    /// B:3711 — the auto-resume rung's buffered-runway alternative to
    /// `isPlaybackLikelyToKeepUp`.
    static let autoResumeBufferedAheadFloor: Double = 0.5

    /// PVM:4467 — the terminal message when the server never came back.
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
            // B:3435 — `recoverLocalLoopbackStallIfNeeded(item:)` with both
            // defaults.
            return reanchorIfNeeded(
                requireBufferedEdge: true,
                reason: "stall",
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

        case let .seekDeadlineExpired(kind):
            return decideSeekDeadlineExpired(kind: kind, context: &context)

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

        case let .bufferingChanged(buffering):
            // PVM:4371 `noteBufferingDuringSourceOutage` — the runway gate.
            // The notice itself is presentation; what the policy owns is the
            // once-per-outage latch, which is also what decides whether the
            // ride-through's exit shows "Reconnected" (PVM:4326 reads
            // `sourceOutageNoticeShown` *before* clearing the state, so the
            // caller reads it off the context it passed in).
            if buffering, var outage = context.outage, !outage.noticeShown {
                outage.noticeShown = true
                context.outage = outage
            }
            return (nil, context)
        }
    }

    // MARK: - S — startup ladder (B:3829 `loopbackStartupWatchdogTick`)

    private static func decideStartupTick(
        servedRequests: UInt64,
        displayModeSwitchInProgress: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3830-3836: the tick is loopback-only and pre-`didFireFileLoaded`.
        guard context.route == .siloPlayerLoopback,
              !context.playbackEstablished,
              var startup = context.startup else {
            return (nil, context)
        }

        // B:3844-3854: a served-request delta is forward progress, and an HDMI
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

        // B:3856 `secondsSinceStart: now.timeIntervalSince(startedAt)`. The
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
            // PINNED QUIRK (B:3866-3873, design §2.4): this arm does **not**
            // check suspension, unlike `escalateLoopbackStartupRecovery`
            // (B:3884). A backstop can therefore fire and report while a server
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

    /// B:3883 `escalateLoopbackStartupRecovery(trigger:)`. Also the direct
    /// entry from the item error log's `-15628` loader-poison signature
    /// (B:3498-3502), which arrives as `.itemDeathEvidence` before
    /// `playbackEstablished`.
    private static func escalateStartupRecovery(
        trigger: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3884: the ladder itself is muzzled while any owner holds the latch.
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
            // B:3897-3899: cancel the watchdog, then report.
            context.startup = nil
            return (.fail(.loopbackStartupStalled(trigger: trigger)), context)
        }
    }

    // MARK: - P — playhead watchdog (B:3010 `loopbackPlayheadWatchdogTick`)

    private static func decidePlayheadTick(
        sample: PlayheadSample,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3011-3019: loopback, established, finite position. (`!isDisposed`,
        // `currentItem` and `!isSeekPending` are the observation source's.)
        guard context.route == .siloPlayerLoopback,
              sample.playbackEstablished,
              sample.position.isFinite else {
            return (nil, context)
        }
        context.playhead.lastSample = sample
        context.playbackEstablished = sample.playbackEstablished
        context.userPaused = sample.userPaused

        // Rung 0 — advance tracking, B:3028-3032. Movement in EITHER direction
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

        // Rung 1 is telemetry only (B:3060) and stays at the observation source
        // (design §7 item 3).

        // Rung 2 — item-death confirmation, B:3089. Runs BEFORE the suspension
        // gate but takes suppression as an input, so it degrades to `.none`.
        //
        // The backend passes `isRecoverySuspended || isWaitingForInitialVideoDisplay`.
        // The second term is dead here: `isWaitingForInitialVideoDisplay` is
        // cleared at B:4136 immediately before `finishInitialLoadIfNeeded` sets
        // `didFireFileLoaded` (B:4241) on every one of that function's three
        // call sites (B:3807/4130 reach it only when the gate is already
        // clear), and the gate is re-armed only from `startPlaybackIfNeeded`
        // after a `load()` has reset `didFireFileLoaded` to false (B:1769). The
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
            // B:3106 issues `avPlayer.play()` and falls through. Returning here
            // is equivalent: `.reassertPlay` is only produced when
            // `transportState == .paused`, and every rung below is unreachable
            // in that state — the starvation rung requires `.waiting` (B:3135)
            // and the wedge qualifier requires `.playing` or `.waiting`
            // (B:3152-3153), so its `guard` returns.
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

        // Rung 3 — suspension gate, B:3128. Everything below is muzzled.
        guard !context.isRecoverySuspended else { return (nil, context) }

        // Rung 4 — producer-dead starvation, B:3134-3147.
        if !sample.userPaused,
           sample.timeControl == .waiting,
           sample.bufferedAhead < playheadBufferedAheadStarvationCeiling,
           stationaryFor >= playheadWatchdogStarvationEscalateSeconds,
           sample.secondsSinceLastServe >= playheadWatchdogStarvationServeQuietSeconds,
           !context.playhead.didEscalateStarvation {
            context.playhead.didEscalateStarvation = true
            return rebuildLocalSession(
                atPlayerSeconds: sample.position,
                reason: "loopback_starvation",
                context: &context,
                now: now
            )
        }

        // Rung 5 — wedge qualification, B:3152-3159.
        let believesPlayable = sample.timeControl == .playing
            || (sample.timeControl == .waiting
                && sample.bufferedAhead >= playheadBufferedAheadStarvationCeiling)
        guard !sample.userPaused,
              believesPlayable,
              stationaryFor >= playheadWatchdogStallSeconds,
              sample.generatedAhead >= playheadWatchdogMinGeneratedAhead else {
            return (nil, context)
        }

        // Rung 6 — rolling window reset, B:3164-3169.
        if context.playhead.windowStart.map({
            now.timeIntervalSince($0) > playheadWatchdogReanchorWindowSeconds
        }) ?? true {
            context.playhead.windowStart = now
            context.playhead.reanchorCount = 0
            context.playhead.didEscalateStarvation = false
        }

        // Rung 7 — exhaustion, B:3171-3179.
        if context.playhead.reanchorCount >= playheadWatchdogMaxReanchors {
            guard !context.playhead.didEscalateStarvation else { return (nil, context) }
            context.playhead.didEscalateStarvation = true
            return rebuildLocalSession(
                atPlayerSeconds: sample.position,
                reason: "playhead_watchdog",
                context: &context,
                now: now
            )
        }

        // Rung 8 — fetch-high-water bail, B:3181-3189. The consumer is filling
        // after a seek, not wedged. (`secondsSinceLastServe` is `.infinity`
        // when there is no store, matching the backend's optional chain, which
        // does not bail.)
        guard sample.secondsSinceLastServe >= fetchHighWaterSeconds else {
            return (nil, context)
        }

        // Rung 9 — reanchor attempt, B:3191-3199 → B:1917
        // `performVODStallRecovery(attempt:frozenPosition:)`.
        //
        // B:1918: `vodPendingSeekMediaTarget.map(playerTime(forMediaTime:)) ??
        // frozenPosition` — an unlanded seek target wins, because a wedged
        // zero-tolerance seek leaves the frozen clock at the PRE-seek position
        // (B:1160-1164) and anchoring there would discard the user's seek. The
        // latch is already media-timeline, which is the axis the action carries,
        // so it needs no conversion; the engine converts back with the exact
        // inverse the legacy sinks use.
        context.playhead.reanchorCount += 1
        let anchor = sample.pendingSeekMediaTarget
            ?? context.mediaSeconds(forPlayerSeconds: sample.position)
        if context.playhead.reanchorCount <= 1 {
            return (.reanchor(atMediaSeconds: anchor, reason: "vod_stall_nudge"), context)
        }
        return (.reloadItem(atMediaSeconds: anchor, reason: "vod_stall"), context)
    }

    // MARK: - D — item death (B:3569 `handleLoopbackItemDeathEvidence`)

    private static func decideItemDeathEvidence(
        statusCode: Int?,
        description: String,
        weight: Int,
        position: Double,
        userPaused: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3485-3489 / B:3539-3542: both evidence sources classify before reporting.
        guard LoopbackItemDeathRecoveryState.isItemDeath(
            statusCode: statusCode,
            errorDescription: description
        ) else {
            return (nil, context)
        }
        // B:3498-3502: `-15628` before the file-loaded edge is the loader-poison
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
        // B:3576-3579.
        guard context.route == .siloPlayerLoopback, !context.isRecoverySuspended else {
            return (nil, context)
        }
        let action = context.itemDeath.record(
            position: position,
            evidenceWeight: weight,
            userPaused: userPaused
        )
        // B:3494 / B:3549: the trigger names the evidence source.
        let trigger = statusCode == nil ? "failed_to_end" : "error_log"
        return performItemDeathAction(
            action,
            position: position,
            trigger: trigger,
            context: &context,
            now: now
        )
    }

    /// B:3596 `performLoopbackItemDeathRecoveryAction`.
    private static func performItemDeathAction(
        _ action: LoopbackItemDeathRecoveryState.Action,
        position: Double,
        trigger: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        switch action {
        case .waitForConfirmation:
            // B:3605 — log only.
            return (nil, context)
        case let .reload(attempt):
            context.itemDeathConfirmation.resetCandidate()
            return (
                .reloadItem(
                    atMediaSeconds: context.mediaSeconds(forPlayerSeconds: position),
                    reason: "item_death_\(trigger)_\(attempt)"
                ),
                context
            )
        case .escalate:
            context.itemDeathConfirmation.resetCandidate()
            return rebuildLocalSession(
                atPlayerSeconds: position,
                reason: "loopback_item_death",
                context: &context,
                now: now
            )
        }
    }

    // MARK: - E — edge watchdog (B:3201 `sampleLocalLoopbackEdge`)

    private static func decideEdgeSample(
        sample: EdgeSample,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3202-3209.
        guard context.route == .siloPlayerLoopback,
              context.playbackEstablished,
              !context.userPaused,
              sample.referenceTime.isFinite else {
            return (nil, context)
        }

        // B:3213-3220 — the first sample only seeds.
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

        // B:3235-3243.
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
            reason: "edge_watchdog",
            context: &context,
            now: now
        )
    }

    // MARK: - D — explicit item failure (B:3438 `itemFailedToEndObserver`)

    /// B:3453-3461: every `.AVPlayerItemFailedToPlayToEndTime` on an
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
        // B:3453-3454 — loopback only, and only after the file-loaded edge.
        // Anything else falls through to `recoverLocalLoopbackFailureIfNeeded`
        // (B:3536), whose only live tail arrives as `.playlistUnchanged`.
        guard context.route == .siloPlayerLoopback, context.playbackEstablished else {
            return (nil, context)
        }
        context.userPaused = userPaused
        // B:3455-3460. `noteExplicitFailure` clears the candidate itself when
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

    // MARK: - Y — "Playlist File unchanged" (B:3536 tail)

    /// B:3553-3566. Reached only for a failed-to-end notification that
    /// `decideItemFailedToEnd` did not consume — B:3453's early return means
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
            // B:3556-3565: latch the media time; `play()` (B:979-990) consumes it
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
            reason: "playlist_unchanged",
            context: &context,
            now: now
        )
    }

    // MARK: - Shared reanchor rung (B:3666 `recoverLocalLoopbackStallIfNeeded`)

    private static func reanchorIfNeeded(
        requireBufferedEdge: Bool,
        reason: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3671-3675.
        guard context.route == .siloPlayerLoopback,
              context.playbackEstablished,
              !context.userPaused,
              !context.isRecoverySuspended else {
            return (nil, context)
        }
        // B:3677 — the 10 s cooldown. `nil` is the backend's zero-initialised
        // `lastLocalLoopbackStallRecoveryAt`, which never blocks the first call.
        if let last = context.playhead.lastStallRecoveryAt,
           now.timeIntervalSince(last) < reanchorCooldownSeconds {
            return (nil, context)
        }
        guard let sample = context.playhead.lastSample, sample.position.isFinite else {
            return (nil, context)
        }
        // B:3681 — the buffered edge must sit at the playhead.
        guard !requireBufferedEdge || sample.bufferedAhead <= reanchorBufferedEdgeCeiling else {
            return (nil, context)
        }
        // B:3686-3688. The backend does not clamp `generatedAhead` here (the
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
                reason: reason
            ),
            context
        )
    }

    // MARK: - Auto-resume rung (B:3698 `resumeLocalLoopbackPlaybackIfNeeded`)

    private static func decideLikelyToKeepUp(
        rate: Double,
        bufferedAhead: Double,
        reachedEnd: Bool,
        likely: Bool,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3699-3707. `!hasReachedItemEnd` is review §3 #15: a buffer KVO
        // arriving after end-of-file must not restart transport behind the
        // hand-off.
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

    // MARK: - Seek deadlines (B:1262 `handleSeekDeadline`)

    private static func decideSeekDeadlineExpired(
        kind: SeekDeadlineKind,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        switch kind {
        case let .interactive(mediaTarget):
            // B:1290-1310. On loopback the latched seek target is the anchor,
            // and the recovery is `performVODStallRecovery(attempt: 1, …)` —
            // i.e. the same recipe `.reanchor(reason: "vod_stall_nudge")`
            // names. There is deliberately no cooldown and no suspension gate
            // on this path today.
            if context.route == .siloPlayerLoopback {
                return (
                    .reanchor(atMediaSeconds: mediaTarget, reason: "vod_stall_nudge"),
                    context
                )
            }
            guard !context.userPaused else { return (nil, context) }
            return (.resumePlayback, context)
        case .recovery:
            // B:1312-1320: the rung that issued the seek owns the next step;
            // stacking another recovery here would double-spend its budget.
            return (nil, context)
        case .initial:
            // B:1322-1335: the 8 × 200 ms retry is transport bookkeeping, not a
            // recovery decision, and design §7 item 5 replaces it with a
            // deadline-carrying `SeekRequest` in wave 3.
            return (nil, context)
        }
    }

    // MARK: - Rebuild (B:3635 `rebuildSiloLoopbackSession`)

    private static func rebuildLocalSession(
        atPlayerSeconds playerSeconds: Double,
        reason: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // B:3636-3638.
        guard context.route == .siloPlayerLoopback,
              playerSeconds.isFinite,
              !context.userPaused else {
            return (nil, context)
        }
        // B:3639-3648 — every rebuild resets the latches that decided to
        // rebuild, so without the budget the same wedge rebuilds forever.
        guard context.rebuildBudget.consume() else {
            return (
                .fail(.loopbackRebuildBudgetExhausted(
                    reason: reason,
                    rebuilds: context.rebuildBudget.used
                )),
                context
            )
        }
        // B:3649-3654.
        context.itemDeath.reset()
        context.itemDeathConfirmation.resetCandidate()
        context.playhead.reanchorCount = 0
        context.playhead.windowStart = now
        context.playhead.didEscalateStarvation = false
        return (
            .rebuildLocalSession(
                atMediaSeconds: context.mediaSeconds(forPlayerSeconds: playerSeconds),
                reason: reason
            ),
            context
        )
    }

    // MARK: - The view model's failure ladder (PVM:1537 `handlePlaybackError`)

    private static func decideEngineFailed(
        _ failure: PlaybackFailure,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // Rung 1 (PVM:1540, `hasReachedEndOfFile`) is a load-state gate, not a
        // recovery decision: after end-of-file the load is in its terminal
        // state and the engine does not report failures into recovery at all
        // (wave 1E's `PlaybackState` carries the `.ended` sub-state).

        // Rung 2 — PVM:1544: a visible outage recovery already owns the load.
        guard context.serverOutageRecovery == nil else { return (nil, context) }

        // Rung 3 — PVM:1548 `shouldTreatPlaybackErrorAsNaturalEnd`.
        if let nearEnd = context.nearEnd, shouldTreatAsNaturalEnd(nearEnd) {
            return (.treatAsNaturalEnd, context)
        }

        // Rung 4 — PVM:1553: while Protocol V3 is active the server owns
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

        // Rung 5 — PVM:1557: the server no longer knows this session.
        if failure.isPlaybackSessionMissing {
            return decideSessionMissing(source: .playerError, context: &context)
        }

        // Rung 6 — PVM:1565: ingest ended short of the known content.
        if failure.isPrematureSourceEnd {
            return beginServerOutageRecovery(
                reason: token(for: .networkUnavailable),
                context: &context,
                now: now
            )
        }

        // Rung 7 (PVM:1578, `progressTask?.cancel()`) is an effect, not a
        // decision — but it is NOT unconditional. It sits *below* the rungs
        // above, so it runs only when the ladder reaches rung 8 or lower: it is
        // part of executing `.autoRecoverInterruption`, `.switchRoute` and
        // `.fail`, and it must NOT be performed when this ladder returns
        // `.renewSourceInBackground`. A silent renewal that failed transiently
        // deliberately re-arms nothing (PVM:4186-4192, "so the next trigger
        // (progress heartbeat or stream 404) retries"), so cancelling the 10 s
        // progress loop here would kill the only thing that retries it. The
        // rungs above that do want the loop stopped stop it themselves inside
        // their own execution — PVM:1615 (replan), PVM:4259 (visible renewal)
        // and PVM:4426 (server-outage recovery).

        // Rung 8 — PVM:1579 `shouldAutoRecoverFromInterruption`.
        if context.canAutoRecoverInterruption {
            return (.autoRecoverInterruption, context)
        }

        // Rung 9 — PVM:1583 `attemptNativeDirectRouteRecovery` (PVM:2174).
        if context.route == .avPlayerNativeDirect, !context.attemptedNativeDirectFallback {
            if context.canBuildLoopbackFallback {
                context.attemptedNativeDirectFallback = true
                return (.switchRoute(.loopbackFallback), context)
            }
            // PVM:2192-2204: nothing local can remux this source, so the only
            // rung left is a server-produced HLS rendition — and the latch is
            // set only if that replan was actually accepted (PVM:2284 needs a
            // watch detail to replan against and no replan already running;
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

        // Rung 10 — PVM:1586 `attemptSiloRouteHLSFallback` (PVM:2258), which
        // also goes through `requestServerHLSRouteFallback`'s PVM:2284 guard.
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

        // PVM:1589 — terminal.
        return (.fail(failure), context)
    }

    /// PVM:1697 `shouldTreatPlaybackErrorAsNaturalEnd`, verbatim.
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

    // MARK: - Session renewal (PVM:4085 / PVM:4212)

    private static func decideSessionMissing(
        source: SessionMissingSource,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // PVM:1663-1670: three of the four sources try the silent renewal
        // first; the V3 replan's `catch` does not. It calls
        // `attemptStaleSessionRenewal` directly and deliberately: PVM:4165
        // states that once the server has re-planned "only a full visible
        // renewal can pick up the new plan", while the silent path keeps the
        // existing plan, session and backend alive and merely retargets the
        // proxy's origin (PVM:4138). The silent path's preconditions are all
        // satisfiable where this fires (a V3 session on `.direct` delivery with
        // a live proxy and a loaded watch detail), so without this
        // short-circuit the rung would divert a replan failure into a retarget
        // of the stale plan.
        if case .replanCatch = source {
            return renewSessionFresh(reason: source.reason, context: &context)
        }
        // PVM:4086-4092: a silent renewal only exists on a proxied direct
        // source that is online and has a watch detail loaded.
        if context.canRenewSourceInBackground {
            // PVM:4094-4097: single-flight — an in-flight renewal counts as
            // handled and takes no new action.
            if context.backgroundRenewalInFlight { return (nil, context) }
            // PVM:4177-4193 + PVM:4199 `failBackgroundRenewal`: once the
            // transient budget is spent, escalate to the visible renewal with
            // the `_bg_renewal_failed` suffix.
            //
            // How the engine reports a failed silent renewal matters, because
            // the two failure classes behave differently today:
            //  * transient (PVM:4176-4193, below the limit) — clear
            //    `backgroundRenewalInFlight`, increment
            //    `backgroundRenewalTransientFailures`, and do NOTHING else. The
            //    legacy `catch` deliberately re-arms nothing 'so the next
            //    trigger (progress heartbeat or stream 404) retries'; an engine
            //    that re-emitted `.sessionMissing` here would turn a 10 s-paced
            //    retry into a tight renewal loop against a server that is
            //    already failing.
            //  * escalating (PVM:4165 `DirectSessionRenewalError`, PVM:4134 an
            //    unusable renewed stream URL, or the limit-th transient
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

    /// PVM:4212 `attemptStaleSessionRenewal`. The `lastLoadRequest != nil`
    /// precondition (PVM:4214) is structural: a session can only go missing
    /// after a load started.
    private static func renewSessionFresh(
        reason: String,
        context: inout RecoveryContext
    ) -> (RecoveryAction?, RecoveryContext) {
        // PVM:4219-4223: single-flight.
        if context.freshRenewalInFlight { return (nil, context) }
        context.freshRenewalInFlight = true
        // PVM:4225-4227: a visible renewal supersedes any in-flight silent one.
        context.backgroundRenewalInFlight = false
        return (.renewSessionFresh(reason: reason), context)
    }

    // MARK: - Origin-outage ride-through (PVM:4280 `handleOriginOutageChanged`)

    private static func decideOriginOutage(
        active: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        if active {
            // PVM:4284-4285: a full visible recovery already owns this outage,
            // and a second `active` while riding is a no-op.
            guard context.serverOutageRecovery == nil, context.outage == nil else {
                return (nil, context)
            }
            context.outage = RecoveryContext.OutageState(
                rideThroughStart: now,
                nextProbeDelay: serverOutageRecoveryInitialDelay,
                noticeShown: false
            )
            // PVM:4299-4310: the loop probes *immediately* and only then sleeps
            // `delay` (primed at `serverOutageRecoveryInitialDelay`), so its
            // probes land at t = 0, 1, 3, 7, 15, 23, … Under this action's one
            // contract — "sleep `probeAfter`, then probe" — the entry probe is
            // `probeAfter: 0`; every later sleep comes back from
            // `decideServerHealthProbe`, which emits the delay in force at that
            // probe before doubling it.
            return (.rideThroughOutage(probeAfter: .zero), context)
        }
        // PVM:4323-4331: exit — clear the state, then kick the item whose
        // segment fetches died during the outage. (The caller reads
        // `noticeShown` off the context it passed in to decide whether to show
        // "Reconnected", exactly as PVM:4326 reads it before clearing.)
        guard context.outage != nil else { return (nil, context) }
        context.outage = nil
        return (.endOutageRideThrough(kick: true), context)
    }

    // MARK: - Health probes (PVM:4300 loop / PVM:4494 `waitForServerReady`)

    private static func decideServerHealthProbe(
        ok: Bool,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // The visible recovery supersedes the ride-through (it clears it when
        // it starts, PVM:4410), so it owns the probe when both look present.
        if var wait = context.serverOutageRecovery {
            if ok {
                // PVM:4504-4513: the probe succeeded (or reached auth), so the
                // wait is over. Completing the reload is the engine's tail of
                // `.recoverFromServerOutage`, exactly as `waitForServerReady`'s
                // `true` return lands back inside `attemptServerOutageRecovery`.
                context.serverOutageRecovery = nil
                return (nil, context)
            }
            // PVM:4520-4521: budget spent ⇒ terminal.
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
        // PVM:4301-4304: the loop re-checks its 90 s deadline once per probe;
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
        // PVM:4308-4310: sleep the delay in force at *this* probe, then double
        // it. With the entry action's `probeAfter: 0` the emitted sequence is
        // 0, 1, 2, 4, 8, 8, … — probes at t = 0, 1, 3, 7, 15, 23, ….
        let sleepFor = outage.nextProbeDelay
        outage.nextProbeDelay = min(outage.nextProbeDelay * 2, serverOutageRecoveryMaxDelay)
        context.outage = outage
        return (.rideThroughOutage(probeAfter: .seconds(sleepFor)), context)
    }

    // MARK: - Visible server-outage recovery (PVM:4385)

    private static func beginServerOutageRecovery(
        reason: String,
        context: inout RecoveryContext,
        now: Date
    ) -> (RecoveryAction?, RecoveryContext) {
        // PVM:4390 `!hasReachedEndOfFile` is a load-state gate, not a recovery
        // decision — the same gate `decideEngineFailed`'s rung 1 delegates: after
        // end-of-file the load is terminal and the engine reports nothing into
        // recovery, so none of this function's three entries (the failure
        // ladder's premature-source-end rung, `.sourceInterrupted`, and the
        // ride-through's budget expiry) can reach it. Wave 1E's `PlaybackState`
        // carries that `.ended` sub-state; a proxy interruption arriving after
        // EOF must be dropped there, not answered with
        // `.recoverFromServerOutage`.
        //
        // PVM:4396-4398: single-flight.
        guard context.serverOutageRecovery == nil else { return (nil, context) }
        context.serverOutageRecovery = RecoveryContext.ServerOutageRecoveryState(
            waitStart: now,
            nextDelay: serverOutageRecoveryInitialDelay
        )
        // PVM:4406-4409: cancel any in-flight silent renewal (its retarget must
        // not land mid-teardown) and end the ride-through (its watchdog
        // suppression must not outlive the proxy).
        context.backgroundRenewalInFlight = false
        context.outage = nil
        return (.recoverFromServerOutage(reason: reason), context)
    }

    /// The token form of `PlaybackSourceInterruptionReason`. `PVM:4423` logs the
    /// reason and `PVM:4428` branches on `.sourceEntityChanged`, so the token
    /// has to keep that case distinguishable.
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
    /// B:3041-3056 — the tick's mapping onto the confirmation state's input.
    var transportState: LoopbackItemDeathConfirmationState.TransportState {
        switch self {
        case .paused: return .paused
        case .waiting: return .waiting
        case .playing: return .playing
        case .unknown: return .unknown
        }
    }
}
