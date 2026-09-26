import XCTest
@testable import Silo

/// Pins the registry contract that a final teardown relies on when it decides
/// whether to release the shared `AVAudioSession`: only another claim that is
/// actually holding audio blocks release. The audiobook stop and video teardown
/// both call `canReleaseSharedSession(excluding:)` with their own claim.
///
/// The registry is process-global, so every claim lives in a local and
/// unregisters when its test returns. Claims the assertion depends on are kept
/// alive with `withExtendedLifetime`; a claim Swift releases early would turn a
/// blocking claim into no claim at all.
@MainActor
final class AetherAudioSessionOwnershipTests: XCTestCase {
    private typealias Ownership = AetherAudioSessionOwnership
    private typealias Claim = AetherAudioSessionOwnership.Claim

    /// An audiobook stopping while an idle video controller is alive: the idle
    /// claim must not keep another app's audio paused or ducked.
    func testIdleOtherClaimDoesNotBlockRelease() {
        let own = Claim(isHoldingAudio: { true })
        let other = Claim(isHoldingAudio: { false })

        withExtendedLifetime(other) {
            XCTAssertTrue(Ownership.canReleaseSharedSession(excluding: own))
        }
    }

    /// A playing or paused video keeps its session.
    func testActiveOtherClaimBlocksRelease() {
        let own = Claim(isHoldingAudio: { false })
        let other = Claim(isHoldingAudio: { true })

        withExtendedLifetime(other) {
            XCTAssertFalse(Ownership.canReleaseSharedSession(excluding: own))
        }
    }

    /// A claim without a probe cannot be interrogated and counts as active.
    func testProbelessOtherClaimBlocksRelease() {
        let own = Claim(isHoldingAudio: { false })
        let other = Claim()

        withExtendedLifetime(other) {
            XCTAssertFalse(Ownership.canReleaseSharedSession(excluding: own))
        }
    }

    /// A final teardown gives up the caller's own audio, so its own active claim
    /// never blocks it.
    func testOwnActiveClaimIsExcluded() {
        let own = Claim(isHoldingAudio: { true })

        XCTAssertTrue(Ownership.canReleaseSharedSession(excluding: own))
    }

    /// Deallocating a claim unregisters it.
    func testReleasedClaimStopsBlocking() {
        let own = Claim(isHoldingAudio: { false })
        var other: Claim? = Claim(isHoldingAudio: { true })

        withExtendedLifetime(other) {
            XCTAssertFalse(Ownership.canReleaseSharedSession(excluding: own))
        }

        other = nil
        XCTAssertNil(other)
        XCTAssertTrue(Ownership.canReleaseSharedSession(excluding: own))
    }

    /// Probes are evaluated on each call, which is why teardown decides per stop.
    func testProbeIsReadAtCallTime() {
        let own = Claim(isHoldingAudio: { false })
        let flag = ActivityFlag()
        flag.isHolding = true
        let other = Claim(isHoldingAudio: { flag.isHolding })

        withExtendedLifetime(other) {
            XCTAssertFalse(Ownership.canReleaseSharedSession(excluding: own))
            flag.isHolding = false
            XCTAssertTrue(Ownership.canReleaseSharedSession(excluding: own))
        }
    }
}

@MainActor
private final class ActivityFlag {
    var isHolding = false
}
