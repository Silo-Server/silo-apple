import XCTest
@testable import Silo

final class TVTopMenuCloseRepinTests: XCTestCase {
    private let closedAt = ContinuousClock.now

    func testFocusDropRightAfterTheCloseIsRepinned() {
        var repin = TVTopMenuCloseRepin()
        repin.arm(now: closedAt)
        XCTAssertTrue(repin.consume(now: closedAt + .milliseconds(16)))
    }

    /// Down from Home after a sideways move had closed a preview used to be
    /// pulled back to the tab, however long ago the preview closed.
    func testLeavingTheBarLaterIsNotPulledBack() {
        var repin = TVTopMenuCloseRepin()
        repin.arm(now: closedAt)
        XCTAssertFalse(repin.consume(now: closedAt + .seconds(1)))
    }

    func testOneCloseRepinsOnlyOneDrop() {
        var repin = TVTopMenuCloseRepin()
        repin.arm(now: closedAt)
        XCTAssertTrue(repin.consume(now: closedAt + .milliseconds(16)))
        XCTAssertFalse(repin.consume(now: closedAt + .milliseconds(32)))
    }

    func testFocusLandingOnATabCancelsTheRepin() {
        var repin = TVTopMenuCloseRepin()
        repin.arm(now: closedAt)
        repin.cancel()
        XCTAssertFalse(repin.consume(now: closedAt + .milliseconds(16)))
    }
}
