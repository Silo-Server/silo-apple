#if os(iOS)
import XCTest
@testable import Silo

final class PlayerBrightnessSessionTests: XCTestCase {
    func testEndWithoutApplyWritesNothing() {
        var session = PlayerBrightnessSession()

        XCTAssertNil(session.suspend())
        XCTAssertNil(session.resume(currentLevel: 0.7))
        XCTAssertNil(session.end())
    }

    func testEndRestoresLevelCapturedBeforeFirstApply() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.3, currentLevel: 0.8)
        session.recordApply(0.1, currentLevel: 0.3)

        XCTAssertEqual(session.end(), 0.8)
    }

    func testEndResetsSoNextApplyCapturesFreshOriginal() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.3, currentLevel: 0.8)
        _ = session.end()

        XCTAssertNil(session.end())

        session.recordApply(0.2, currentLevel: 0.6)
        XCTAssertEqual(session.end(), 0.6)
    }

    func testSuspendRestoresOriginalAndResumeReappliesPlayerLevel() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)

        XCTAssertEqual(session.suspend(), 0.8)
        XCTAssertEqual(session.resume(currentLevel: 0.81), 0.2)
        XCTAssertEqual(session.end(), 0.8)
    }

    // scenePhase goes .inactive then .background, so suspend runs twice.
    func testSuspendIsIdempotent() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)

        XCTAssertEqual(session.suspend(), 0.8)
        XCTAssertNil(session.suspend())
    }

    func testResumeEndsSessionWhenUserChangedBrightnessWhileAway() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)
        _ = session.suspend()

        XCTAssertNil(session.resume(currentLevel: 0.5))
        XCTAssertNil(session.end())
    }

    func testEndWhileSuspendedDoesNotWriteAgain() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)
        _ = session.suspend()

        XCTAssertNil(session.end())
        XCTAssertEqual(session, PlayerBrightnessSession())

        session.recordApply(0.4, currentLevel: 0.5)
        XCTAssertEqual(session.end(), 0.5)
    }

    func testResumeWithoutSuspendIsNoOp() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)

        XCTAssertNil(session.resume(currentLevel: 0.2))
        XCTAssertEqual(session.end(), 0.8)
    }

    func testApplyAfterSuspendKeepsOriginal() {
        var session = PlayerBrightnessSession()
        session.recordApply(0.2, currentLevel: 0.8)
        _ = session.suspend()

        session.recordApply(0.4, currentLevel: 0.8)

        XCTAssertEqual(session.end(), 0.8)
    }
}

/// Covers what the pure session cannot: which screen gets written, and when
/// its level is read.
@MainActor
final class PlayerScreenBrightnessTests: XCTestCase {
    @MainActor
    private final class FakeScreen: PlayerBrightnessScreen {
        var brightness: CGFloat { didSet { writes.append(brightness) } }
        private(set) var writes: [CGFloat] = []
        init(_ brightness: CGFloat) { self.brightness = brightness }
    }

    func testLifecycleWithoutGestureNeverWrites() {
        let screen = FakeScreen(0.7)
        let brightness = PlayerScreenBrightness { screen }

        XCTAssertEqual(brightness.currentLevel(), 0.7)
        brightness.suspend()
        brightness.resume()
        brightness.restore()

        XCTAssertEqual(screen.writes, [])
    }

    func testRestoreWritesLevelReadBeforeFirstDrag() {
        let screen = FakeScreen(0.8)
        let brightness = PlayerScreenBrightness { screen }

        brightness.apply(0.3)
        brightness.apply(0.1)
        brightness.restore()

        XCTAssertEqual(screen.writes, [0.3, 0.1, 0.8])
    }

    // At resign-active the foreground lookup finds nothing, and that is
    // exactly when the original has to go back.
    func testSuspendAndResumeWriteToRememberedScreen() {
        let screen = FakeScreen(0.8)
        var foreground: FakeScreen? = screen
        let brightness = PlayerScreenBrightness { foreground }

        brightness.apply(0.2)
        foreground = nil
        brightness.suspend()
        XCTAssertEqual(screen.brightness, 0.8)

        brightness.resume()
        XCTAssertEqual(screen.brightness, 0.2)

        brightness.restore()
        XCTAssertEqual(screen.writes, [0.2, 0.8, 0.2, 0.8])
    }

    func testUserChangeWhileAwayIsKeptOnDismiss() {
        let screen = FakeScreen(0.8)
        let brightness = PlayerScreenBrightness { screen }

        brightness.apply(0.2)
        brightness.suspend()
        screen.brightness = 0.5 // the user, in Control Center
        brightness.resume()
        brightness.restore()

        XCTAssertEqual(screen.writes, [0.2, 0.8, 0.5])
    }

    // An ended session forgets its screen, so the next drag saves a fresh
    // original on whichever screen is in front then.
    func testNextSessionResolvesScreenAfresh() {
        let first = FakeScreen(0.8)
        var foreground: FakeScreen? = first
        let brightness = PlayerScreenBrightness { foreground }

        // Ended by a brightness change while away.
        brightness.apply(0.2)
        brightness.suspend()
        first.brightness = 0.5
        brightness.resume()

        let second = FakeScreen(0.6)
        foreground = second
        brightness.apply(0.3)
        // Ended by dismissal.
        brightness.restore()

        let third = FakeScreen(0.4)
        foreground = third
        brightness.apply(0.1)
        brightness.restore()

        XCTAssertEqual(first.writes, [0.2, 0.8, 0.5])
        XCTAssertEqual(second.writes, [0.3, 0.6])
        XCTAssertEqual(third.writes, [0.1, 0.4])
    }
}
#endif
