#if os(iOS)
import XCTest
@testable import Silo

/// Headers fold only on iPhone and iPad.
@MainActor
final class PageChromeScrollStateTests: XCTestCase {
    /// Folding shortens the header by about 30 pt, which lowers the measured
    /// offset by as much; the header must stay folded until the page is back
    /// near the top.
    func testFoldedHeaderStaysFoldedWhenFoldingMovesTheOffset() {
        let state = PageChromeScrollState()

        state.update(50)
        XCTAssertTrue(state.isCompact)

        state.update(50 - 30)
        XCTAssertTrue(state.isCompact)

        state.update(2)
        XCTAssertFalse(state.isCompact)
    }

    func testUnfoldedHeaderStaysUnfoldedWhenUnfoldingMovesTheOffset() {
        let state = PageChromeScrollState()

        state.update(2 + 30)

        XCTAssertFalse(state.isCompact)
    }

    /// At large text sizes folding can take more than the 40 pt gap off the
    /// header. The fold that reveals it can't stick, but the header then
    /// folds further down, where the loss can't bring it back to the top.
    func testHeaderThatLosesMoreThanTheGapFoldsFurtherDown() {
        let state = PageChromeScrollState()

        state.update(44, topInset: 120)
        XCTAssertTrue(state.isCompact)
        state.update(0, topInset: 60)
        XCTAssertFalse(state.isCompact)

        // Unfolding gives the height back without the page moving.
        state.update(60, topInset: 120)
        XCTAssertFalse(state.isCompact)

        state.update(72, topInset: 120)
        XCTAssertTrue(state.isCompact)
        state.update(12, topInset: 60)
        XCTAssertTrue(state.isCompact)

        state.update(2, topInset: 60)
        XCTAssertFalse(state.isCompact)
    }
}
#endif
