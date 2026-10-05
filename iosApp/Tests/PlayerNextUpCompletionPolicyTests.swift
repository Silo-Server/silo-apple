import XCTest
@testable import Silo

final class PlayerNextUpCompletionPolicyTests: XCTestCase {
    func testAlreadyPlayingOrLoadingCandidateOnlyExpands() {
        XCTAssertEqual(
            PlayerNextUpPlaybackAction.resolve(candidateId: "episode-b", currentId: "episode-b"),
            .expand
        )
    }

    func testEarlyNextAndRepeatedCountdownProduceOneLoad() {
        var currentId = "episode-a"
        var loads = 0
        for _ in 0..<100 {
            switch PlayerNextUpPlaybackAction.resolve(candidateId: "episode-b", currentId: currentId) {
            case .load(let id):
                loads += 1
                // beginFreshLoad sets lastLoadRequest synchronously, before awaits.
                currentId = id
            case .expand, .unavailable, .waitForPicture:
                break
            }
        }
        XCTAssertEqual(loads, 1)
    }

    func testMissingCandidateDoesNotReloadCurrentEpisode() {
        XCTAssertEqual(
            PlayerNextUpPlaybackAction.resolve(candidateId: nil, currentId: "episode-a"),
            .unavailable
        )
    }

    func testEarlyRepeatedPlayNowWaitsForTheSuccessorsPicture() {
        for candidate in ["episode-b", "episode-c", nil] {
            XCTAssertEqual(
                PlayerNextUpPlaybackAction.resolve(
                    candidateId: candidate, currentId: "episode-b", awaitingPicture: true
                ),
                .waitForPicture
            )
        }
        XCTAssertEqual(
            PlayerNextUpPlaybackAction.resolve(candidateId: "episode-b", currentId: "episode-b"),
            .expand
        )
    }

