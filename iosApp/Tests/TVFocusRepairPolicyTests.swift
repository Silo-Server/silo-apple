import XCTest
@testable import Silo

final class TVFocusRepairPolicyTests: XCTestCase {
    func testFirstRootRepairRearmsPageContent() {
        XCTAssertEqual(tvFocusRepairAction(attempt: 1, isShowingRoot: true), .contentHandoff)
    }

    /// The soft-lock this exists for: a root page whose whole content is an
    /// inert placeholder has no focus target, so re-arming content can never
    /// restore focus. Every later attempt has to reach the top menu instead.
    func testRepeatedRootRepairEscalatesToTopMenu() {
        XCTAssertEqual(tvFocusRepairAction(attempt: 2, isShowingRoot: true), .topMenu)
        XCTAssertEqual(tvFocusRepairAction(attempt: 3, isShowingRoot: true), .topMenu)
    }

    /// A pushed route has no top menu to hand focus to, so escalating there
    /// would pin nothing; the engine re-resolves from the window instead.
    func testPushedRouteAlwaysAsksTheEngineToReresolve() {
        for attempt in 1...3 {
            XCTAssertEqual(
                tvFocusRepairAction(attempt: attempt, isShowingRoot: false),
                .engineReresolve
            )
        }
    }
}
