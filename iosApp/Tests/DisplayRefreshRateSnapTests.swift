import XCTest
@testable import Silo

final class DisplayRefreshRateSnapTests: XCTestCase {

    func testExactStandardRatesSnapToThemselves() {
        for rate in [25.0, 29.97, 30.0, 48.0, 50.0, 59.94, 60.0] {
            XCTAssertEqual(DisplayRefreshRateSnap.snap(rate), rate)
        }
    }

    func testFilmCadenceWindowPrefers23976() {
        // Exact 24.0 included: panels accepting 24 universally accept
        // 23.976, and "24" probes are nearly always 24000/1001.
        XCTAssertEqual(DisplayRefreshRateSnap.snap(23.976), 23.976)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(24.0), 23.976)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(23.98), 23.976)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(23.5), 23.976)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(24.05), 23.976)
    }

    func testNearMissesSnapWithinTolerance() {
        XCTAssertEqual(DisplayRefreshRateSnap.snap(24.42), 24.0)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(29.5), 29.97)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(59.5), 59.94)
        XCTAssertEqual(DisplayRefreshRateSnap.snap(50.3), 50.0)
    }

    func testOffGridRatesReturnNil() {
        XCTAssertNil(DisplayRefreshRateSnap.snap(15.0))
        XCTAssertNil(DisplayRefreshRateSnap.snap(22.9))
        XCTAssertNil(DisplayRefreshRateSnap.snap(40.0))
        XCTAssertNil(DisplayRefreshRateSnap.snap(120.0))
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(DisplayRefreshRateSnap.snap(0))
        XCTAssertNil(DisplayRefreshRateSnap.snap(-24))
        XCTAssertNil(DisplayRefreshRateSnap.snap(.nan))
        XCTAssertNil(DisplayRefreshRateSnap.snap(.infinity))
    }

    func testSnapOrFilmDefaultFallsBackTo23976() {
        XCTAssertEqual(DisplayRefreshRateSnap.snapOrFilmDefault(0), 23.976, accuracy: 0.001)
        XCTAssertEqual(DisplayRefreshRateSnap.snapOrFilmDefault(40.0), 23.976, accuracy: 0.001)
        XCTAssertEqual(DisplayRefreshRateSnap.snapOrFilmDefault(59.94), 59.94, accuracy: 0.001)
    }
}
