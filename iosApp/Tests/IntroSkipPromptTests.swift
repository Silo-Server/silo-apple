import XCTest
@testable import Silo

/// The conformance suite for the intro-skip pill.
///
/// The oracle is the `never` / `ask` / `always` tables in the server repo's
/// `docs/design/2026-08-16-intro-skip-mode.md` ("Prompt behaviour"). The same
/// tables drive web and Android (`IntroAutoSkipControllerTest` there), so a
/// divergence should fail here rather than arrive as a bug report.
@MainActor
final class IntroSkipPromptTests: XCTestCase {
    private let intro = TimeRange(start: 30, end: 90)
    private let key = "content-1:7:30.0:90.0"

    private var clock: ManualIntroSkipClock!
    private var prompt: IntroSkipPrompt!
    private var inputs: IntroSkipPrompt.Inputs!
    /// Positions the prompt asked the player to seek to on its own.
    private var automaticSeeks: [Double] = []

    private func start(_ mode: IntroSkipMode, duration: TimeInterval = 5) {
        clock = ManualIntroSkipClock()
        prompt = IntroSkipPrompt(clock: clock, duration: duration)
        inputs = .init(position: 0, range: intro, key: key, mode: mode, activity: .playing)
        automaticSeeks = []
        drive()
    }

    /// Feeds the current inputs, performing an automatic seek the way the
    /// player does — which moves the position, exactly what the undo pill
    /// has to survive.
    private func drive() {
        if let target = prompt.update(inputs) {
            automaticSeeks.append(target)
            inputs.position = target
            drive()
        }
    }

    private func move(to position: Double) {
        inputs.position = position
        drive()
    }

    private func set(_ activity: IntroSkipPrompt.Activity) {
        inputs.activity = activity
        drive()
    }

    private var kind: IntroSkipPrompt.Kind? { prompt.pill?.kind }

    private func remaining() -> TimeInterval? {
        guard let pill = prompt.pill else { return nil }
        return pill.deadline.map { $0.timeIntervalSince(clock.now) } ?? pill.remaining
    }

    // MARK: - never

    func testNeverEnteringAnIntroDoesNothingAtAll() {
        start(.never)
        move(to: 35)
        XCTAssertNil(prompt.pill)
        clock.advance(by: 10)
        XCTAssertNil(prompt.pill)
        XCTAssertTrue(automaticSeeks.isEmpty)
    }

    // MARK: - ask

    func testAskEnteringAnIntroOffersSkipWithAFullTimer() {
        start(.ask)
        XCTAssertNil(prompt.pill)
        move(to: 35)
        XCTAssertEqual(kind, .skip)
        XCTAssertEqual(remaining(), 5)
        clock.advance(by: 2)
        XCTAssertEqual(remaining(), 3)
        XCTAssertTrue(automaticSeeks.isEmpty, "ask never seeks on its own")
    }

