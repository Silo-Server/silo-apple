import XCTest
@testable import Silo

/// `RecoveryDriver` is the only runtime caller of
/// `RecoveryPolicy.decide`, so what it owes is narrow and testable: it threads
/// the context between observations, mirrors the live inputs the pure policy
/// cannot read for itself, and holds the suspension latch the retired
/// two-owner handshake used to hold.
///
/// The rungs themselves are pinned by `RecoveryPolicyTests`; these tests pin the
/// *threading*, which is what makes the ladders load-scoped instead of
/// process-scoped.
final class RecoveryDriverTests: XCTestCase {

    private func loopbackDriver(established: Bool = true) -> RecoveryDriver {
        let driver = RecoveryDriver(route: .siloPlayerLoopback)
        driver.note(playbackEstablished: established)
        return driver
    }

    private func sample(
        position: Double,
        timeControl: PlayheadSample.TimeControl = .playing,
        bufferedAhead: Double = 0,
        generatedAhead: Double = 40,
        secondsSinceLastServe: Double = .infinity,
        userPaused: Bool = false,
        playbackEstablished: Bool = true
    ) -> PlayheadSample {
        PlayheadSample(
            position: position,
            timeControl: timeControl,
            bufferedAhead: bufferedAhead,
            generatedAhead: generatedAhead,
            secondsSinceLastServe: secondsSinceLastServe,
            userPaused: userPaused,
            playbackEstablished: playbackEstablished
        )
    }

    // MARK: - Suspension

    /// The `setRecoverySuspended` handshake became `RecoveryContext.suspendedReasons`,
    /// reference-counted by reason exactly as the backend's latch was: one
    /// owner clearing its reason must not release another owner's hold, and no
    /// in-route rung may act while any reason is held.
    func testSuspensionIsReferenceCountedByReasonAndMuzzlesTheInRouteRungs() {
        let driver = loopbackDriver()
        driver.setSuspended(true, reason: RecoveryDriver.originOutageSuspensionReason)
        driver.setSuspended(true, reason: RecoveryDriver.serverReplanSuspensionReason)
        XCTAssertEqual(
            driver.context.suspendedReasons,
            [
                RecoveryDriver.originOutageSuspensionReason,
                RecoveryDriver.serverReplanSuspensionReason,
            ]
        )

        // The shared reanchor rung would fire on this sample if nothing held
        // the latch (`.playbackStalled` → `reanchorIfNeeded`).
        driver.note(playheadSample: sample(position: 100, bufferedAhead: 0, generatedAhead: 40))
        XCTAssertNil(driver.observe(.playbackStalled))

        driver.setSuspended(false, reason: RecoveryDriver.originOutageSuspensionReason)
        XCTAssertEqual(
            driver.context.suspendedReasons,
            [RecoveryDriver.serverReplanSuspensionReason]
        )
        XCTAssertNil(driver.observe(.playbackStalled))

        driver.setSuspended(false, reason: RecoveryDriver.serverReplanSuspensionReason)
        XCTAssertTrue(driver.context.suspendedReasons.isEmpty)
        XCTAssertEqual(
            driver.observe(.playbackStalled),
            .reanchor(atMediaSeconds: 100, cause: .stall)
        )
    }

    /// Every change is published so the backend's periodic
    /// `[CMP-AVP] loopback playhead state` line keeps printing its
    /// `suspended=[…]` suffix — the only thing left that reads the latch
    /// outside the policy.
    func testSuspensionChangesArePublishedForTelemetry() {
        let driver = loopbackDriver()
        var published: [Set<String>] = []
        driver.onSuspensionChanged = { published.append($0) }

        driver.setSuspended(true, reason: RecoveryDriver.originOutageSuspensionReason)
        // A repeat of a held reason changes nothing and publishes nothing.
        driver.setSuspended(true, reason: RecoveryDriver.originOutageSuspensionReason)
        driver.setSuspended(false, reason: RecoveryDriver.originOutageSuspensionReason)

        XCTAssertEqual(published, [[RecoveryDriver.originOutageSuspensionReason], []])
    }

    // MARK: - Context threading

