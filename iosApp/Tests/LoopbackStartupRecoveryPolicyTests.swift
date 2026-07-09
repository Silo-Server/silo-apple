import XCTest
@testable import Silo

final class LoopbackStartupRecoveryPolicyTests: XCTestCase {
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
            .reload(attempt: 2)
        )
        XCTAssertEqual(
            state.record(position: 100.5, evidenceWeight: 2, userPaused: false),
            .reload(attempt: 3)
        )
        XCTAssertEqual(
            state.record(position: 100.5, evidenceWeight: 2, userPaused: false),
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
