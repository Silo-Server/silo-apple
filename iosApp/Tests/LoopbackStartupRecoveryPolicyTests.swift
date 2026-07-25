import AVFoundation
import XCTest
@testable import Silo

final class LoopbackStartupRecoveryPolicyTests: XCTestCase {
    private func transportContext(
        _ status: AVPlayer.TimeControlStatus,
        isUserPaused: Bool = false,
        systemControlsAreActive: Bool = true,
        isInitialObservation: Bool = false,
        hasStartedPlayback: Bool = true,
        isSeekInFlight: Bool = false,
        isBufferStarved: Bool = false,
        hasReachedEnd: Bool = false
    ) -> AVPlayerSystemTransportIntent.Context {
        .init(
            timeControlStatus: status,
            isUserPaused: isUserPaused,
            systemControlsAreActive: systemControlsAreActive,
            isInitialObservation: isInitialObservation,
            hasStartedPlayback: hasStartedPlayback,
            isSeekInFlight: isSeekInFlight,
            isBufferStarved: isBufferStarved,
            hasReachedEnd: hasReachedEnd
        )
    }

    func testSystemTransportChangesReconcileOnlyWhenIntentDiffers() {
        XCTAssertEqual(
            AVPlayerSystemTransportIntent.resolve(transportContext(.paused)),
            .pause
        )
        XCTAssertEqual(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.playing, isUserPaused: true)
            ),
            .play
        )
        XCTAssertEqual(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.waitingToPlayAtSpecifiedRate, isUserPaused: true)
            ),
            .play
        )
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, isUserPaused: true)
            )
        )
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.waitingToPlayAtSpecifiedRate)
            )
        )
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, systemControlsAreActive: false)
            )
        )
    }

    /// The player is paused at every one of these moments for reasons that
    /// have nothing to do with the receiver or the PiP window. Reading any of
    /// them as a pause command latches `isUserPaused`, and every loopback
    /// stall-recovery path is gated on `!isUserPaused`.
    func testPlayerOwnPauseTransitionsAreNotTransportCommands() {
        // `.initial` KVO delivery on a freshly attached item.
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, isInitialObservation: true, hasStartedPlayback: false)
            )
        )
        // Pre-roll: item attached, initial resume seek not issued yet.
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, hasStartedPlayback: false)
            )
        )
        // Mid-scrub.
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, isSeekInFlight: true)
            )
        )
        // Buffer underrun on the loopback route.
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, isBufferStarved: true)
            )
        )
        // End of file.
        XCTAssertNil(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.paused, hasReachedEnd: true)
            )
        )
    }

    func testResumeFromTheReceiverStillReconcilesAfterAStall() {
        XCTAssertEqual(
            AVPlayerSystemTransportIntent.resolve(
                transportContext(.playing, isUserPaused: true, isBufferStarved: true)
            ),
            .play
        )
    }

    func testAudioSessionActivationStateRejectsStaleCompletionAndDeactivates() {
        var state = AVPlayerAudioSessionActivationState()
        let first = state.beginActivation()
        let second = state.beginActivation()

        XCTAssertTrue(first.needsActivation)
        XCTAssertTrue(second.needsActivation)
        XCTAssertFalse(state.finishActivation(id: first.id, succeeded: true))
        XCTAssertTrue(state.finishActivation(id: second.id, succeeded: true))
        XCTAssertTrue(state.cancelAndDeactivate())
        XCTAssertFalse(state.isCurrent(id: second.id))
    }

    func testAudioSessionCoordinatorRunsBlockingOperationsOffMainThread() {
        let activationFinished = expectation(description: "activation finished")
        let deactivationFinished = expectation(description: "deactivation finished")
        var activationWasOffMain = false
        var deactivationWasOffMain = false
        let coordinator = AVPlayerAudioSessionCoordinator(
            workQueue: DispatchQueue(label: "test.audio-session.work"),
            callbackQueue: .main,
            activation: {
                activationWasOffMain = !Thread.isMainThread
            },
            deactivation: {
                deactivationWasOffMain = !Thread.isMainThread
                deactivationFinished.fulfill()
            }
        )

        coordinator.activate { error in
            XCTAssertNil(error)
            XCTAssertTrue(Thread.isMainThread)
            activationFinished.fulfill()
        }
        wait(for: [activationFinished], timeout: 2)
        coordinator.deactivate()
        wait(for: [deactivationFinished], timeout: 2)

        XCTAssertTrue(activationWasOffMain)
        XCTAssertTrue(deactivationWasOffMain)
    }

    func testItemDeathPolicyRequiresConfirmationAndCapsReloads() {
        var state = LoopbackItemDeathRecoveryState()
        XCTAssertEqual(
            state.record(position: 100, evidenceWeight: 1, userPaused: false),
            .waitForConfirmation
        )
        XCTAssertEqual(
            state.record(position: 100.5, evidenceWeight: 1, userPaused: false),
            .reload(attempt: 1)
        )
        XCTAssertEqual(
            state.record(position: 100.5, evidenceWeight: 2, userPaused: false),
            .escalate
        )
    }

    func testConfirmedItemDeathReloadsOnceThenEscalatesAtSamePosition() {
        var state = LoopbackItemDeathRecoveryState()
        XCTAssertEqual(
            state.confirm(position: 75.74, userPaused: false),
            .reload(attempt: 1)
        )
        XCTAssertEqual(
            state.confirm(position: 75.74, userPaused: false),
            .escalate
        )
    }

    func testItemDeathPolicyNeverReloadsUserPause() {
        var state = LoopbackItemDeathRecoveryState()
        XCTAssertEqual(
            state.record(position: 100, evidenceWeight: 2, userPaused: true),
            .waitForConfirmation
        )
    }

    func testItemDeathPolicyResetsAtDifferentPlaybackPosition() {
        var state = LoopbackItemDeathRecoveryState()
        XCTAssertEqual(
            state.record(position: 100, evidenceWeight: 2, userPaused: false),
            .reload(attempt: 1)
        )
        XCTAssertEqual(
            state.record(position: 110, evidenceWeight: 2, userPaused: false),
            .reload(attempt: 1)
        )
    }

    func testItemDeathSignatures() {
        XCTAssertTrue(
            LoopbackItemDeathRecoveryState.isItemDeath(
                statusCode: -12889,
                errorDescription: ""
            )
        )
        XCTAssertTrue(
            LoopbackItemDeathRecoveryState.isItemDeath(
                statusCode: nil,
                errorDescription: "No response for media file"
            )
        )
        XCTAssertFalse(
            LoopbackItemDeathRecoveryState.isItemDeath(
                statusCode: -12888,
                errorDescription: "Playlist File unchanged"
            )
        )
    }

    func testUnexpectedPauseReassertsPlayThenConfirmsAfterGracePeriod() {
        var state = LoopbackItemDeathConfirmationState()
        XCTAssertEqual(
            state.evaluate(
                now: 10,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .reassertPlay
        )
        XCTAssertEqual(
            state.evaluate(
                now: 12.9,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .none
        )
        XCTAssertEqual(
            state.evaluate(
                now: 13,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .confirmed(trigger: .unexpectedPause)
        )
    }

    func testUnexpectedPauseCandidateClearsWhenPlayResumes() {
        var state = LoopbackItemDeathConfirmationState()
        _ = state.evaluate(
            now: 10,
            position: 75.74,
            playbackEstablished: true,
            userPaused: false,
            transportState: .paused,
            recoverySuppressed: false,
            mediaAvailableAhead: true
        )
        XCTAssertEqual(
            state.evaluate(
                now: 11,
                position: 75.9,
                playbackEstablished: true,
                userPaused: false,
                transportState: .playing,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .none
        )
        XCTAssertEqual(
            state.evaluate(
                now: 15,
                position: 80,
                playbackEstablished: true,
                userPaused: false,
                transportState: .playing,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .none
        )
    }

    func testFailedToEndConfirmsOnlyWhenTransportRemainsDead() {
        var state = LoopbackItemDeathConfirmationState()
        state.noteExplicitFailure(
            position: 75.74,
            now: 10,
            playbackEstablished: true,
            userPaused: false
        )
        XCTAssertEqual(
            state.evaluate(
                now: 12.9,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .waiting,
                recoverySuppressed: false,
                mediaAvailableAhead: false
            ),
            .none
        )
        XCTAssertEqual(
            state.evaluate(
                now: 13,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .waiting,
                recoverySuppressed: false,
                mediaAvailableAhead: false
            ),
            .confirmed(trigger: .failedToEnd)
        )
    }

    func testFailedToEndCandidateClearsOnProgress() {
        var state = LoopbackItemDeathConfirmationState()
        state.noteExplicitFailure(
            position: 75.74,
            now: 10,
            playbackEstablished: true,
            userPaused: false
        )
        XCTAssertEqual(
            state.evaluate(
                now: 13,
                position: 76.3,
                playbackEstablished: true,
                userPaused: false,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .none
        )
    }

    func testUserPauseAndUnavailableMediaDoNotStartRecovery() {
        var state = LoopbackItemDeathConfirmationState()
        XCTAssertEqual(
            state.evaluate(
                now: 10,
                position: 75.74,
                playbackEstablished: true,
                userPaused: true,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: true
            ),
            .none
        )
        XCTAssertEqual(
            state.evaluate(
                now: 11,
                position: 75.74,
                playbackEstablished: true,
                userPaused: false,
                transportState: .paused,
                recoverySuppressed: false,
                mediaAvailableAhead: false
            ),
            .none
        )
    }

    private func verdict(
        sinceProgress: Double,
        sinceStart: Double,
        displaySwitching: Bool = false
    ) -> LoopbackStartupRecoveryPolicy.Verdict {
        LoopbackStartupRecoveryPolicy.verdict(
            secondsSinceProgress: sinceProgress,
            secondsSinceStart: sinceStart,
            displayModeSwitchInProgress: displaySwitching,
            stallWindow: 6.0,
            absoluteBackstop: 60.0
        )
    }

    func testFreshProgressWaits() {
        XCTAssertEqual(verdict(sinceProgress: 0.5, sinceStart: 10), .wait)
        XCTAssertEqual(verdict(sinceProgress: 5.9, sinceStart: 30), .wait)
    }

    func testFrozenFetchesEscalate() {
        XCTAssertEqual(verdict(sinceProgress: 6.0, sinceStart: 10), .escalate)
        XCTAssertEqual(verdict(sinceProgress: 20.0, sinceStart: 30), .escalate)
    }

    func testSlowButFetchingConsumerNeverEscalates() {
        // The living-room DV P7 + TrueHD failure: 12+ seconds elapsed but
        // segment GETs flowing every 1-2 s. Progress stays fresh, so the
        // ladder must hold no matter how long startup takes (short of the
        // backstop).
        for elapsed in stride(from: 1.0, through: 59.0, by: 1.0) {
            XCTAssertEqual(verdict(sinceProgress: 1.2, sinceStart: elapsed), .wait)
        }
    }

    func testDisplayModeSwitchHoldsTheLadder() {
        XCTAssertEqual(
            verdict(sinceProgress: 30.0, sinceStart: 30, displaySwitching: true),
            .wait
        )
    }

    func testAbsoluteBackstopFailsEvenWithProgress() {
        XCTAssertEqual(verdict(sinceProgress: 0.1, sinceStart: 60.0), .failBackstop)
        XCTAssertEqual(verdict(sinceProgress: 0.1, sinceStart: 120.0), .failBackstop)
    }

    func testBackstopWinsOverDisplaySwitchHold() {
        XCTAssertEqual(
            verdict(sinceProgress: 0.1, sinceStart: 60.0, displaySwitching: true),
            .failBackstop
        )
    }
}