    /// The context is threaded across observations: the playhead watchdog's
    /// rolling reanchor budget is spent one call at a time, and the third
    /// attempt escalates to a rebuild — which is only meaningful because the
    /// count survives between `decide` calls.
    func testReanchorBudgetIsThreadedAcrossObservations() {
        let driver = loopbackDriver()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        // Seed the advance tracker, then hold the playhead still for 10 s.
        _ = driver.observe(.playheadTick(sample(position: 100)), now: start)

        var actions: [RecoveryAction?] = []
        for tick in 1...4 {
            actions.append(
                driver.observe(
                    .playheadTick(sample(position: 100)),
                    now: start.addingTimeInterval(Double(tick) * 11)
                )
            )
        }

        XCTAssertEqual(actions[0], .reanchor(atMediaSeconds: 100, cause: .vodStallNudge))
        XCTAssertEqual(actions[1], .reloadItem(atMediaSeconds: 100, cause: .vodStall))
        XCTAssertEqual(actions[2], .reloadItem(atMediaSeconds: 100, cause: .vodStall))
        XCTAssertEqual(
            actions[3],
            .rebuildLocalSession(atMediaSeconds: 100, cause: .playheadWatchdogExhausted)
        )
        XCTAssertEqual(driver.context.playhead.reanchorCount, 0)
        XCTAssertEqual(driver.context.rebuildBudget.used, 1)
    }

    /// `note(mediaTimelineOffset:)` is what converts a player-timeline
    /// observation into the media-timeline anchor an action carries. Without
    /// the driver threading it, a reanchor on a late-start title would aim at
    /// the wrong second.
    func testMediaTimelineOffsetIsAppliedToActionAnchors() {
        let driver = loopbackDriver()
        driver.note(mediaTimelineOffset: 30)
        driver.note(playheadSample: sample(position: 100, bufferedAhead: 0, generatedAhead: 40))
        XCTAssertEqual(
            driver.observe(.playbackStalled),
            .reanchor(atMediaSeconds: 130, cause: .stall)
        )
    }

    /// `noteEngineLoadStarted()` resets exactly what
    /// `AVPlayerBackend.load(strategy:)` reset when it owned those fields —
    /// the advance tracker, the reanchor cooldown, the edge watch and the
    /// file-loaded edge — and deliberately keeps the reanchor retry budget,
    /// which only resets on window expiry.
    func testEngineReloadResetsPerLoadStateButKeepsTheReanchorBudget() {
        let driver = loopbackDriver()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        _ = driver.observe(.playheadTick(sample(position: 50)), now: start)
        _ = driver.observe(
            .playheadTick(sample(position: 50)),
            now: start.addingTimeInterval(11)
        )
        XCTAssertEqual(driver.context.playhead.reanchorCount, 1)
        XCTAssertNotNil(driver.context.playhead.stationarySince)

        driver.noteEngineLoadStarted()

        XCTAssertNil(driver.context.playhead.stationarySince)
        XCTAssertNil(driver.context.playhead.lastAdvancePosition)
        XCTAssertNil(driver.context.playhead.lastStallRecoveryAt)
        XCTAssertNil(driver.context.edge)
        XCTAssertFalse(driver.context.playbackEstablished)
        XCTAssertEqual(driver.context.playhead.reanchorCount, 1)
    }

    // MARK: - The startup ladder and its `-15628` direct entry

