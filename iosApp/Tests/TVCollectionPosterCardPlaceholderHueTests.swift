import XCTest
@testable import Silo

// TVCollectionPosterCard is tvOS-only, so SiloTests compiles this file empty
// and SiloTVTests runs it.
#if os(tvOS)
final class TVCollectionPosterCardPlaceholderHueTests: XCTestCase {
    private func hue(_ id: String) -> Double {
        TVCollectionPosterCard.placeholderHue(forCollectionId: id)
    }

    /// Pinned FNV-1a 64 values (mod 360). A per-process-seeded hash such as
    /// `Hasher` can't reproduce these, so this test is the cross-launch contract.
    func testKnownIdsMapToPinnedHues() {
        XCTAssertEqual(hue(""), 77.0 / 360.0, accuracy: 1e-12)
        XCTAssertEqual(hue("a"), 196.0 / 360.0, accuracy: 1e-12)
        XCTAssertEqual(hue("c1"), 137.0 / 360.0, accuracy: 1e-12)
        XCTAssertEqual(hue("c2"), 224.0 / 360.0, accuracy: 1e-12)
        // NFC "Café" (UTF-8 43 61 66 C3 A9). Keep the escape: an NFD literal
        // has different UTF-8 bytes and hashes to a different hue.
        XCTAssertEqual(hue("Caf\u{E9}"), 105.0 / 360.0, accuracy: 1e-12)
    }

    func testHueIsDeterministicAcrossCalls() {
        let first = hue("c1")
        XCTAssertEqual(hue("c1"), first)
        XCTAssertEqual(hue(String(["c", "1"])), first)
    }

    func testHueStaysInUnitRange() {
        var ids = (0..<100).map { "c\($0)" }
        ids.append("")
        ids.append(String(repeating: "\u{03A9}\u{6620}\u{753B}\u{1F3AC} collection ", count: 64))

        for id in ids {
            let value = hue(id)
            XCTAssertGreaterThanOrEqual(value, 0, "id: \(id)")
            XCTAssertLessThan(value, 1, "id: \(id)")
        }
    }

    func testDistinctIdsSpreadAcrossHues() {
        let hues = Set((0..<100).map { hue("c\($0)") })
        XCTAssertGreaterThanOrEqual(hues.count, 80)
    }
}
#endif
