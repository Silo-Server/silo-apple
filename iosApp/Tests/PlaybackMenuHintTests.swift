#if os(tvOS)
import XCTest
@testable import Silo

/// "Press down to open Playback Menu": once per item, for five seconds, while
/// playback runs with the controls hidden, and gone for the item once the
/// viewer brings up the controls or the menu.
@MainActor
final class PlaybackMenuHintTests: XCTestCase {
    private let playingWithControlsHidden = PlaybackMenuHint.Conditions(
        isPlaybackOnScreen: true,
        isPlaying: true
    )

    func testShowsOnceForFiveSeconds() {
        let (hint, clock) = makeHint()
        hint.update(playingWithControlsHidden)
        XCTAssertTrue(hint.isVisible)

        clock.advance(by: PlaybackMenuHint.visibleSeconds - 0.1)
        XCTAssertTrue(hint.isVisible)
        clock.advance(by: 0.2)
        XCTAssertFalse(hint.isVisible)

        // A pause and resume, a seek or a replan of the same item.
        hint.update(PlaybackMenuHint.Conditions(isPlaybackOnScreen: true, isPlaying: false))
        hint.update(playingWithControlsHidden)
        XCTAssertFalse(hint.isVisible)
    }

    func testTheControlsOrTheMenuEndItForTheItem() {
        let (hint, _) = makeHint()
        hint.update(playingWithControlsHidden)
        var controlsUp = playingWithControlsHidden
        controlsUp.areControlsUp = true

        hint.update(controlsUp)
        XCTAssertFalse(hint.isVisible)

        hint.update(playingWithControlsHidden)
        XCTAssertFalse(hint.isVisible)
    }

    /// A viewer who finds the controls before the hint could show never gets
    /// it later in the item.
    func testControlsBeforeTheHintPassItOver() {
        let (hint, _) = makeHint()
        var controlsUp = playingWithControlsHidden
        controlsUp.areControlsUp = true

        hint.update(controlsUp)
        hint.update(playingWithControlsHidden)

        XCTAssertFalse(hint.isVisible)
    }

    func testWaitsForPlaybackAndForANoticeToClear() {
        let (hint, _) = makeHint()
        hint.update(PlaybackMenuHint.Conditions(isPlaybackOnScreen: false, isPlaying: true))
        XCTAssertFalse(hint.isVisible)

        var notice = playingWithControlsHidden
        notice.isSlotTaken = true
        hint.update(notice)
        XCTAssertFalse(hint.isVisible)

        hint.update(playingWithControlsHidden)
        XCTAssertTrue(hint.isVisible)
    }

    func testTheNextItemShowsItAgain() {
        let (hint, clock) = makeHint()
        hint.update(playingWithControlsHidden)
        clock.advance(by: PlaybackMenuHint.visibleSeconds)
        XCTAssertFalse(hint.isVisible)

        hint.reset()
        hint.update(playingWithControlsHidden)

        XCTAssertTrue(hint.isVisible)
    }

    private func makeHint() -> (PlaybackMenuHint, ManualIntroSkipClock) {
        let clock = ManualIntroSkipClock()
        return (PlaybackMenuHint(clock: clock), clock)
    }
}
#endif
