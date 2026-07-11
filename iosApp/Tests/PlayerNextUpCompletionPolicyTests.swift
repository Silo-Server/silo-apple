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
}
