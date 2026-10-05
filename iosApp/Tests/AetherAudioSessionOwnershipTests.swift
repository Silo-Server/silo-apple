import Foundation
import XCTest
@testable import Silo

/// The release gate a stopping player hands its engine. The engine calls it off the
/// main actor about half a second later, just before `setActive(false)`, so a player
/// opened in that window must make the earlier player's late release stand down.
///
/// The generation is process-wide, so each test compares gates against loads it makes
/// itself rather than against absolute values.
final class AetherAudioSessionOwnershipTests: XCTestCase {
    func testReleaseRunsWhenNoLoadFollowsTheStop() {
        AetherAudioSessionOwnership.takeSession()
        let gate = AetherAudioSessionOwnership.releaseGate()

        XCTAssertTrue(gate())
        XCTAssertTrue(gate(), "asking twice must not change the answer")
    }

    func testLoadAfterTheStopDropsTheEarlierRelease() {
        AetherAudioSessionOwnership.takeSession()
        let outgoing = AetherAudioSessionOwnership.releaseGate()

        AetherAudioSessionOwnership.takeSession()

        XCTAssertFalse(outgoing(), "the new player's load owns the session now")
        XCTAssertTrue(AetherAudioSessionOwnership.releaseGate()(),
                      "the new player's own stop can still release it")
    }

    /// A load that began before the stop is not the gate's concern; the activity probe
    /// in `canReleaseSharedSession(excluding:)` keeps that stop from opting in at all.
    /// Without it, an audiobook that loaded and stopped while a video played would
    /// leave the video's stop unable to release the session afterwards.
    func testLoadBeforeTheStopDoesNotBlockTheRelease() {
        AetherAudioSessionOwnership.takeSession()
        AetherAudioSessionOwnership.takeSession()
        let gate = AetherAudioSessionOwnership.releaseGate()

        XCTAssertTrue(gate())
    }

    func testGateAnswersOffTheMainActor() async {
        AetherAudioSessionOwnership.takeSession()
        let gate = AetherAudioSessionOwnership.releaseGate()

        let beforeLoad = await Task.detached { gate() }.value
        AetherAudioSessionOwnership.takeSession()
        let afterLoad = await Task.detached { gate() }.value

        XCTAssertTrue(beforeLoad)
        XCTAssertFalse(afterLoad)
    }

    /// A player opened and then abandoned before its load never took the
    /// session: the closing player's release still runs, and the abandoned
    /// player's own stop is free to release too.
    @MainActor
    func testPlayerAbandonedBeforeLoadDoesNotHoldTheSession() {
        let closing = AetherAudioSessionOwnership.Claim(isHoldingAudio: { false })
        AetherAudioSessionOwnership.takeSession()
        let closingGate = AetherAudioSessionOwnership.releaseGate()
        let abandoned = AetherAudioSessionOwnership.Claim(isHoldingAudio: { false })

        XCTAssertTrue(AetherAudioSessionOwnership.canReleaseSharedSession(excluding: closing))
        XCTAssertTrue(closingGate())
        XCTAssertTrue(AetherAudioSessionOwnership.canReleaseSharedSession(excluding: abandoned))
    }

    /// An audiobook that starts and stops while a video plays leaves the
    /// session to the video, whose own stop then releases it.
    @MainActor
    func testAudiobookDuringVideoLeavesTheReleaseToTheVideo() {
        let videoAudio = HoldingAudio(true)
        let audiobookAudio = HoldingAudio(false)
        let video = AetherAudioSessionOwnership.Claim(isHoldingAudio: { videoAudio.value })
        let audiobook = AetherAudioSessionOwnership.Claim(isHoldingAudio: { audiobookAudio.value })
        AetherAudioSessionOwnership.takeSession()

        audiobookAudio.value = true
        AetherAudioSessionOwnership.takeSession()
        audiobookAudio.value = false
        XCTAssertFalse(AetherAudioSessionOwnership.canReleaseSharedSession(excluding: audiobook),
                       "the audiobook's stop must leave the video's session alone")

        videoAudio.value = false
        XCTAssertTrue(AetherAudioSessionOwnership.canReleaseSharedSession(excluding: video))
        XCTAssertTrue(AetherAudioSessionOwnership.releaseGate()())
    }
}

@MainActor
private final class HoldingAudio {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
