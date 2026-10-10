import XCTest
@testable import Silo

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
}