    func testEarlyManualPresentationPreservesCurrentPosition() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: false,
            currentTime: 300,
            duration: 3_600,
            promptSeconds: 30
        )

        XCTAssertEqual(position, 300)
    }

    func testPresentationInsidePromptWindowFinalizesAtDuration() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: false,
            currentTime: 3_575,
            duration: 3_600,
            promptSeconds: 30
        )

        XCTAssertEqual(position, 3_600)
    }

    func testNaturalEndOfFileFinalizesWithThePromptDisabled() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: false,
            hasReachedEndOfFile: true,
            currentTime: 3_594,
            duration: 3_600,
            promptSeconds: 0
        )

        XCTAssertEqual(position, 3_600)
    }

    /// A dropped connection ends the stream early. Leaving from the
    /// connection-lost postroll must keep the resume point, not mark watched.
    func testPrematureEndOfFileKeepsTheResumePoint() {
        XCTAssertFalse(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: true,
                hasReachedEndOfFile: true,
                currentTime: 1_200,
                duration: 3_600,
                promptSeconds: 30
            )
        )
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: true,
            currentTime: 1_200,
            duration: 3_600,
            promptSeconds: 30
        )
        XCTAssertEqual(position, 1_200)
    }

    /// The lost-source postroll shows Next Up, so a drop inside the prompt
    /// window must not count as reaching the prompt.
    func testPrematureEndOfFileInsideThePromptWindowKeepsTheResumePoint() {
        XCTAssertFalse(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: true,
                hasReachedEndOfFile: true,
                currentTime: 175,
                duration: 200,
                promptSeconds: 30
            )
        )
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: true,
            currentTime: 175,
            duration: 200,
            promptSeconds: 30
        )
        XCTAssertEqual(position, 175)
    }

    /// A late reopen that ends again at once resolves to a finish, and the
    /// end-of-playback path moves the playhead to the duration before
    /// anything reads completion.
    func testLateStalledReopenFinishStillFinalizes() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_580, duration: 3_600, skippedCredits: false), .reopen)
        XCTAssertEqual(budget.resolveEnd(position: 3_580, duration: 3_600, skippedCredits: false), .finish)
        XCTAssertTrue(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: true,
                hasReachedEndOfFile: true,
                currentTime: 3_600,
                duration: 3_600,
                promptSeconds: 30
            )
        )
    }

    func testEndOfFileStillFinalizesAfterSkippingCreditsToTheEnd() {
        XCTAssertTrue(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: false,
                hasReachedEndOfFile: true,
                currentTime: 3_300,
                duration: 3_600,
                promptSeconds: 30,
                skippedCredits: true
            )
        )
    }

    /// Offline playback can end before the duration resolves; nothing then
    /// shows the end was early.
    func testEndOfFileWithUnknownDurationFinalizes() {
        XCTAssertTrue(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: false,
                hasReachedEndOfFile: true,
                currentTime: 1_200,
                duration: 0,
                promptSeconds: 30
            )
        )
    }

    func testOnlyAnEndNearTheDurationIsAFinish() {
        XCTAssertTrue(PlayerEndOfFilePolicy.isFinish(position: 3_600, duration: 3_600))
        XCTAssertTrue(PlayerEndOfFilePolicy.isFinish(position: 3_593, duration: 3_600))
        // 98.6% through a long film is still minutes of credits short.
        XCTAssertFalse(PlayerEndOfFilePolicy.isFinish(position: 3_550, duration: 3_600))
        XCTAssertFalse(PlayerEndOfFilePolicy.isFinish(position: 1_200, duration: 3_600))
    }

    /// A playback error in the last seconds is the stream running out, and
    /// leaving afterwards finishes the item.
    func testNearEndPlaybackErrorStillCountsAsFinished() {
        XCTAssertTrue(PlayerEndOfFilePolicy.treatsPlaybackErrorAsEnd(position: 3_595, duration: 3_600))
        XCTAssertTrue(PlayerEndOfFilePolicy.isFinish(position: 3_595, duration: 3_600))
        XCTAssertTrue(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: true,
                hasReachedEndOfFile: true,
                currentTime: 3_600,
                duration: 3_600,
                promptSeconds: 30
            )
        )
    }

    /// An error in the last 1.5% but well before the end takes the
    /// end-of-file path, where it is a premature end that gets reopened.
    func testLateButNotFinalPlaybackErrorIsAPrematureEnd() {
        XCTAssertTrue(PlayerEndOfFilePolicy.treatsPlaybackErrorAsEnd(position: 3_550, duration: 3_600))
        XCTAssertFalse(PlayerEndOfFilePolicy.isFinish(position: 3_550, duration: 3_600))
        XCTAssertFalse(PlayerEndOfFilePolicy.treatsPlaybackErrorAsEnd(position: 1_200, duration: 3_600))
        // An unknown duration cannot place an error near the end.
        XCTAssertFalse(PlayerEndOfFilePolicy.treatsPlaybackErrorAsEnd(position: 1_200, duration: 0))
    }

    func testFirstPrematureEndReopensOnce() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertTrue(budget.claimReopen())
        // The reopened stream ended again straight away: a truncated file.
        budget.notePlayhead(from: 1_200, to: 1_201)
        XCTAssertFalse(budget.claimReopen())
    }

    func testAnotherReopenNeedsThirtySecondsOfPlayback() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertTrue(budget.claimReopen())
        var position = 1_200.0
        for _ in 0..<58 {
            budget.notePlayhead(from: position, to: position + 0.5)
            position += 0.5
        }
        XCTAssertFalse(budget.claimReopen())
        budget.notePlayhead(from: position, to: position + 1)
        XCTAssertTrue(budget.claimReopen())
        XCTAssertFalse(budget.claimReopen())
    }

    func testSeeksAndPlaybackBeforeTheFirstReopenDoNotCount() {
        var budget = PlayerPrematureEndReopenBudget()
        budget.notePlayhead(from: 0, to: 4)
        XCTAssertTrue(budget.claimReopen())
        budget.notePlayhead(from: 1_200, to: 2_400)
        budget.notePlayhead(from: 2_400, to: 600)
        XCTAssertFalse(budget.claimReopen())
    }

    func testEndInsideTheFinishWindowFinishesWithoutUsingTheReopen() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_595, duration: 3_600, skippedCredits: false), .finish)
        XCTAssertEqual(budget.resolveEnd(position: 1_200, duration: 3_600, skippedCredits: false), .reopen)
    }

    /// The stored duration runs 20 s past the last packet. The first end looks
    /// premature; the reopen ends again at once, so that is the real end.
    func testReopenThatEndsAgainAtOnceLateInTheFileFinishes() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_580, duration: 3_600, skippedCredits: false), .reopen)
        budget.notePlayhead(from: 3_576, to: 3_580)
        XCTAssertEqual(budget.resolveEnd(position: 3_580, duration: 3_600, skippedCredits: false), .finish)
    }

    /// The viewer skipped credits that run to the end, so a source that drops
    /// in them has nothing left to reopen for.
    func testEndAfterSkippingCreditsToTheEndFinishes() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_300, duration: 3_600, skippedCredits: true), .finish)
        XCTAssertEqual(budget.resolveEnd(position: 3_300, duration: 3_600, skippedCredits: false), .reopen)
    }

    /// A drop 90 s before the end of a long film must not finish it.
    func testReopenThatEndsAgainAtOnceEarlierInTheFileLosesTheSource() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_510, duration: 3_600, skippedCredits: false), .reopen)
        XCTAssertEqual(budget.resolveEnd(position: 3_510, duration: 3_600, skippedCredits: false), .lostSource)
    }

    /// A reopen that played on before dropping again found a live but flaky
    /// connection, not the end of the file.
    func testReopenThatPlayedBeforeEndingAgainLosesTheSource() {
        var budget = PlayerPrematureEndReopenBudget()
        XCTAssertEqual(budget.resolveEnd(position: 3_550, duration: 3_600, skippedCredits: false), .reopen)
        var position = 3_550.0
        for _ in 0..<12 {
            budget.notePlayhead(from: position, to: position + 1)
            position += 1
        }
        XCTAssertEqual(budget.resolveEnd(position: position, duration: 3_600, skippedCredits: false), .lostSource)
    }

    func testSkippedCreditsFinalizeAtDurationWhileCreditsStillPlay() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: false,
            currentTime: 3_300,
            duration: 3_600,
            promptSeconds: 30,
            skippedCredits: true
        )

        XCTAssertEqual(position, 3_600)
    }

    func testKeepWatchingAfterSkippedCreditsStillFinalizes() {
        XCTAssertTrue(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: false,
                hasReachedEndOfFile: false,
                currentTime: 3_300,
                duration: 3_600,
                promptSeconds: 30,
                skippedCredits: true
            )
        )
    }

    func testHiddenNextUpDoesNotFinalizeInsidePromptWindow() {
        XCTAssertFalse(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: false,
                hasReachedEndOfFile: false,
                currentTime: 3_575,
                duration: 3_600,
                promptSeconds: 30
            )
        )
    }
}
