import XCTest
@testable import Silo

/// Table tests for `RecoveryPolicy` — the single owner of every recovery
/// ladder after Stage 2.
///
/// One test per rung, driving the pure `decide` with an explicit clock so the
/// 90 s rolling window, the 10 s cooldown and the 1→8 s backoffs run in
/// microseconds. Each test names the legacy site it pins (`B:` =
/// `AVPlayerRoute/AVPlayerBackend.swift`, `PVM:` = `PlayerViewModel.swift`).
///
/// Where a rung is arithmetic the expected value comes from an in-test
/// **oracle** — a small copy of the legacy expression — following the R2
/// `PlayerErrorClassificationMatrixTests` pattern, so a constant that drifts
/// fails here instead of quietly changing behaviour.
final class RecoveryPolicyTests: XCTestCase {

    // MARK: - Oracles (verbatim copies of the legacy expressions)

    /// PVM:1697 `PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd`.
    private func oracleTreatAsNaturalEnd(
        duration: Double,
        currentTime: Double,
        bufferedAheadSeconds: Double,
        isSourceOutageActive: Bool
    ) -> Bool {
        guard duration.isFinite, duration > 0, currentTime.isFinite, currentTime > 0 else {
            return false
        }
        guard !isSourceOutageActive else { return false }
        if bufferedAheadSeconds.isFinite, bufferedAheadSeconds > 1 {
            return false
        }
        return duration - currentTime <= 8
    }

    /// B:3236 `watchdogDelay`.
    private func oracleEdgeWatchdogDelay(targetDuration: Double) -> Double {
        max(3.0, max(1.0, targetDuration) * 2.0 + 1.0)
    }

    /// B:3241 — the visible-runway requirement.
    private func oracleEdgeVisibleAheadFloor(
        targetDuration: Double,
        longestSegment: Double
    ) -> Double {
        max(6.0, max(1.0, targetDuration) + longestSegment)
    }

    /// B:3686 `minimumGeneratedAhead`.
    private func oracleMinimumGeneratedAhead(playerSeconds: Double) -> Double {
        playerSeconds < 10 ? 4.0 : 10
    }

    /// PVM:4310 / PVM:4523 — the shared health-probe backoff.
    private func oracleNextBackoff(_ delay: TimeInterval) -> TimeInterval {
        min(delay * 2, 8)
    }

    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private func sample(
        position: Double = 100,
        timeControl: PlayheadSample.TimeControl = .playing,
        bufferedAhead: Double = 5,
        generatedAhead: Double = 20,
        secondsSinceLastServe: Double = 5,
        userPaused: Bool = false,
        playbackEstablished: Bool = true,
        pendingSeekMediaTarget: Double? = nil
    ) -> PlayheadSample {
        PlayheadSample(
            position: position,
            timeControl: timeControl,
            bufferedAhead: bufferedAhead,
            generatedAhead: generatedAhead,
            secondsSinceLastServe: secondsSinceLastServe,
            userPaused: userPaused,
            playbackEstablished: playbackEstablished,
            pendingSeekMediaTarget: pendingSeekMediaTarget
        )
    }

    /// An established loopback load with a live playhead sample, which is what
    /// the notification-driven rungs (shared reanchor, auto-resume) read.
    private func loopbackContext(
        suspendedReasons: Set<String> = [],
        userPaused: Bool = false,
        mediaTimelineOffset: Double = 0,
        lastSample: PlayheadSample? = nil
    ) -> RecoveryContext {
        var context = RecoveryContext.initial(route: .siloPlayerLoopback)
        context.playbackEstablished = true
        context.userPaused = userPaused
        context.suspendedReasons = suspendedReasons
        context.mediaTimelineOffset = mediaTimelineOffset
        context.playhead.lastSample = lastSample
        return context
    }

    private func startupContext(
        stage: RecoveryContext.StartupState.Stage = .initial,
        suspendedReasons: Set<String> = []
    ) -> RecoveryContext {
        var context = RecoveryContext.initial(route: .siloPlayerLoopback)
        context.playbackEstablished = false
        context.suspendedReasons = suspendedReasons
        context.startup = RecoveryContext.StartupState(
            stage: stage,
            startedAt: t0,
            lastProgressAt: t0,
            lastRequestCount: 0
        )
        return context
    }

    /// Drives the wedge rung to its Nth reanchor, returning the context after
    /// the run. Ticks are 10 s apart with a stationary playhead, which is
    /// exactly what B:3151-3159 qualifies as a wedge.
    private func driveWedge(
        attempts: Int,
        context: RecoveryContext,
        firstTickAt offset: TimeInterval = 0
    ) -> (actions: [RecoveryAction?], context: RecoveryContext) {
        var context = context
        var actions: [RecoveryAction?] = []
        // Seed the stationary clock.
        (_, context) = RecoveryPolicy.decide(
            .playheadTick(sample()),
            context: context,
            now: at(offset)
        )
        for attempt in 1...attempts {
            let action: RecoveryAction?
            (action, context) = RecoveryPolicy.decide(
                .playheadTick(sample()),
                context: context,
                now: at(offset + Double(attempt) * 10)
            )
            actions.append(action)
        }
        return (actions, context)
    }

    // MARK: - S — startup ladder (B:3828)

    func testStartup_StallWindow_WaitsWhileFetchesAdvance() {
        var context = startupContext()
        var action: RecoveryAction?
        // A served-request delta rebases the progress clock every tick, so the
        // ladder holds no matter how long startup takes (B:3844-3847).
        for tick in 1...30 {
            (action, context) = RecoveryPolicy.decide(
                .startupTick(
                    servedRequests: UInt64(tick),
                    displayModeSwitchInProgress: false
                ),
                context: context,
                now: at(Double(tick))
            )
            XCTAssertNil(action)
        }
        XCTAssertEqual(context.startup?.stage, .initial)
    }