    /// The item error log's `-15628` loader-poison
    /// signature drives the *startup* ladder directly, and it must still be
    /// able to do so after the 1 Hz timer was cancelled — `status.readyToPlay`
    /// cancels the tick while `didFireFileLoaded` is still false, and the
    /// ladder's stage lives in the context, which that cancellation must not
    /// clear.
    func testStartupLadderEscalatesOnLoaderPoisonAfterTheTimerIsCancelled() {
        let driver = RecoveryDriver(route: .siloPlayerLoopback)
        let armedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        driver.armStartupLadder(startedAt: armedAt, servedRequests: 4)
        // The timer is cancelled here (`status.readyToPlay`); nothing tells the
        // driver, and nothing should.
        XCTAssertNotNil(driver.context.startup)

        let poison = RecoveryObservation.itemDeathEvidence(
            statusCode: -15628,
            description: "loader poisoned",
            weight: 2,
            position: 3,
            userPaused: false
        )
        XCTAssertEqual(driver.observe(poison, now: armedAt.addingTimeInterval(1)), .nudgeStartup)
        XCTAssertEqual(driver.context.startup?.stage, .nudged)
        XCTAssertEqual(
            driver.observe(poison, now: armedAt.addingTimeInterval(2)),
            .reloadStartupItem
        )
        XCTAssertEqual(driver.context.startup?.stage, .reloaded)
        XCTAssertEqual(
            driver.observe(poison, now: armedAt.addingTimeInterval(3)),
            .fail(.loopbackStartupStalled(trigger: "errorLog_-15628"))
        )
        // The ladder is spent, so the stage is gone and a fourth signature is
        // inert rather than looping.
        XCTAssertNil(driver.context.startup)
        XCTAssertNil(driver.observe(poison, now: armedAt.addingTimeInterval(4)))
    }

    /// Re-arming replaces the ladder's whole state, which is what makes the
    /// stage per-load rather than per-process.
    func testArmingTheStartupLadderResetsItsStage() {
        let driver = RecoveryDriver(route: .siloPlayerLoopback)
        let armedAt = Date(timeIntervalSinceReferenceDate: 4_000)
        driver.armStartupLadder(startedAt: armedAt, servedRequests: 0)
        let poison = RecoveryObservation.itemDeathEvidence(
            statusCode: -15628,
            description: "loader poisoned",
            weight: 2,
            position: 0,
            userPaused: false
        )
        XCTAssertEqual(driver.observe(poison, now: armedAt), .nudgeStartup)

        driver.armStartupLadder(startedAt: armedAt.addingTimeInterval(10), servedRequests: 9)
        XCTAssertEqual(driver.context.startup?.stage, .initial)
        XCTAssertEqual(driver.context.startup?.lastRequestCount, 9)
        XCTAssertEqual(
            driver.observe(poison, now: armedAt.addingTimeInterval(11)),
            .nudgeStartup
        )
    }

    // MARK: - Renewal bookkeeping

    /// The silent renewal's transient budget lives in the context and is spent
    /// through the driver, so the limit is read in exactly one place
    /// (`RecoveryPolicy.backgroundRenewalTransientFailureLimit`).
    func testBackgroundRenewalTransientBudgetEscalatesAtTheLimit() {
        let driver = RecoveryDriver(route: .avPlayerNativeDirect)
        driver.note(
            isProtocolV3Active: false,
            isReplanInFlight: false,
            hasWatchDetail: true,
            canRenewSourceInBackground: true,
            canAutoRecoverInterruption: false,
            canBuildLoopbackFallback: false,
            nearEnd: nil
        )

        XCTAssertEqual(
            driver.observe(.sessionMissing(source: .proxy404)),
            .renewSourceInBackground(reason: "source_404")
        )
        XCTAssertTrue(driver.context.backgroundRenewalInFlight)

        var escalated = driver.noteBackgroundRenewalTransientFailure()
        XCTAssertFalse(escalated)
        XCTAssertFalse(driver.context.backgroundRenewalInFlight)
        escalated = driver.noteBackgroundRenewalTransientFailure()
        XCTAssertFalse(escalated)
        escalated = driver.noteBackgroundRenewalTransientFailure()
        XCTAssertTrue(escalated)

        // The escalation re-enters the same rung and lands on the visible
        // renewal with the legacy suffix.
        driver.noteBackgroundRenewalExhausted()
        XCTAssertEqual(
            driver.observe(.sessionMissing(source: .proxy404)),
            .renewSessionFresh(reason: "source_404_bg_renewal_failed")
        )
        XCTAssertTrue(driver.context.freshRenewalInFlight)
    }