    func testAskTimeoutHidesThePillWithoutResolvingTheIntro() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 5)
        XCTAssertNil(prompt.pill)
        XCTAssertTrue(automaticSeeks.isEmpty, "the intro keeps playing")

        // Still inside the same intro: the offer withdrew and must not return.
        move(to: 40)
        XCTAssertNil(prompt.pill)

        // Scrubbing out and back in re-offers, from a full timer.
        move(to: 95)
        move(to: 32)
        XCTAssertEqual(kind, .skip)
        XCTAssertEqual(remaining(), 5)
    }

    func testAskSelectSeeksToTheEndAndNeverOffersAgain() {
        start(.ask)
        move(to: 35)
        XCTAssertEqual(prompt.select(), intro.end)
        XCTAssertNil(prompt.pill)

        move(to: intro.end)
        move(to: 40)
        XCTAssertNil(prompt.pill, "a resolved intro never offers again")
        clock.advance(by: 10)
        XCTAssertTrue(automaticSeeks.isEmpty, "the viewer's skip is returned, never performed here")
    }

    func testAskBackDismissesResolvesAndIsConsumedOnlyOnce() {
        start(.ask)
        move(to: 35)
        XCTAssertTrue(prompt.dismiss(), "the first Back belongs to the pill")
        XCTAssertNil(prompt.pill)
        XCTAssertFalse(prompt.dismiss(), "a second Back belongs to the player")

        move(to: 40)
        move(to: 95)
        move(to: 35)
        XCTAssertNil(prompt.pill)
        XCTAssertTrue(automaticSeeks.isEmpty, "the intro keeps playing")
    }

    func testAskMovingFocusAwayLeavesTheTimerRunning() {
        // Focus is a view concern; the prompt only sees time pass.
        start(.ask)
        move(to: 35)
        clock.advance(by: 4.9)
        XCTAssertEqual(kind, .skip)
        clock.advance(by: 0.1)
        XCTAssertNil(prompt.pill)
    }

    func testAskPauseFreezesTheTimerAndPlayResumesFromTheSameValue() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 2)

        set(.paused)
        XCTAssertEqual(kind, .skip, "the pill stays visible")
        XCTAssertNil(prompt.pill?.deadline)
        XCTAssertEqual(remaining(), 3)
        clock.advance(by: 30)
        XCTAssertEqual(remaining(), 3, "a frozen timer does not run down")

        set(.playing)
        XCTAssertEqual(remaining(), 3)
        clock.advance(by: 2.9)
        XCTAssertEqual(kind, .skip)
        clock.advance(by: 0.1)
        XCTAssertNil(prompt.pill)
    }

    func testAskStallShorterThanTheGraceWindowDoesNotTouchTheTimer() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 1)
        set(.stalled)
        clock.advance(by: 1)
        set(.playing)
        XCTAssertEqual(remaining(), 3, "a rebuffer does not pause the countdown")
        clock.advance(by: 3)
        XCTAssertNil(prompt.pill)
    }

    func testAskStallThatOutlastsTheCountdownExpiresOnResume() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 4)
        set(.stalled)
        clock.advance(by: 1.4)
        XCTAssertEqual(kind, .skip, "a stall never runs the pill out while the picture is frozen")
        set(.playing)
        XCTAssertNil(prompt.pill, "the original deadline has passed")
    }

    func testAskStallLongerThanTheGraceWindowFreezesAtTheStallEdge() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 1)
        set(.stalled)
        clock.advance(by: IntroSkipPrompt.pauseGraceSeconds)
        XCTAssertNil(prompt.pill?.deadline, "a long stall is a pause")
        XCTAssertEqual(remaining(), 4, "counted from when playback stopped")
        clock.advance(by: 20)
        set(.playing)
        XCTAssertEqual(remaining(), 4)
    }

    func testAskTheTimerDoesNotStartUntilPlaybackIsRunning() {
        start(.ask)
        set(.stalled)
        move(to: 35)
        XCTAssertNil(prompt.pill, "the pill and its fill start together, once playback is up")
        clock.advance(by: 10)
        XCTAssertNil(prompt.pill)
        set(.playing)
        XCTAssertEqual(kind, .skip)
        XCTAssertEqual(remaining(), 5)
    }

    func testAskSeekingOutHidesThePillWithoutResolvingIt() {
        start(.ask)
        move(to: 35)
        clock.advance(by: 2)
        move(to: 120)
        XCTAssertNil(prompt.pill)
        clock.advance(by: 10)

        move(to: 35)
        XCTAssertEqual(kind, .skip, "not resolved: seeking back in offers again")
        XCTAssertEqual(remaining(), 5, "from a full timer")
    }

    func testAskADifferentIntroGetsItsOwnOffer() {
        start(.ask)
        move(to: 35)
        prompt.dismiss()
        inputs.key = "content-1:8:30.0:90.0"
        drive()
        XCTAssertEqual(kind, .skip)
    }

    func testWithoutAnIntroKeyNothingIsOffered() {
        start(.ask)
        inputs.key = nil
        move(to: 35)
        XCTAssertNil(prompt.pill)
        XCTAssertTrue(automaticSeeks.isEmpty)
    }

    // MARK: - always

    func testAlwaysSkipsImmediatelyAndOffersTheUndo() {
        start(.always)
        move(to: 35)
        XCTAssertEqual(automaticSeeks, [intro.end])
        XCTAssertEqual(kind, .undo)
        XCTAssertEqual(remaining(), 5)
    }

    func testAlwaysTheUndoIsAnchoredToTheIntroNotThePosition() {
        start(.always)
        move(to: 35)
        move(to: 95)
        move(to: 140)
        XCTAssertEqual(kind, .undo, "position changes must not take the undo down")
        clock.advance(by: 1)
        XCTAssertEqual(remaining(), 4)
    }

    func testAlwaysTimeoutResolvesTheIntro() {
        start(.always)
        move(to: 35)
        clock.advance(by: 5)
        XCTAssertNil(prompt.pill)

        move(to: 35)
        clock.advance(by: 10)
        XCTAssertNil(prompt.pill)
        XCTAssertEqual(automaticSeeks, [intro.end], "scrubbing back in does not skip again")
    }

    func testAlwaysSelectSeeksBackToTheStartAndDoesNotSkipAgain() {
        start(.always)
        move(to: 35)
        XCTAssertEqual(prompt.select(), intro.start, "the undo plays the intro")
        XCTAssertNil(prompt.pill)

        move(to: intro.start)
        move(to: 45)
        clock.advance(by: 10)
        XCTAssertNil(prompt.pill)
        XCTAssertEqual(automaticSeeks, [intro.end], "the intro is resolved, so it plays through")
    }

    func testAlwaysBackResolvesAndPlaybackContinuesPastTheIntro() {
        start(.always)
        move(to: 35)
        XCTAssertTrue(prompt.dismiss())
        XCTAssertNil(prompt.pill)
        XCTAssertFalse(prompt.dismiss())

        move(to: 35)
        clock.advance(by: 10)
        XCTAssertEqual(automaticSeeks, [intro.end])
    }

    func testAlwaysPauseFreezesTheUndoTimer() {
        start(.always)
        move(to: 35)
        clock.advance(by: 2)
        set(.paused)
        clock.advance(by: 10)
        XCTAssertEqual(remaining(), 3)
        set(.playing)
        clock.advance(by: 1)
        XCTAssertEqual(remaining(), 2)
    }

    func testAlwaysAReloadThatLandsShortOfTheEndDoesNotSkipAgain() {
        // A seek that needs a stream reload can land on a segment boundary a
        // little before the target. The skip already resolved the intro, so
        // this must not read as a fresh intro and loop.
        start(.always)
        move(to: 35)
        prompt.dismiss()
        move(to: 88.5)
        clock.advance(by: 10)
        XCTAssertEqual(automaticSeeks, [intro.end])
        XCTAssertNil(prompt.pill)
    }

    func testAlwaysTheUndoSurvivesMarkersBrieflyGoingMissing() {
        start(.always)
        move(to: 35)
        inputs.range = nil
        inputs.key = nil
        drive()
        XCTAssertEqual(kind, .undo)
        XCTAssertEqual(prompt.select(), intro.start, "the undo still knows the intro it skipped")
    }

    // MARK: - Failed reloads

    func testAlwaysAFailedReloadWithdrawsTheFrozenUndoWithoutSkippingAgain() {
        start(.always)
        move(to: 35)
        // The reload drops the markers and stalls past the grace window,
        // which freezes the undo's timer, then fails.
        inputs.range = nil
        inputs.key = nil
        set(.stalled)
        clock.advance(by: 2)
        XCTAssertEqual(kind, .undo)
        XCTAssertNil(prompt.pill?.deadline)

        prompt.withdraw()
        XCTAssertNil(prompt.pill)
        XCTAssertFalse(prompt.dismiss(), "Back after the failure must reach the player")
        XCTAssertNil(prompt.select())

        // A retry that lands short of the end is still not a fresh intro.
        inputs.range = intro
        inputs.key = key
        inputs.position = 88.5
        set(.playing)
        XCTAssertEqual(automaticSeeks, [intro.end])
        XCTAssertNil(prompt.pill)
    }

    func testAskAWithdrawnOfferReturnsWhenPlaybackComesBackIntoTheIntro() {
        start(.ask)
        move(to: 35)
        prompt.withdraw()
        XCTAssertNil(prompt.pill)

        // Nothing is offered while playback is down.
        set(.paused)
        XCTAssertNil(prompt.pill)

        // Withdrawing decided nothing, so a retry back inside the intro
        // offers it again with a full timer.
        set(.playing)
        XCTAssertEqual(kind, .skip)
        XCTAssertEqual(remaining(), 5)
    }

    // MARK: - Mode changes and reset

    func testAskToNeverMidIntroTakesThePillDown() {
        start(.ask)
        move(to: 35)
        inputs.mode = .never
        drive()
        XCTAssertNil(prompt.pill)
        clock.advance(by: 10)
        XCTAssertTrue(automaticSeeks.isEmpty)
    }

    func testNeverToAskMidIntroOffersThePill() {
        start(.never)
        move(to: 35)
        inputs.mode = .ask
        drive()
        XCTAssertEqual(kind, .skip)
    }

    func testAskToAlwaysMidIntroSkipsThereAndThen() {
        start(.ask)
        move(to: 35)
        inputs.mode = .always
        drive()
        XCTAssertEqual(automaticSeeks, [intro.end])
        XCTAssertEqual(kind, .undo)
    }

    func testResetClearsDecisionsForNewContent() {
        start(.ask)
        move(to: 35)
        prompt.dismiss()
        prompt.reset()
        move(to: 5)
        move(to: 40)
        XCTAssertEqual(kind, .skip)
    }

    func testSelectAndDismissAreNoOpsWithoutAPill() {
        start(.ask)
        XCTAssertNil(prompt.select())
        XCTAssertFalse(prompt.dismiss())
    }

    // MARK: - Fill

    func testTheFillTracksTheSameClockAsTheTimer() throws {
        start(.ask)
        move(to: 35)
        let pill = try XCTUnwrap(prompt.pill)
        XCTAssertEqual(pill.progress(at: clock.now), 0, accuracy: 0.0001)
        XCTAssertEqual(pill.progress(at: clock.now.addingTimeInterval(2.5)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(pill.progress(at: clock.now.addingTimeInterval(5)), 1, accuracy: 0.0001)

        clock.advance(by: 1)
        set(.paused)
        let frozen = try XCTUnwrap(prompt.pill)
        XCTAssertEqual(frozen.progress(at: clock.now.addingTimeInterval(60)), 0.2, accuracy: 0.0001,
                       "a frozen fill holds still")
    }

    // MARK: - Settings mapping

    func testModeWireAndLegacyMapping() {
        XCTAssertEqual(IntroSkipMode(wireValue: "never"), .never)
        XCTAssertEqual(IntroSkipMode(wireValue: "ask"), .ask)
        XCTAssertEqual(IntroSkipMode(wireValue: "always"), .always)
        XCTAssertNil(IntroSkipMode(wireValue: "sometimes"))
        XCTAssertNil(IntroSkipMode(wireValue: nil))
        XCTAssertEqual(IntroSkipMode(legacyAutoSkip: true), .always)
        XCTAssertEqual(IntroSkipMode(legacyAutoSkip: false), .ask)
        XCTAssertEqual(IntroSkipMode.default, .ask)
        XCTAssertEqual(IntroSkipMode.allCases.map(\.label), ["Never", "Ask to skip", "Skip automatically"])
    }
}

/// A clock the test advances by hand. Due timers fire in deadline order.
@MainActor
final class ManualIntroSkipClock: IntroSkipPromptClock {
    private final class Timer: IntroSkipPromptTimer {
        let fireAt: Date
        let action: @MainActor () -> Void
        var cancelled = false

        init(fireAt: Date, action: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private(set) var now = Date(timeIntervalSinceReferenceDate: 0)
    private var timers: [Timer] = []

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> IntroSkipPromptTimer {
        let timer = Timer(fireAt: now.addingTimeInterval(max(0, delay)), action: action)
        timers.append(timer)
        return timer
    }

    func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        while let next = timers
            .filter({ !$0.cancelled && $0.fireAt <= target })
            .min(by: { $0.fireAt < $1.fireAt }) {
            now = max(now, next.fireAt)
            next.cancelled = true
            next.action()
        }
        timers.removeAll { $0.cancelled }
        now = target
    }
}
