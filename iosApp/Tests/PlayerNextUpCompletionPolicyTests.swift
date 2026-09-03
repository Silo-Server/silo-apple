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
            case .expand, .unavailable:
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

    func testEndOfFileFinalizesEvenOutsidePromptWindow() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: true,
            currentTime: 300,
            duration: 3_600,
            promptSeconds: 30
        )

        XCTAssertEqual(position, 3_600)
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
