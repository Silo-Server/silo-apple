#if os(tvOS)
import XCTest
@testable import Silo

/// The flyout's alignment padding is derived from a measurement that the
/// padding itself moves by pixel rounding. Feeding sub-point jitter back into
/// the padding re-laid the cascade forever (main thread at 100 %, #1253).
final class TVCascadeFlyoutAlignmentTests: XCTestCase {
    func testKeepsTheSettledValueAcrossSubPointJitter() {
        let cases: [(String, CGFloat?, CGFloat?, CGFloat?)] = [
            ("first measurement is taken", nil, 65, 65),
            ("quarter-point rounding jitter is ignored", 65, 64.75, 65),
            ("jitter the other way is ignored", 64.75, 65, 64.75),
            ("a real layout change is taken", 65, 72, 72),
            ("a one-point change is taken", 65, 66, 66),
            ("a lost measurement keeps the last one", 65, nil, 65),
        ]
        for (name, settled, measured, expected) in cases {
            XCTAssertEqual(
                TVCascadeFlyoutAlignment.settledCenter(settled, measured: measured),
                expected,
                name
            )
        }
    }
}
#endif
