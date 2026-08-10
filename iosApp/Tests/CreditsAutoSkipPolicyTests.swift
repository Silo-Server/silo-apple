import XCTest
@testable import Silo

final class CreditsAutoSkipPolicyTests: XCTestCase {
    private let credits = TimeRange(start: 1_500, end: 1_790)

    func testFirstEligibleVisitSeeksToTheCreditsEnd() {
        XCTAssertEqual(
            CreditsAutoSkipPolicy.target(
                enabled: true,
                playbackEligible: true,
                time: 1_500,
                range: credits,
                markerKey: "session:file:credits:1500:1790",
                lastSkippedKey: nil
            ),
            1_790
        )
    }

    func testSettingAndPlaybackStateGateTheSkip() {
        XCTAssertNil(target(enabled: false, playbackEligible: true, time: 1_600))
        XCTAssertNil(target(enabled: true, playbackEligible: false, time: 1_600))
    }

    func testOnlyTimesInsideTheHalfOpenCreditsRangeSkip() {
        XCTAssertNil(target(time: 1_499.999))
        XCTAssertEqual(target(time: 1_500), 1_790)
        XCTAssertEqual(target(time: 1_789.999), 1_790)
        XCTAssertNil(target(time: 1_790))
    }

    func testTheSameSessionFileAndMarkerSkipsOnlyOnce() {
        let key = "session:file:credits:1500:1790"
        XCTAssertNil(
            CreditsAutoSkipPolicy.target(
                enabled: true,
                playbackEligible: true,
                time: 1_600,
                range: credits,
                markerKey: key,
                lastSkippedKey: key
            )
        )
        XCTAssertEqual(
            CreditsAutoSkipPolicy.target(
                enabled: true,
                playbackEligible: true,
                time: 1_600,
                range: credits,
                markerKey: key + ":updated",
                lastSkippedKey: key
            ),
            1_790,
            "an updated marker is a new server-authored skip opportunity"
        )
    }

    func testMissingIdentityAndMalformedRangesNeverSeek() {
        XCTAssertNil(target(time: 1_600, markerKey: nil))
        XCTAssertNil(target(time: .nan))
        XCTAssertNil(target(time: 1_600, range: TimeRange(start: 1_790, end: 1_500)))
        XCTAssertNil(target(time: 1_600, range: TimeRange(start: -1, end: 1_790)))
    }

    private func target(
        enabled: Bool = true,
        playbackEligible: Bool = true,
        time: Double,
        range: TimeRange? = nil,
        markerKey: String? = "session:file:credits:1500:1790"
    ) -> Double? {
        CreditsAutoSkipPolicy.target(
            enabled: enabled,
            playbackEligible: playbackEligible,
            time: time,
            range: range ?? credits,
            markerKey: markerKey,
            lastSkippedKey: nil
        )
    }
}
