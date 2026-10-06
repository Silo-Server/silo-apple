#if os(iOS)
import XCTest
@testable import Silo

/// The iPhone Duo's open display in portrait is 669 x 951pt; half-folded, its
/// fold runs across the middle.
final class PlayerTabletopLayoutTests: XCTestCase {
    private let portrait = CGRect(x: 0, y: 0, width: 669, height: 951)
    private let fold = CGRect(x: 0, y: 470, width: 669, height: 11)

    func testFoldAcrossTheScreenSplitsVideoAboveControls() throws {
        let layout = try XCTUnwrap(PlayerTabletopLayout(bounds: portrait, fold: fold, isActive: true))
        XCTAssertEqual(layout.videoMaxY, fold.minY - PlayerTabletopLayout.foldClearance)
        XCTAssertEqual(layout.controlsMinY, fold.maxY + PlayerTabletopLayout.foldClearance)
    }

    /// A flexible display can report its crease with no height; the panes
    /// still stay clear of it.
    func testZeroHeightFoldKeepsClearance() throws {
        let crease = CGRect(x: 0, y: 475, width: 669, height: 0)
        let layout = try XCTUnwrap(PlayerTabletopLayout(bounds: portrait, fold: crease, isActive: true))
        XCTAssertLessThan(layout.videoMaxY, crease.minY)
        XCTAssertGreaterThan(layout.controlsMinY, crease.maxY)
    }

    /// Flat open, or held as a book with the fold down the middle, the player
    /// keeps its full-screen layout.
    func testFlatOrBookPostureKeepsFullScreen() {
        XCTAssertNil(PlayerTabletopLayout(bounds: portrait, fold: fold, isActive: false))
        let landscape = CGRect(x: 0, y: 0, width: 951, height: 669)
        let bookFold = CGRect(x: 470, y: 0, width: 11, height: 669)
        XCTAssertNil(PlayerTabletopLayout(bounds: landscape, fold: bookFold, isActive: true))
    }

    /// A fold near an edge, or one that only crosses part of the player,
    /// leaves no useful pane on one side.
    func testFoldWithoutRoomForBothPanesKeepsFullScreen() {
        let nearTop = CGRect(x: 0, y: 120, width: 669, height: 11)
        XCTAssertNil(PlayerTabletopLayout(bounds: portrait, fold: nearTop, isActive: true))
        let partial = CGRect(x: 200, y: 470, width: 469, height: 11)
        XCTAssertNil(PlayerTabletopLayout(bounds: portrait, fold: partial, isActive: true))
    }
}
#endif
