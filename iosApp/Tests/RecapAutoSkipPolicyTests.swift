import XCTest
@testable import Silo

/// `playback.auto_skip_recap` jumps past a recap on its own, once, and only
/// for a viewer playing alone whose load has shown its first frame.
final class RecapAutoSkipPolicyTests: XCTestCase {
    private let recap = TimeRange(start: 0, end: 45)
    private let key = "session:42:recap:0.0:45.0"

    func testStartedSoloPlaybackSkipsToTheRecapEnd() {
        XCTAssertEqual(target(time: 0), 45)
        XCTAssertEqual(target(time: 44.9), 45)
        XCTAssertNil(target(time: 45), "past the recap there is nothing to skip")
    }

    func testTheSettingOffNeverSkips() {
        XCTAssertNil(target(enabled: false, time: 3))
    }

    func testNothingSkipsBeforeTheFirstFrame() {
        XCTAssertNil(target(playbackStarted: false, time: 0))
        XCTAssertNil(target(playbackEligible: false, time: 3), "loading or at end of file")
    }

    func testAWatchPartyKeepsTheButtonInsteadOfSkipping() {
        XCTAssertNil(target(isWatchParty: true, time: 3))
    }

    func testEachRecapSkipsOnlyOnce() {
        // Seeking back into a recap already skipped plays it.
        XCTAssertNil(target(time: 10, lastSkippedKey: key))
        XCTAssertEqual(
            target(time: 10, markerKey: "session:42:recap:0.0:50.0", lastSkippedKey: key),
            45,
            "an updated marker is a new recap"
        )
        XCTAssertNil(target(time: 10, markerKey: nil), "no playback identity, no latch, no skip")
    }

    private func target(
        enabled: Bool = true,
        isWatchParty: Bool = false,
        playbackStarted: Bool = true,
        playbackEligible: Bool = true,
        time: Double,
        markerKey: String? = "session:42:recap:0.0:45.0",
        lastSkippedKey: String? = nil
    ) -> Double? {
        RecapAutoSkipPolicy.target(
            enabled: enabled,
            isWatchParty: isWatchParty,
            playbackStarted: playbackStarted,
            playbackEligible: playbackEligible,
            time: time,
            range: recap,
            markerKey: markerKey,
            lastSkippedKey: lastSkippedKey
        )
    }
}