    /// A successful renewal clears both single-flights and the budget, which is
    /// what `attemptBackgroundSessionRenewal`'s success tail did by hand.
    func testBackgroundRenewalSuccessClearsBothSingleFlights() {
        let driver = RecoveryDriver(route: .avPlayerNativeDirect)
        driver.note(
            isProtocolV3Active: false,
            isReplanInFlight: false,
            hasWatchDetail: true,
            canRenewSourceInBackground: true,
            canAutoRecoverInterruption: false,
            canBuildLoopbackFallback: false,
            nearEnd: nil
        )
        _ = driver.observe(.sessionMissing(source: .proxy404))
        _ = driver.noteBackgroundRenewalTransientFailure()

        driver.noteBackgroundRenewalSucceeded()

        XCTAssertFalse(driver.context.backgroundRenewalInFlight)
        XCTAssertFalse(driver.context.freshRenewalInFlight)
        XCTAssertEqual(driver.context.backgroundRenewalTransientFailures, 0)
    }

    // MARK: - Visible server-outage recovery

    /// The visible recovery's single-flight is the policy's form of
    /// `activeServerOutageRecoverySessionId`, which the failure ladder and the
    /// end-of-file gate read and which `clearServerOutageRecoveryState()`
    /// cleared with the task that owned the wait. Left latched it would swallow
    /// every later error and re-entry for the rest of the load.
    func testClearingTheServerOutageRecoveryReleasesTheSingleFlight() {
        let driver = RecoveryDriver(route: .avPlayerNativeDirect)
        XCTAssertEqual(
            driver.observe(.sourceInterrupted(reason: .networkUnavailable)),
            .recoverFromServerOutage(reason: "network_unavailable")
        )
        XCTAssertNotNil(driver.context.serverOutageRecovery)
        // Single-flight while it is latched.
        XCTAssertNil(driver.observe(.sourceInterrupted(reason: .networkUnavailable)))

        driver.clearServerOutageRecovery()

        XCTAssertNil(driver.context.serverOutageRecovery)
        XCTAssertEqual(
            driver.observe(.sourceInterrupted(reason: .networkUnavailable)),
            .recoverFromServerOutage(reason: "network_unavailable")
        )
    }

    // MARK: - Adoption across an in-place replan

    /// The other releaser of an adopted `origin_outage` hold: the ride-through
    /// poll, which is view-model-scoped and survives an in-place replan exactly
    /// as legacy's `sourceOutageRideThroughTask` did (no load path cancels the
    /// `.sourceOutageRideThrough` key). Adoption carries the *original*
    /// ride-through start, so the replan neither restarts the 90 s budget nor
    /// rewinds the backoff — the escalation lands at the instant legacy's
    /// captured deadline did.
    func testAdoptedRideThroughKeepsItsBudgetAndStillEscalates() {
        let start = Date()
        let outgoing = RecoveryDriver(route: .avPlayerNativeDirect)
        XCTAssertEqual(
            outgoing.observe(.originOutage(active: true), now: start),
            .rideThroughOutage(probeAfter: .zero)
        )
        // The hold is the engine session's half of outage entry (it is what
        // `setExternalStallSuppression(true)` was), taken alongside the
        // observation.
        outgoing.setSuspended(true, reason: RecoveryDriver.originOutageSuspensionReason)

        let replacement = RecoveryDriver(route: .avPlayerNativeDirect)
        replacement.adoptSuspensions(outgoing.context.suspendedReasons)
        replacement.adoptOutageRideThrough(outgoing.context.outage)

        XCTAssertTrue(replacement.context.isRecoverySuspended)
        XCTAssertEqual(replacement.context.outage?.rideThroughStart, start)

        // Inside the budget the ride-through continues on the new driver.
        XCTAssertEqual(
            replacement.observe(
                .serverHealthProbe(ok: false),
                now: start.addingTimeInterval(10)
            ),
            .rideThroughOutage(
                probeAfter: .seconds(RecoveryPolicy.serverOutageRecoveryInitialDelay)
            )
        )

        // The budget is measured from the original start, not from the replan.
        XCTAssertEqual(
            replacement.observe(
                .serverHealthProbe(ok: false),
                now: start.addingTimeInterval(RecoveryPolicy.serverOutageRecoveryTimeout + 1)
            ),
            .recoverFromServerOutage(reason: "network_unavailable")
        )
        XCTAssertNil(replacement.context.outage)
    }
}
