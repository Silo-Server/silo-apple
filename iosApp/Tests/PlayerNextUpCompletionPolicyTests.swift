import XCTest
@testable import Silo

final class PlayerNextUpCompletionPolicyTests: XCTestCase {
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

    /// A mid-episode HTTP reset still reports EOF, so the player latches
    /// `hasReachedEndOfFile` to stay paused. That latch must not finalize
    /// the item as watched — otherwise dismissing (or the 10s progress tick)
    /// overwrites the real resume point with duration.
    func testPrematureEndOfFilePreservesCurrentPosition() {
        let position = PlayerNextUpCompletionPolicy.progressPosition(
            isNextUpPresented: true,
            hasReachedEndOfFile: true,
            endedPrematurely: true,
            currentTime: 600,
            duration: 2_700,
            promptSeconds: 30
        )

        XCTAssertEqual(position, 600)
        XCTAssertFalse(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: true,
                hasReachedEndOfFile: true,
                endedPrematurely: true,
                currentTime: 600,
                duration: 2_700,
                promptSeconds: 30
            )
        )
    }

    func testPrematureEndDoesNotFinalizeEvenWhenDismissingThePlayer() {
        XCTAssertFalse(
            PlayerNextUpCompletionPolicy.shouldFinalizeAsCompleted(
                isNextUpPresented: false,
                hasReachedEndOfFile: true,
                endedPrematurely: true,
                currentTime: 600,
                duration: 2_700,
                promptSeconds: 30
            )
        )
    }
}