    func testStartup_StallWindow_EscalatesToNudge() {
        var context = startupContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false),
            context: context,
            now: at(5.9)
        )
        XCTAssertNil(action, "5.9 s is inside the 6 s stall window")

        (action, context) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false),
            context: context,
            now: at(6)
        )
        XCTAssertEqual(action, .nudgeStartup)
        XCTAssertEqual(context.startup?.stage, .nudged)
        XCTAssertEqual(context.startup?.lastProgressAt, at(6), "the nudge rebases the progress clock")
    }

    func testStartup_Nudged_EscalatesToItemReload() {
        var context = startupContext(stage: .nudged)
        let (action, next) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false),
            context: context,
            now: at(12)
        )
        XCTAssertEqual(action, .reloadStartupItem)
        XCTAssertEqual(next.startup?.stage, .reloaded)
        context = next
        XCTAssertNotNil(context.startup)
    }

    func testStartup_Reloaded_FailsWithStartupStalled() {
        let context = startupContext(stage: .reloaded)
        let (action, next) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false),
            context: context,
            now: at(18)
        )
        XCTAssertEqual(action, .fail(.loopbackStartupStalled(trigger: "fetches_frozen")))
        XCTAssertNil(next.startup, "the watchdog is cancelled when the ladder gives up")
    }

    func testStartup_Escalation_IsMuzzledWhileSuspended() {
        // B:3884 — the ladder itself checks suspension.
        let context = startupContext(suspendedReasons: ["server_replan"])
        let (action, next) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false),
            context: context,
            now: at(30)
        )
        XCTAssertNil(action)
        XCTAssertEqual(next.startup?.stage, .initial, "a muzzled escalation does not advance the ladder")
    }

    func testStartup_Backstop_FiresEvenWhileSuspended() {
        // PINNED QUIRK (design §2.4): unlike `escalateLoopbackStartupRecovery`,
        // the tick's `failBackstop` arm (B:3866) does NOT check suspension, so
        // it can report during a server replan or an origin-outage
        // ride-through. Kept deliberately.
        let context = startupContext(suspendedReasons: ["server_replan", "origin_outage"])
        let (action, next) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 7, displayModeSwitchInProgress: false),
            context: context,
            now: at(60)
        )
        XCTAssertEqual(
            action,
            .fail(.loopbackStartupBackstop(seconds: 60, requestsServed: 7, stage: "initial"))
        )
        XCTAssertNil(next.startup)
    }

    func testStartup_Backstop_ReportsTheCurrentStage() {
        // The stage string is `"\(loopbackStartupRecoveryStage)"` (B:3871), so
        // it must keep spelling the case names.
        for (stage, spelling) in [
            (RecoveryContext.StartupState.Stage.initial, "initial"),
            (.nudged, "nudged"),
            (.reloaded, "reloaded")
        ] {
            let (action, _) = RecoveryPolicy.decide(
                .startupTick(servedRequests: 3, displayModeSwitchInProgress: false),
                context: startupContext(stage: stage),
                now: at(120)
            )
            XCTAssertEqual(
                action,
                .fail(.loopbackStartupBackstop(seconds: 60, requestsServed: 3, stage: spelling))
            )
        }
    }

    func testStartup_DisplayModeSwitch_HoldsTheLadder() {
        // B:3844-3854 — an HDMI mode switch rebases the progress clock, and the
        // shared policy also returns `.wait` outright.
        let context = startupContext()
        let (action, next) = RecoveryPolicy.decide(
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: true),
            context: context,
            now: at(30)
        )
        XCTAssertNil(action)
        XCTAssertEqual(next.startup?.lastProgressAt, at(30))
    }

    func testStartup_ErrorLogPoison_EntersTheLadderBeforeFileLoaded() {
        // B:3498-3502 — `-15628` before the file-loaded edge is CoreMedia's
        // loader-poison signature and drives the startup ladder directly.
        var context = startupContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -15628,
                description: "loader poisoned",
                weight: 2,
                position: 0,
                userPaused: false
            ),
            context: context,
            now: at(2)
        )
        XCTAssertEqual(action, .nudgeStartup)

        // A different item-death code before the edge does nothing: the
        // errorLog observer's second branch is `-15628` only.
        (action, _) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -12889,
                description: "No response for media file",
                weight: 1,
                position: 0,
                userPaused: false
            ),
            context: context,
            now: at(3)
        )
        XCTAssertNil(action)
    }

    // MARK: - P — playhead watchdog (B:3010)

    func testPlayhead_ItemDeathConfirmation_ReassertsPlayOnUnexpectedPause() {
        // B:3089-3106 — AVPlayer parked at `.paused` with media available and
        // no user pause is a candidate, not an intentional stop.
        let context = loopbackContext()
        let (action, next) = RecoveryPolicy.decide(
            .playheadTick(sample(timeControl: .paused, bufferedAhead: 1.0, generatedAhead: 20)),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reassertPlay)
        XCTAssertNotEqual(next, context, "the candidate is latched for the 3 s confirmation")
    }

    func testPlayhead_ItemDeathConfirmation_ConfirmedPauseReloadsTheItem() {
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(timeControl: .paused, bufferedAhead: 1.0)),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reassertPlay)

        // B:145 `confirmationSeconds = 3.0`: still parked at the same position.
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(timeControl: .paused, bufferedAhead: 1.0)),
            context: context,
            now: at(3)
        )
        XCTAssertEqual(
            action,
            .reloadItem(atMediaSeconds: 100, reason: "item_death_unexpected_pause_1")
        )
    }

    func testPlayhead_ItemDeathConfirmation_CancelsOnProgress() {
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(timeControl: .paused, bufferedAhead: 1.0)),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reassertPlay)
        // B:146 `progressCancellationThresholdSeconds = 0.5` — the playhead
        // moved, so the candidate is abandoned.
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 101, timeControl: .paused, bufferedAhead: 1.0)),
            context: context,
            now: at(3)
        )
        XCTAssertNil(action)
    }

    func testPlayhead_Suppression_ReturnsNoActionBelowTheGate() {
        // B:3131 — everything below the gate is muzzled, and the confirmation
        // state degrades to `.none` because it takes suppression as an input.
        let context = loopbackContext(suspendedReasons: ["origin_outage"])
        let wedged = sample(timeControl: .playing, bufferedAhead: 5, generatedAhead: 40)
        var next = context
        var action: RecoveryAction?
        (action, next) = RecoveryPolicy.decide(.playheadTick(wedged), context: next, now: t0)
        XCTAssertNil(action)
        (action, next) = RecoveryPolicy.decide(.playheadTick(wedged), context: next, now: at(30))
        XCTAssertNil(action)
        XCTAssertEqual(next.playhead.reanchorCount, 0)
    }

    /// B:3134-3147 — waiting on an empty buffer for 30 s with no segment serve
    /// for 15 s is a producer-dead stall, not a wedge.
    private var starvedSample: PlayheadSample {
        sample(
            timeControl: .waiting,
            bufferedAhead: 0.1,
            generatedAhead: 0,
            secondsSinceLastServe: 20
        )
    }

    func testPlayhead_Starvation_RebuildsAtTheEscalationWindow() {
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: t0
        )
        XCTAssertNil(action)

        (action, context) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: at(29.9)
        )
        XCTAssertNil(action, "29.9 s is inside the 30 s escalation window")

        (action, context) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: at(30)
        )
        XCTAssertEqual(
            action,
            .rebuildLocalSession(atMediaSeconds: 100, reason: "loopback_starvation")
        )
        XCTAssertEqual(context.rebuildBudget.used, 1)
        // B:3653 — the rebuild resets the very latch that decided to rebuild,
        // which is why the rebuild *budget*, not the latch, is the outer bound.
        XCTAssertFalse(context.playhead.didEscalateStarvation)
    }

    func testPlayhead_Starvation_LatchHoldsOnceTheBudgetIsSpent() {
        // B:3639-3648 — when `consume()` fails the ladder reports and returns
        // *before* the resets, so the latch stays set and the rung goes quiet.
        var context = loopbackContext()
        var action: RecoveryAction?
        (_, context) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: t0
        )
        for elapsed in stride(from: 30.0, through: 90.0, by: 30.0) {
            (action, context) = RecoveryPolicy.decide(
                .playheadTick(starvedSample),
                context: context,
                now: at(elapsed)
            )
        }
        XCTAssertEqual(
            action,
            .fail(.loopbackRebuildBudgetExhausted(reason: "loopback_starvation", rebuilds: 2))
        )
        XCTAssertTrue(context.playhead.didEscalateStarvation)

        (action, _) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: at(120)
        )
        XCTAssertNil(action, "the ladder does not keep reporting the same exhausted budget")
    }

    func testPlayhead_Starvation_HoldsWhileSegmentsAreStillServed() {
        // B:3139-3140 — the serve-quiet guard keeps ordinary slow-WAN rebuffers from
        // tripping the rung.
        let rebuffering = sample(
            timeControl: .waiting,
            bufferedAhead: 0.1,
            generatedAhead: 0,
            secondsSinceLastServe: 14.9
        )
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(rebuffering),
            context: context,
            now: t0
        )
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(rebuffering),
            context: context,
            now: at(45)
        )
        XCTAssertNil(action)
    }

    func testPlayhead_Wedge_DoesNotQualifyWithoutGeneratedMedia() {
        // B:3158 — `playheadWatchdogMinGeneratedAhead = 12`.
        var context = loopbackContext()
        let thin = sample(generatedAhead: 11.9)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(.playheadTick(thin), context: context, now: t0)
        (action, _) = RecoveryPolicy.decide(.playheadTick(thin), context: context, now: at(20))
        XCTAssertNil(action)
    }

    func testPlayhead_Wedge_DoesNotQualifyBeforeTheStallWindow() {
        // B:3157 — `playheadWatchdogStallSeconds = 10`.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(.playheadTick(sample()), context: context, now: t0)
        (action, _) = RecoveryPolicy.decide(.playheadTick(sample()), context: context, now: at(9.9))
        XCTAssertNil(action)
    }

    func testPlayhead_Wedge_ReanchorsOnTheFirstAttempt() {
        // B:3191-3199 → B:1917 `performVODStallRecovery(attempt: 1, …)`.
        let (actions, context) = driveWedge(attempts: 1, context: loopbackContext())
        XCTAssertEqual(actions, [.reanchor(atMediaSeconds: 100, reason: "vod_stall_nudge")])
        XCTAssertEqual(context.playhead.reanchorCount, 1)
    }

    func testPlayhead_Wedge_ReloadsTheItemOnLaterAttempts() {
        // B:1934 — attempt > 1 reloads the established item in place.
        let (actions, _) = driveWedge(attempts: 3, context: loopbackContext())
        XCTAssertEqual(
            actions,
            [
                .reanchor(atMediaSeconds: 100, reason: "vod_stall_nudge"),
                .reloadItem(atMediaSeconds: 100, reason: "vod_stall"),
                .reloadItem(atMediaSeconds: 100, reason: "vod_stall")
            ]
        )
    }

    func testPlayhead_Wedge_AnchorsOnTheMediaTimeline() {
        // B:3649/B:3689 — the sinks reanchor at `mediaTime(for: playerSeconds)`.
        let (actions, _) = driveWedge(
            attempts: 1,
            context: loopbackContext(mediaTimelineOffset: 640)
        )
        XCTAssertEqual(actions, [.reanchor(atMediaSeconds: 740, reason: "vod_stall_nudge")])
    }

    func testPlayhead_Wedge_PrefersTheUnlandedSeekTarget() {
        // B:1918 — a wedged zero-tolerance seek leaves the frozen clock at the
        // PRE-seek position (B:1160-1164), so the latched media target is the
        // anchor and the user's seek is not discarded. Reachable between
        // `handleSeekDeadline`'s `markSeekSettled()` (B:1268) and the `Task`
        // that consumes the latch (B:1297-1304).
        var context = loopbackContext(mediaTimelineOffset: 640)
        let wedged = sample(pendingSeekMediaTarget: 1_500)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(.playheadTick(wedged), context: context, now: t0)
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(wedged),
            context: context,
            now: at(10)
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 1_500, reason: "vod_stall_nudge"))

        // Later attempts reload the item at the same anchor.
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(wedged),
            context: context,
            now: at(20)
        )
        XCTAssertEqual(action, .reloadItem(atMediaSeconds: 1_500, reason: "vod_stall"))
    }

    func testPlayhead_Exhaustion_RebuildsAfterThreeReanchors() {
        // B:3171-3179 — `playheadWatchdogMaxReanchors = 3`.
        var (actions, context) = driveWedge(attempts: 3, context: loopbackContext())
        XCTAssertEqual(context.playhead.reanchorCount, 3)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample()),
            context: context,
            now: at(40)
        )
        actions.append(action)
        XCTAssertEqual(
            action,
            .rebuildLocalSession(atMediaSeconds: 100, reason: "playhead_watchdog")
        )
        XCTAssertEqual(context.playhead.reanchorCount, 0, "a rebuild resets the reanchor budget")
        XCTAssertFalse(context.playhead.didEscalateStarvation, "and clears the escalation latch")
        XCTAssertEqual(context.rebuildBudget.used, 1)
    }

    func testPlayhead_RebuildBudget_FailsAfterTwoRebuilds() {
        // B:3639-3648 + B:41 `maximumRebuildsPerLoad = 2`. Each rebuild clears
        // `didEscalateStarvation`, so the same wedge re-qualifies every 30 s
        // and the budget is what finally stops it.
        var context = loopbackContext()
        var actions: [RecoveryAction?] = []
        var action: RecoveryAction?
        (_, context) = RecoveryPolicy.decide(
            .playheadTick(starvedSample),
            context: context,
            now: t0
        )
        for elapsed in stride(from: 30.0, through: 90.0, by: 30.0) {
            (action, context) = RecoveryPolicy.decide(
                .playheadTick(starvedSample),
                context: context,
                now: at(elapsed)
            )
            actions.append(action)
        }
        XCTAssertEqual(
            actions,
            [
                .rebuildLocalSession(atMediaSeconds: 100, reason: "loopback_starvation"),
                .rebuildLocalSession(atMediaSeconds: 100, reason: "loopback_starvation"),
                .fail(.loopbackRebuildBudgetExhausted(reason: "loopback_starvation", rebuilds: 2))
            ]
        )
        XCTAssertEqual(context.rebuildBudget.used, 2)
    }

    func testPlayhead_FetchHighWater_BailsWhileSegmentsFlow() {
        // B:3181-3189 — a post-seek buffer fill, not a wedge (living-room bug 3).
        var context = loopbackContext()
        let filling = sample(secondsSinceLastServe: 3.9)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(.playheadTick(filling), context: context, now: t0)
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(filling),
            context: context,
            now: at(20)
        )
        XCTAssertNil(action)
        XCTAssertEqual(context.playhead.reanchorCount, 0)
        // The window still opened — the bail is below the reset (B:3164).
        XCTAssertEqual(context.playhead.windowStart, at(20))
    }

    func testPlayhead_Window_ResetsAfterNinetySeconds() {
        // B:3164-3169 — `playheadWatchdogReanchorWindowSeconds = 90`.
        var (_, context) = driveWedge(attempts: 3, context: loopbackContext())
        XCTAssertEqual(context.playhead.reanchorCount, 3)
        var action: RecoveryAction?
        // 91 s after the window opened at t0+10, the budget refreshes and the
        // rung reanchors again instead of rebuilding.
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample()),
            context: context,
            now: at(101.5)
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 100, reason: "vod_stall_nudge"))
        XCTAssertEqual(context.playhead.reanchorCount, 1)
        XCTAssertEqual(context.rebuildBudget.used, 0)
    }

    func testPlayhead_Advance_ClearsTheStationaryClockInEitherDirection() {
        // B:3028-3032 — a backward in-item seek is movement too, otherwise the
        // high-water mark goes stale and a healthy route reads as wedged.
        var context = loopbackContext()
        var action: RecoveryAction?
        (_, context) = RecoveryPolicy.decide(.playheadTick(sample()), context: context, now: t0)
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 40)),
            context: context,
            now: at(20)
        )
        XCTAssertNil(action, "the backward jump restarts the stationary clock")
        XCTAssertEqual(context.playhead.stationarySince, at(20))

        // A sub-epsilon jitter is not movement (B:3028, 0.05).
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 40.04)),
            context: context,
            now: at(30)
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 40.04, reason: "vod_stall_nudge"))
        XCTAssertEqual(context.playhead.stationarySince, at(20))
    }

    // MARK: - D — item death (B:3569)

    func testItemDeath_Evidence_NeedsWeightTwoBeforeReloading() {
        // B:68 `evidenceRequired = 2`.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -12889,
                description: "No response for media file",
                weight: 1,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: t0
        )
        XCTAssertNil(action)

        (action, context) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -12889,
                description: "No response for media file",
                weight: 1,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: at(1)
        )
        XCTAssertEqual(
            action,
            .reloadItem(atMediaSeconds: 100, reason: "item_death_error_log_1")
        )
    }

    func testItemDeath_Evidence_WeightTwoConfirmsImmediately() {
        // B:3493 — `-15628` carries weight 2, so one entry is enough.
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -15628,
                description: "-15628",
                weight: 2,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reloadItem(atMediaSeconds: 100, reason: "item_death_error_log_1"))
    }

    func testItemDeath_Evidence_PositionDriftResetsTheEvidence() {
        // B:67 `matchingPositionToleranceSeconds = 2.0`.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -12889,
                description: "x",
                weight: 1,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        (action, context) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -12889,
                description: "x",
                weight: 1,
                position: 110,
                userPaused: false
            ),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action, "the playhead moved, so the accumulated evidence is stale")
    }

    func testItemDeath_Evidence_SecondConfirmationEscalatesToRebuild() {
        // B:69 `maximumReloads = 1` → the second confirmation rebuilds.
        var context = loopbackContext()
        var action: RecoveryAction?
        for tick in 0..<2 {
            (action, context) = RecoveryPolicy.decide(
                .itemDeathEvidence(
                    statusCode: -15628,
                    description: "-15628",
                    weight: 2,
                    position: 100,
                    userPaused: false
                ),
                context: context,
                now: at(Double(tick))
            )
        }
        XCTAssertEqual(
            action,
            .rebuildLocalSession(atMediaSeconds: 100, reason: "loopback_item_death")
        )
        XCTAssertEqual(context.rebuildBudget.used, 1)
    }

    func testItemDeath_Evidence_WaitsWhileTheUserIsPaused() {
        // B:87 — a user pause always defers to the confirmation state.
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -15628,
                description: "-15628",
                weight: 2,
                position: 100,
                userPaused: true
            ),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
    }

    func testItemDeath_Evidence_IsMuzzledWhileSuspended() {
        // B:3579 — the evidence entry point checks suspension.
        let context = loopbackContext(suspendedReasons: ["server_replan"])
        let (action, next) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -15628,
                description: "-15628",
                weight: 2,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        XCTAssertEqual(next, context, "no evidence is accumulated either")
    }

    func testItemDeath_Evidence_IgnoresNonItemDeathSignatures() {
        // B:75 `isItemDeath` — only the four signatures count.
        let context = loopbackContext()
        let (action, next) = RecoveryPolicy.decide(
            .itemDeathEvidence(
                statusCode: -11800,
                description: "The operation could not be completed",
                weight: 2,
                position: 100,
                userPaused: false
            ),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        XCTAssertEqual(next, context)
    }

    // MARK: - D — explicit failed-to-end (B:3438)

    func testItemDeath_FailedToEnd_ConfirmsAfterTheWindowAndReloadsTheItem() {
        // B:3453-3461 arms the confirmation candidate and returns; B:3089 +
        // B:145 confirm it 3 s later while the playhead has not moved.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemFailedToEnd(position: 100, userPaused: false),
            context: context,
            now: t0
        )
        XCTAssertNil(action, "the notification only arms a candidate")

        // Inside the window nothing confirms yet.
        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 100, timeControl: .waiting, bufferedAhead: 0.1)),
            context: context,
            now: at(2.9)
        )
        XCTAssertNil(action)

        // A dead item parked in `.waitingToPlayAtSpecifiedRate` — the state the
        // `.unexpectedPause` trigger can never reach — confirms here.
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 100.4, timeControl: .waiting, bufferedAhead: 0.1)),
            context: context,
            now: at(3)
        )
        XCTAssertEqual(
            action,
            .reloadItem(atMediaSeconds: 100.4, reason: "item_death_failed_to_end_1")
        )
    }

    func testItemDeath_FailedToEnd_PositionDriftCancelsTheCandidate() {
        // B:146 `progressCancellationThresholdSeconds = 0.5` — the item is
        // still rendering, so the failure was not terminal.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemFailedToEnd(position: 100, userPaused: false),
            context: context,
            now: t0
        )
        XCTAssertNil(action)

        (action, context) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 100.6, timeControl: .waiting, bufferedAhead: 0.1)),
            context: context,
            now: at(3)
        )
        XCTAssertNil(action, "0.6 s of drift cancels the candidate")

        // And the cancellation is permanent: a later tick at the same position
        // has nothing left to confirm.
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 100.6, timeControl: .waiting, bufferedAhead: 0.1)),
            context: context,
            now: at(6)
        )
        XCTAssertNil(action)
    }

    func testItemDeath_FailedToEnd_ArmsNothingOutsideAnEstablishedLoopback() {
        // B:3453-3454 — anything else falls through to
        // `recoverLocalLoopbackFailureIfNeeded`, which arrives classified as
        // `.playlistUnchanged` instead.
        var startup = startupContext()
        var action: RecoveryAction?
        (action, startup) = RecoveryPolicy.decide(
            .itemFailedToEnd(position: 100, userPaused: false),
            context: startup,
            now: t0
        )
        XCTAssertNil(action)
        XCTAssertEqual(startup, startupContext(), "no candidate before the file-loaded edge")

        var hls = RecoveryContext.initial(route: .avPlayerHLS)
        hls.playbackEstablished = true
        let (offRoute, next) = RecoveryPolicy.decide(
            .itemFailedToEnd(position: 100, userPaused: false),
            context: hls,
            now: t0
        )
        XCTAssertNil(offRoute)
        XCTAssertEqual(next, hls)
    }

    func testItemDeath_FailedToEnd_IsNotItemDeathEvidence() {
        // The two mechanisms must stay apart: `.itemDeathEvidence` gates on
        // `isItemDeath(...)` (B:60) and confirms at weight 2, while the
        // failed-to-end note (B:3455) classifies nothing and always opens the
        // 3 s window. Feeding the same notification through both would reload
        // immediately instead.
        var context = loopbackContext()
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .itemFailedToEnd(position: 100, userPaused: false),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        (action, _) = RecoveryPolicy.decide(
            .playheadTick(sample(position: 100, timeControl: .waiting, bufferedAhead: 0.1)),
            context: context,
            now: at(0.5)
        )
        XCTAssertNil(action, "no immediate reload — the window owns the decision")
    }

    // MARK: - E — edge watchdog (B:3201)

    private func edgeSample(
        referenceTime: Double = 99.5,
        loadedEnd: Double = 100,
        playlistEnd: Double = 120,
        playlistHash: UInt64 = 2,
        targetDuration: Double = 4,
        longestSegment: Double = 5
    ) -> EdgeSample {
        EdgeSample(
            referenceTime: referenceTime,
            loadedEnd: loadedEnd,
            playlistEnd: playlistEnd,
            playlistHash: playlistHash,
            loadedAhead: max(0, loadedEnd - referenceTime),
            visibleAhead: max(0, playlistEnd - referenceTime),
            targetDuration: targetDuration,
            longestSegment: longestSegment
        )
    }

    private func seededEdgeContext() -> RecoveryContext {
        let context = loopbackContext(
            lastSample: sample(position: 99.5, bufferedAhead: 0.2, generatedAhead: 20.5)
        )
        let (_, next) = RecoveryPolicy.decide(
            .edgeSample(edgeSample(playlistEnd: 110, playlistHash: 1)),
            context: context,
            now: t0
        )
        return next
    }

    func testEdge_FirstSample_OnlySeeds() {
        // B:3213-3220.
        let context = loopbackContext()
        let (action, next) = RecoveryPolicy.decide(
            .edgeSample(edgeSample()),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        XCTAssertEqual(next.edge?.lastLoadedEnd, 100)
        XCTAssertEqual(next.edge?.lastPlaylistEnd, 120)
        XCTAssertEqual(next.edge?.lastLoadedEndAdvancedAt, t0)
    }

    func testEdge_Thresholds_ReanchorWhenThePlaylistOutrunsTheLoadedEdge() {
        // B:3239-3243.
        let context = seededEdgeContext()
        let delay = oracleEdgeWatchdogDelay(targetDuration: 4)
        XCTAssertEqual(delay, 9)
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample()),
            context: context,
            now: at(delay)
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 99.5, reason: "edge_watchdog"))
    }

    func testEdge_WatchdogDelay_HoldsUntilTheTargetDurationWindowElapses() {
        let context = seededEdgeContext()
        let delay = oracleEdgeWatchdogDelay(targetDuration: 4)
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample()),
            context: context,
            now: at(delay - 0.1)
        )
        XCTAssertNil(action)
    }

    func testEdge_Thresholds_HoldWhenTheLoadedEdgeStillAdvances() {
        // B:3240 — `!loadedAdvanced`; 0.25 is the advance epsilon (B:3224).
        let context = seededEdgeContext()
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample(loadedEnd: 100.26)),
            context: context,
            now: at(20)
        )
        XCTAssertNil(action)
    }

    func testEdge_Thresholds_RequireTheLoadedRunwayToBeAtThePlayhead() {
        // B:3241 — `loadedAhead <= 1.0`.
        let context = seededEdgeContext()
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample(referenceTime: 98.9)),
            context: context,
            now: at(20)
        )
        XCTAssertNil(action, "1.1 s of loaded runway is not an edge sitting at the playhead")
    }

    func testEdge_Thresholds_RequireTheVisibleRunwayFloor() {
        // B:3242 — `visibleAhead >= max(6.0, targetDuration + longestSegment)`.
        let floor = oracleEdgeVisibleAheadFloor(targetDuration: 4, longestSegment: 5)
        XCTAssertEqual(floor, 9)
        let context = seededEdgeContext()
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample(playlistEnd: 99.5 + floor - 0.1)),
            context: context,
            now: at(20)
        )
        XCTAssertNil(action)
    }

    func testEdge_PlaylistHashChange_CountsAsAdvance() {
        // B:3229 — a body-hash change is playlist advance even without a
        // visible-end move.
        let context = seededEdgeContext()
        let (action, _) = RecoveryPolicy.decide(
            .edgeSample(edgeSample(playlistEnd: 110, playlistHash: 77)),
            context: context,
            now: at(20)
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 99.5, reason: "edge_watchdog"))
    }

    // MARK: - X / Y / the shared reanchor rung (B:3666)

    func testStalled_SharedRung_ReanchorsWithBufferedEdge() {
        // B:3426-3436 → defaults `requireBufferedEdge: true, reason: "stall"`.
        let context = loopbackContext(
            lastSample: sample(bufferedAhead: 0.4, generatedAhead: 20)
        )
        let (action, next) = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 100, reason: "stall"))
        XCTAssertEqual(next.playhead.lastStallRecoveryAt, t0)
    }

    func testStalled_SharedRung_RequiresTheBufferedEdge() {
        // B:3681 — `bufferedAhead <= 0.5`.
        let context = loopbackContext(
            lastSample: sample(bufferedAhead: 0.6, generatedAhead: 20)
        )
        let (action, _) = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        XCTAssertNil(action)
    }

    func testStalled_SharedRung_HoldsWithinTheCooldown() {
        // B:3677 — the 10 s cooldown.
        var context = loopbackContext(lastSample: sample(bufferedAhead: 0.4, generatedAhead: 20))
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        XCTAssertNotNil(action)
        (action, context) = RecoveryPolicy.decide(.playbackStalled, context: context, now: at(9.9))
        XCTAssertNil(action)
        (action, _) = RecoveryPolicy.decide(.playbackStalled, context: context, now: at(10))
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 100, reason: "stall"))
    }

    func testStalled_SharedRung_IsMuzzledWhileSuspended() {
        // B:3675.
        let context = loopbackContext(
            suspendedReasons: ["origin_outage"],
            lastSample: sample(bufferedAhead: 0.4, generatedAhead: 20)
        )
        let (action, _) = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        XCTAssertNil(action)
    }

    func testSharedRung_GeneratedAhead_UsesTheStartupFloorBeforeTenSeconds() {
        // B:3686 — one fragment-equivalent below 10 s of player time, a full
        // steady-state runway above it.
        XCTAssertEqual(oracleMinimumGeneratedAhead(playerSeconds: 9.9), 4.0)
        XCTAssertEqual(oracleMinimumGeneratedAhead(playerSeconds: 10), 10)

        let early = loopbackContext(
            lastSample: sample(position: 9.9, bufferedAhead: 0.1, generatedAhead: 4.1)
        )
        var (action, _) = RecoveryPolicy.decide(.playbackStalled, context: early, now: t0)
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 9.9, reason: "stall"))

        let steady = loopbackContext(
            lastSample: sample(position: 10, bufferedAhead: 0.1, generatedAhead: 4.1)
        )
        (action, _) = RecoveryPolicy.decide(.playbackStalled, context: steady, now: t0)
        XCTAssertNil(action, "past 10 s the rung wants a full steady-state runway")
    }

    func testPlaylistUnchanged_Paused_DefersUntilPlay() {
        // B:3556-3565 — latched and consumed by `play()` (B:979-990).
        let context = loopbackContext(
            userPaused: true,
            mediaTimelineOffset: 12,
            lastSample: sample(bufferedAhead: 0.1, generatedAhead: 20, userPaused: true)
        )
        let (action, _) = RecoveryPolicy.decide(
            .playlistUnchanged(userPaused: true),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .deferUntilPlay(mediaSeconds: 112))
    }

    func testPlaylistUnchanged_Playing_ReanchorsWithoutTheBufferedEdgeRequirement() {
        // B:3566 — `requireBufferedEdge: false`, so a full buffer still qualifies.
        let context = loopbackContext(
            lastSample: sample(bufferedAhead: 30, generatedAhead: 20)
        )
        let (action, _) = RecoveryPolicy.decide(
            .playlistUnchanged(userPaused: false),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 100, reason: "playlist_unchanged"))
    }

    // MARK: - Auto-resume rung (B:3698)

    func testAutoResume_Resumes_WhenLikelyToKeepUp() {
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .likelyToKeepUp(rate: 0, bufferedAhead: 0.1, reachedEnd: false, likely: true),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .resumePlayback)
    }

    func testAutoResume_Resumes_OnBufferedRunwayAlone() {
        // B:3711 — `isPlaybackLikelyToKeepUp || bufferedAhead > 0.5`.
        let context = loopbackContext()
        var (action, _) = RecoveryPolicy.decide(
            .likelyToKeepUp(rate: 0, bufferedAhead: 0.51, reachedEnd: false, likely: false),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .resumePlayback)

        (action, _) = RecoveryPolicy.decide(
            .likelyToKeepUp(rate: 0, bufferedAhead: 0.5, reachedEnd: false, likely: false),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
    }

    func testAutoResume_Holds_AfterTheItemReachedEnd() {
        // B:3704 — review §3 #15: a late buffer KVO must not restart transport
        // behind the end-of-file hand-off.
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .likelyToKeepUp(rate: 0, bufferedAhead: 10, reachedEnd: true, likely: true),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
    }

    func testAutoResume_Holds_WhilePlaying() {
        // B:3707 — `avPlayer.rate == 0`.
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .likelyToKeepUp(rate: 1, bufferedAhead: 10, reachedEnd: false, likely: true),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
    }

    // MARK: - Seek deadlines (B:1264)

    func testSeekDeadline_Interactive_ReanchorsOnLoopback() {
        // B:1290-1310 — the latched seek target is the anchor.
        let context = loopbackContext()
        let (action, _) = RecoveryPolicy.decide(
            .seekDeadlineExpired(kind: .interactive(mediaTarget: 640)),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .reanchor(atMediaSeconds: 640, reason: "vod_stall_nudge"))
    }

    func testSeekDeadline_Interactive_ResumesOffLoopback() {
        // B:1306-1308 — off loopback the deadline just re-enables playback.
        var context = RecoveryContext.initial(route: .avPlayerHLS)
        context.playbackEstablished = true
        let (action, _) = RecoveryPolicy.decide(
            .seekDeadlineExpired(kind: .interactive(mediaTarget: 640)),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .resumePlayback)
    }

    func testSeekDeadline_Recovery_TakesNoAction() {
        // B:1312-1320 — the rung that issued the seek owns the next step.
        let context = loopbackContext()
        var (action, _) = RecoveryPolicy.decide(
            .seekDeadlineExpired(kind: .recovery(reason: "vod_stall_nudge")),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        (action, _) = RecoveryPolicy.decide(
            .seekDeadlineExpired(kind: .initial(mediaTarget: 10)),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
    }

    // MARK: - The failure ladder (PVM:1537)

    private func onlineContext(route: PlaybackEngineKind = .siloPlayerLoopback) -> RecoveryContext {
        var context = RecoveryContext.initial(route: route)
        context.playbackEstablished = true
        context.isProtocolV3Active = true
        return context
    }

    private func offlineContext(route: PlaybackEngineKind) -> RecoveryContext {
        var context = RecoveryContext.initial(route: route)
        context.playbackEstablished = true
        // PVM:2284 — `requestServerHLSRouteFallback` needs something to replan
        // against. A load that reached `handlePlaybackError` normally has it;
        // the two rungs that read it have their own negative tests below.
        context.hasWatchDetail = true
        return context
    }

    func testEngineFailed_NearEnd_TreatedAsNaturalEnd() {
        // PVM:1548 — corroborated by the oracle at PVM:1697.
        var context = onlineContext()
        context.nearEnd = RecoveryContext.NearEndInputs(
            duration: 100,
            currentTime: 92,
            bufferedAhead: 1,
            sourceOutageActive: false
        )
        XCTAssertTrue(
            oracleTreatAsNaturalEnd(
                duration: 100,
                currentTime: 92,
                bufferedAheadSeconds: 1,
                isSourceOutageActive: false
            )
        )
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .treatAsNaturalEnd, "the near-end rung outranks the V3 replan")
    }

    func testEngineFailed_NearEnd_HeldByBufferedRunway() {
        // PVM:964 — more than 1 s queued ahead is a mid-stream fault.
        var context = onlineContext()
        context.nearEnd = RecoveryContext.NearEndInputs(
            duration: 100,
            currentTime: 95,
            bufferedAhead: 1.01,
            sourceOutageActive: false
        )
        XCTAssertFalse(
            oracleTreatAsNaturalEnd(
                duration: 100,
                currentTime: 95,
                bufferedAheadSeconds: 1.01,
                isSourceOutageActive: false
            )
        )
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(
            action,
            .requestServerReplan(classification: "playback_error", message: "boom")
        )
    }

    func testEngineFailed_NearEnd_HeldByAnActiveSourceOutage() {
        // PVM:1706 — during an outage the failure is a transport problem the
        // recovery ladder owns, not a drain.
        var context = onlineContext()
        context.nearEnd = RecoveryContext.NearEndInputs(
            duration: 100,
            currentTime: 99,
            bufferedAhead: 0,
            sourceOutageActive: true
        )
        XCTAssertFalse(
            oracleTreatAsNaturalEnd(
                duration: 100,
                currentTime: 99,
                bufferedAheadSeconds: 0,
                isSourceOutageActive: true
            )
        )
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertNotEqual(action, .treatAsNaturalEnd)
    }

    func testEngineFailed_NearEnd_HeldOutsideTheEightSecondThreshold() {
        // PVM:960.
        var context = onlineContext()
        context.nearEnd = RecoveryContext.NearEndInputs(
            duration: 100,
            currentTime: 91.9,
            bufferedAhead: 0,
            sourceOutageActive: false
        )
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertNotEqual(action, .treatAsNaturalEnd)
    }

    func testEngineFailed_ProtocolV3_RequestsAServerReplan() {
        // PVM:1553 — V3 owns delivery, so every rung below is unreachable online.
        let failure = PlaybackFailure.writerFailed(kind: .prematureSourceEnd, detail: "short read")
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(failure),
            context: onlineContext(),
            now: t0
        )
        XCTAssertEqual(
            action,
            .requestServerReplan(
                classification: failure.classification,
                message: failure.legacyMessage
            )
        )
    }

    func testEngineFailed_ActiveOutageRecovery_SuppressesTheLadder() {
        // PVM:1544.
        var context = onlineContext()
        context.serverOutageRecovery = RecoveryContext.ServerOutageRecoveryState(waitStart: t0)
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
    }

    func testEngineFailed_SessionMissing_RenewsInBackgroundThenFresh() {
        // PVM:1557-1563.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canRenewSourceInBackground = true
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .engineFailed(.unknown("playback_session_not_found")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .renewSourceInBackground(reason: "player_error"))
        XCTAssertTrue(context.backgroundRenewalInFlight)

        // PVM:4094 — the single-flight makes a second report a no-op.
        (action, context) = RecoveryPolicy.decide(
            .engineFailed(.unknown("playback_session_not_found")),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
    }

    func testEngineFailed_PrematureSourceEnd_EntersServerOutageRecovery() {
        // PVM:1565-1576.
        let context = offlineContext(route: .siloPlayerLoopback)
        let (action, next) = RecoveryPolicy.decide(
            .engineFailed(.writerFailed(kind: .prematureSourceEnd, detail: "short read")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .recoverFromServerOutage(reason: "network_unavailable"))
        XCTAssertEqual(next.serverOutageRecovery?.waitStart, t0)
    }

    func testEngineFailed_Interruption_AutoRecovers() {
        // PVM:1579-1582.
        var context = offlineContext(route: .siloPlayerLoopback)
        context.canAutoRecoverInterruption = true
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .autoRecoverInterruption)
    }

    func testEngineFailed_NativeDirect_SwitchesToLoopbackOnce() {
        // PVM:2174 — the latch bounds the rung to one attempt per load.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canBuildLoopbackFallback = true
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .switchRoute(.loopbackFallback))
        XCTAssertTrue(context.attemptedNativeDirectFallback)

        (action, _) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: at(1)
        )
        XCTAssertEqual(action, .fail(.unknown("boom")), "the second failure is terminal")
    }

    func testEngineFailed_NativeDirect_EscalatesToServerHLSWithoutALocalPlan() {
        // PVM:2192-2204 — nothing local can remux this source.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canBuildLoopbackFallback = false
        let (action, next) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(
            action,
            .switchRoute(.serverHLS(classification: "native_direct_avplayer_failed"))
        )
        XCTAssertTrue(next.attemptedNativeDirectFallback)
    }

    func testEngineFailed_NativeDirect_KeepsTheLatchClearWhileAReplanIsInFlight() {
        // PVM:2284 — `requestServerHLSRouteFallback` returns false, so the rung
        // never claims its one attempt.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canBuildLoopbackFallback = false
        context.isReplanInFlight = true
        let (action, next) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .fail(.unknown("boom")))
        XCTAssertFalse(next.attemptedNativeDirectFallback)
    }

    func testEngineFailed_Loopback_SwitchesToServerHLSOnce() {
        // PVM:2258.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .engineFailed(.loopbackStartupStalled(trigger: "fetches_frozen")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .switchRoute(.serverHLS(classification: "silo_loopback_failed")))
        XCTAssertTrue(context.attemptedLoopbackHLSFallback)

        let failure = PlaybackFailure.loopbackStartupStalled(trigger: "fetches_frozen")
        (action, _) = RecoveryPolicy.decide(.engineFailed(failure), context: context, now: at(1))
        XCTAssertEqual(action, .fail(failure))
    }

    func testEngineFailed_ServerHLS_RequiresAWatchDetail() {
        // PVM:2284 — `requestServerHLSRouteFallback` returns false without one,
        // so rung 9 returns false, rung 10 fails the same guard, and
        // `finalizeTerminalPlaybackError` owns the failure (PVM:1589).
        var nativeDirect = offlineContext(route: .avPlayerNativeDirect)
        nativeDirect.hasWatchDetail = false
        nativeDirect.canBuildLoopbackFallback = false
        let failure = PlaybackFailure.unknown("boom")
        var (action, next) = RecoveryPolicy.decide(
            .engineFailed(failure),
            context: nativeDirect,
            now: t0
        )
        XCTAssertEqual(action, .fail(failure))
        XCTAssertFalse(next.attemptedNativeDirectFallback, "an unaccepted replan claims no attempt")

        var loopback = offlineContext(route: .siloPlayerLoopback)
        loopback.hasWatchDetail = false
        (action, next) = RecoveryPolicy.decide(
            .engineFailed(failure),
            context: loopback,
            now: t0
        )
        XCTAssertEqual(action, .fail(failure))
        XCTAssertFalse(next.attemptedLoopbackHLSFallback)
    }

    func testEngineFailed_NativeDirect_StillFallsBackLocallyWithoutAWatchDetail() {
        // `makeLoopbackFallbackPlan` needs a resolved version (PVM:2307), not
        // a watch detail, so the local rung is unaffected by PVM:2284.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.hasWatchDetail = false
        context.canBuildLoopbackFallback = true
        let (action, next) = RecoveryPolicy.decide(
            .engineFailed(.unknown("boom")),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .switchRoute(.loopbackFallback))
        XCTAssertTrue(next.attemptedNativeDirectFallback)
    }

    func testEngineFailed_Terminal_FailsWhenEveryRungIsSpent() {
        // PVM:1589.
        var context = offlineContext(route: .avPlayerHLS)
        context.attemptedNativeDirectFallback = true
        context.attemptedLoopbackHLSFallback = true
        let failure = PlaybackFailure.itemFailed(
            .init(description: "decode failed", domain: "AVFoundation", code: -11800)
        )
        let (action, _) = RecoveryPolicy.decide(
            .engineFailed(failure),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .fail(failure))
    }

    // MARK: - Session renewal (PVM:4085 / PVM:4212)

    func testSessionMissing_NonDirectDelivery_GoesStraightToFreshRenewal() {
        // PVM:4088 — a silent renewal only exists on a proxied direct source.
        var context = offlineContext(route: .siloPlayerLoopback)
        context.canRenewSourceInBackground = false
        let (action, next) = RecoveryPolicy.decide(
            .sessionMissing(source: .proxy404),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .renewSessionFresh(reason: "source_404"))
        XCTAssertTrue(next.freshRenewalInFlight)
    }

    func testSessionMissing_Background_SingleFlights() {
        // PVM:4094-4097.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canRenewSourceInBackground = true
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sessionMissing(source: .progressHeartbeat),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .renewSourceInBackground(reason: "progress"))
        (action, _) = RecoveryPolicy.decide(
            .sessionMissing(source: .progressHeartbeat),
            context: context,
            now: at(10)
        )
        XCTAssertNil(action)
    }

    func testSessionMissing_TransientLimit_EscalatesToFreshRenewal() {
        // PVM:601 `backgroundRenewalTransientFailureLimit = 3` + PVM:4199
        // `failBackgroundRenewal`'s `_bg_renewal_failed` suffix.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.canRenewSourceInBackground = true
        var action: RecoveryAction?
        for failures in 0..<3 {
            context.backgroundRenewalTransientFailures = failures
            context.backgroundRenewalInFlight = false
            (action, context) = RecoveryPolicy.decide(
                .sessionMissing(source: .playerError),
                context: context,
                now: at(Double(failures))
            )
            XCTAssertEqual(action, .renewSourceInBackground(reason: "player_error"))
        }
        context.backgroundRenewalTransientFailures = 3
        context.backgroundRenewalInFlight = false
        (action, context) = RecoveryPolicy.decide(
            .sessionMissing(source: .playerError),
            context: context,
            now: at(4)
        )
        XCTAssertEqual(action, .renewSessionFresh(reason: "player_error_bg_renewal_failed"))
        XCTAssertEqual(context.backgroundRenewalTransientFailures, 0)
        XCTAssertFalse(context.backgroundRenewalInFlight)
    }

    func testSessionMissing_FreshRenewal_SingleFlights() {
        // PVM:4219-4223.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sessionMissing(source: .replanCatch),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .renewSessionFresh(reason: "replan"))
        (action, _) = RecoveryPolicy.decide(
            .sessionMissing(source: .replanCatch),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
    }

    // MARK: - Origin-outage ride-through (PVM:4280)

    func testOutage_RideThrough_StartsWithTheInitialProbeDelay() {
        // PVM:4299-4300 — the loop probes at once with `delay` primed at 1 s.
        let context = offlineContext(route: .avPlayerNativeDirect)
        let (action, next) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .rideThroughOutage(probeAfter: .seconds(1)))
        XCTAssertEqual(next.outage?.rideThroughStart, t0)
        XCTAssertEqual(next.outage?.nextProbeDelay, 1)
        XCTAssertEqual(next.outage?.noticeShown, false)
    }

    func testOutage_RideThrough_IsNotRestartedWhileActive() {
        // PVM:4284.
        var context = offlineContext(route: .avPlayerNativeDirect)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: t0
        )
        (action, _) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
    }

    func testOutage_RideThrough_YieldsToAVisibleRecovery() {
        // PVM:4284.
        var context = offlineContext(route: .avPlayerNativeDirect)
        context.serverOutageRecovery = RecoveryContext.ServerOutageRecoveryState(waitStart: t0)
        let (action, next) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
        XCTAssertNil(next.outage)
    }

    func testOutage_Backoff_DoublesToTheEightSecondCap() {
        // PVM:4310 — `delay = min(delay * 2, 8)` on every iteration, whatever
        // the probe said.
        var context = offlineContext(route: .avPlayerNativeDirect)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: t0
        )
        var expected: TimeInterval = 1
        var elapsed: TimeInterval = 0
        for probe in 0..<5 {
            expected = oracleNextBackoff(expected)
            elapsed += expected
            (action, context) = RecoveryPolicy.decide(
                .serverHealthProbe(ok: probe.isMultiple(of: 2)),
                context: context,
                now: at(elapsed)
            )
            XCTAssertEqual(action, .rideThroughOutage(probeAfter: .seconds(expected)))
        }
        XCTAssertEqual(expected, 8, "1 → 2 → 4 → 8 → 8 → 8")
    }

    func testOutage_Budget_EscalatesToServerOutageRecovery() {
        // PVM:4301-4304 / PVM:4312-4321 — the 90 s budget hands over to the visible
        // recovery.
        var context = offlineContext(route: .avPlayerNativeDirect)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: t0
        )
        (action, context) = RecoveryPolicy.decide(
            .serverHealthProbe(ok: false),
            context: context,
            now: at(89.9)
        )
        XCTAssertEqual(action, .rideThroughOutage(probeAfter: .seconds(2)))

        (action, context) = RecoveryPolicy.decide(
            .serverHealthProbe(ok: false),
            context: context,
            now: at(90)
        )
        XCTAssertEqual(action, .recoverFromServerOutage(reason: "network_unavailable"))
        XCTAssertNil(context.outage, "the ride-through does not outlive the proxy")
        XCTAssertEqual(context.serverOutageRecovery?.waitStart, at(90))
    }

    func testOutage_Exit_EndsTheRideThroughWithAKick() {
        // PVM:4323-4331 — the second half of the two-owner handshake.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: t0
        )
        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: false),
            context: context,
            now: at(5)
        )
        XCTAssertEqual(action, .endOutageRideThrough(kick: true))
        XCTAssertNil(context.outage)

        // PVM:4324 — an inactive edge with no ride-through is a no-op.
        (action, _) = RecoveryPolicy.decide(
            .originOutage(active: false),
            context: context,
            now: at(6)
        )
        XCTAssertNil(action)
    }

    func testOutage_Buffering_LatchesTheReconnectingNoticeOnce() {
        // PVM:4371 — the runway gate keeps short outages entirely invisible.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .bufferingChanged(true),
            context: context,
            now: t0
        )
        XCTAssertNil(action)
        XCTAssertNil(context.outage, "no outage, no notice")

        (action, context) = RecoveryPolicy.decide(
            .originOutage(active: true),
            context: context,
            now: at(1)
        )
        XCTAssertEqual(context.outage?.noticeShown, false)
        (action, context) = RecoveryPolicy.decide(
            .bufferingChanged(true),
            context: context,
            now: at(2)
        )
        XCTAssertNil(action)
        XCTAssertEqual(context.outage?.noticeShown, true)

        (action, context) = RecoveryPolicy.decide(
            .bufferingChanged(false),
            context: context,
            now: at(3)
        )
        XCTAssertNil(action)
        XCTAssertEqual(context.outage?.noticeShown, true, "the latch is one-way within an outage")
    }

    // MARK: - Visible server-outage recovery (PVM:4385 / PVM:4494)

    func testServerOutage_SourceInterrupted_StartsTheVisibleRecovery() {
        var context = offlineContext(route: .siloPlayerLoopback)
        context.backgroundRenewalInFlight = true
        let (action, next) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .sourceEntityChanged),
            context: context,
            now: t0
        )
        XCTAssertEqual(action, .recoverFromServerOutage(reason: "source_entity_changed"))
        XCTAssertFalse(
            next.backgroundRenewalInFlight,
            "PVM:4406 cancels the silent renewal so its retarget cannot land mid-teardown"
        )
    }

    func testServerOutage_SourceInterrupted_SingleFlights() {
        // PVM:4396-4398.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .networkUnavailable),
            context: context,
            now: t0
        )
        XCTAssertNotNil(action)
        (action, _) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .networkUnavailable),
            context: context,
            now: at(1)
        )
        XCTAssertNil(action)
    }

    func testServerOutage_Wait_BacksOffAndFailsAtTheTimeout() {
        // PVM:4494-4527 — same 1→8 s ladder inside a 90 s budget.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .networkUnavailable),
            context: context,
            now: t0
        )
        var expected: TimeInterval = 1
        var elapsed: TimeInterval = 0
        for _ in 0..<4 {
            (action, context) = RecoveryPolicy.decide(
                .serverHealthProbe(ok: false),
                context: context,
                now: at(elapsed)
            )
            XCTAssertEqual(action, .waitForServerReady(probeAfter: .seconds(expected)))
            elapsed += expected
            expected = oracleNextBackoff(expected)
        }
        XCTAssertEqual(expected, 8)

        (action, context) = RecoveryPolicy.decide(
            .serverHealthProbe(ok: false),
            context: context,
            now: at(90)
        )
        XCTAssertEqual(
            action,
            .fail(.unknown("The server did not come back online in time."))
        )
        XCTAssertNil(context.serverOutageRecovery)
    }

    func testServerOutage_Wait_ClampsTheFinalSleepToTheRemainingBudget() {
        // PVM:4522 — `min(delay, remaining)`.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .networkUnavailable),
            context: context,
            now: t0
        )
        (action, _) = RecoveryPolicy.decide(
            .serverHealthProbe(ok: false),
            context: context,
            now: at(89.5)
        )
        XCTAssertEqual(action, .waitForServerReady(probeAfter: .seconds(0.5)))
    }

    func testServerOutage_Wait_ClearsOnAHealthyProbe() {
        // PVM:4504-4513 — success (or a 401/403) ends the wait; the reload is
        // the engine's tail of `.recoverFromServerOutage`.
        var context = offlineContext(route: .siloPlayerLoopback)
        var action: RecoveryAction?
        (action, context) = RecoveryPolicy.decide(
            .sourceInterrupted(reason: .networkUnavailable),
            context: context,
            now: t0
        )
        (action, context) = RecoveryPolicy.decide(
            .serverHealthProbe(ok: true),
            context: context,
            now: at(3)
        )
        XCTAssertNil(action)
        XCTAssertNil(context.serverOutageRecovery)
    }

    // MARK: - Cross-cutting

    func testDecide_IsPure() {
        // The same observation against the same context must produce the same
        // answer no matter how often it is asked.
        let context = loopbackContext(lastSample: sample(bufferedAhead: 0.1, generatedAhead: 20))
        let first = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        let second = RecoveryPolicy.decide(.playbackStalled, context: context, now: t0)
        XCTAssertEqual(first.action, second.action)
        XCTAssertEqual(first.context, second.context)
    }

    func testDecide_OffLoopbackRoutesIgnoreInRouteRungs() {
        // Every in-route rung guards `case .siloLoopback` on the backend.
        var context = RecoveryContext.initial(route: .avPlayerHLS)
        context.playbackEstablished = true
        context.playhead.lastSample = sample(bufferedAhead: 0.1, generatedAhead: 20)
        let observations: [RecoveryObservation] = [
            .playheadTick(sample()),
            .playbackStalled,
            .playlistUnchanged(userPaused: false),
            .edgeSample(edgeSample()),
            .likelyToKeepUp(rate: 0, bufferedAhead: 10, reachedEnd: false, likely: true),
            .startupTick(servedRequests: 0, displayModeSwitchInProgress: false)
        ]
        for observation in observations {
            let (action, next) = RecoveryPolicy.decide(observation, context: context, now: at(30))
            XCTAssertNil(action, "\(observation) must not act off the loopback route")
            XCTAssertEqual(next, context)
        }
    }

    func testInterruptionReason_TokensKeepTheEntityChangedDiscriminator() {
        // PVM:4428 branches on `.sourceEntityChanged`, so the token must stay
        // distinguishable from every other reason.
        let tokens = [
            RecoveryPolicy.token(for: .networkUnavailable),
            RecoveryPolicy.token(for: .serverUnavailable(statusCode: 503)),
            RecoveryPolicy.token(for: .prematureEOF(offset: 10, expectedEnd: 99)),
            RecoveryPolicy.token(for: .sourceEntityChanged)
        ]
        XCTAssertEqual(Set(tokens).count, 4)
        XCTAssertEqual(RecoveryPolicy.token(for: .networkUnavailable), "network_unavailable")
        XCTAssertEqual(RecoveryPolicy.token(for: .sourceEntityChanged), "source_entity_changed")
    }
}
