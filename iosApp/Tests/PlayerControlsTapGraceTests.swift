import XCTest
@testable import Silo

@MainActor
final class PlayerControlsTapGraceTests: XCTestCase {
    /// A tap aimed at a button that lands on the background instead, right
    /// after the controls appear, must not take them away.
    func testTapJustAfterControlsAppearKeepsThem() {
        let model = PlayerViewModel()
        defer { model.cleanup() }

        model.toggleControls()
        XCTAssertTrue(model.showControls, "The first tap reveals the controls")

        model.toggleControls()
        XCTAssertTrue(model.showControls, "A tap right after the controls appear keeps them")
    }

    /// Once the grace has passed, a tap on the background hides the controls
    /// as it always has.
    func testTapAfterTheGraceHidesControls() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.controlsTapGrace = .milliseconds(50)

        model.toggleControls()
        try await Task.sleep(for: .milliseconds(200))
        model.toggleControls()

        XCTAssertFalse(model.showControls, "A tap after the grace hides the controls")
    }

    /// An open sheet or a scrub suspends the auto-hide. The kept tap must
    /// leave it suspended instead of starting a new countdown.
    func testKeptTapLeavesASuspendedAutoHideSuspended() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.isPlaying = true
        model.autoHideDelay = .milliseconds(20)

        model.toggleControls()
        model.pinControlsVisible()
        model.toggleControls()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.showControls, "The controls stay up while the auto-hide is suspended")
    }
}
