import XCTest
@testable import Silo

final class DolbyVisionPolicyTests: XCTestCase {
    private let dvOn = DolbyVisionPolicy.Snapshot(
        dolbyVisionEnabled: true,
        preferProfile7HDR10Fallback: false
    )
    private let dvOnWithP7Fallback = DolbyVisionPolicy.Snapshot(
        dolbyVisionEnabled: true,
        preferProfile7HDR10Fallback: true
    )
    private let dvOff = DolbyVisionPolicy.Snapshot(
        dolbyVisionEnabled: false,
        preferProfile7HDR10Fallback: false
    )
    private let dvOffWithP7Fallback = DolbyVisionPolicy.Snapshot(
        dolbyVisionEnabled: false,
        preferProfile7HDR10Fallback: true
    )

    // MARK: - Profile 5 (no HDR10-compatible base layer)

    func testProfile5AlwaysResolvesToDolbyVision() {
        for snapshot in [dvOn, dvOnWithP7Fallback, dvOff, dvOffWithP7Fallback] {
            XCTAssertEqual(
                DolbyVisionPolicy.resolution(forProfile: 5, snapshot: snapshot),
                .dolbyVision
            )
        }
    }

    // MARK: - Profile 7 precedence

    func testProfile7PlaysDolbyVisionByDefault() {
        XCTAssertEqual(
            DolbyVisionPolicy.resolution(forProfile: 7, snapshot: dvOn),
            .dolbyVision
        )
    }

    func testProfile7HonorsFallbackToggleWhileDolbyVisionOn() {
        XCTAssertEqual(
            DolbyVisionPolicy.resolution(forProfile: 7, snapshot: dvOnWithP7Fallback),
            .profile7HDR10Fallback
        )
    }

    func testDolbyVisionOffSupersedesProfile7FallbackToggle() {
        // Both fallback-toggle states must collapse to the same disabled
        // resolution — DV off wins, the P7 toggle is moot.
        XCTAssertEqual(
            DolbyVisionPolicy.resolution(forProfile: 7, snapshot: dvOff),
            .dolbyVisionDisabled
        )
        XCTAssertEqual(
            DolbyVisionPolicy.resolution(forProfile: 7, snapshot: dvOffWithP7Fallback),
            .dolbyVisionDisabled
        )
    }

    // MARK: - Base-layer-compatible profiles

    func testCompatibleProfilesFollowTheSetting() {
        for profile in [4, 8, 9, 10] {
            XCTAssertEqual(
                DolbyVisionPolicy.resolution(forProfile: profile, snapshot: dvOn),
                .dolbyVision,
                "profile \(profile)"
            )
            XCTAssertEqual(
                DolbyVisionPolicy.resolution(forProfile: profile, snapshot: dvOff),
                .dolbyVisionDisabled,
                "profile \(profile)"
            )
        }
    }

    // MARK: - Claims

    func testOnlyDisabledResolutionClearsDolbyVisionClaim() {
        XCTAssertTrue(DolbyVisionPolicy.claimsDolbyVisionOutput(.dolbyVision))
        XCTAssertTrue(DolbyVisionPolicy.claimsDolbyVisionOutput(.profile7HDR10Fallback))
        XCTAssertFalse(DolbyVisionPolicy.claimsDolbyVisionOutput(.dolbyVisionDisabled))
    }
}
