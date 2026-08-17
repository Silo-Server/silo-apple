import XCTest
@testable import Silo

/// Pins the two-scheme deep-link contract: `silo://` is what every builder
/// emits, `continuum://` stays accepted for the deprecation window.
final class SiloDeepLinkTests: XCTestCase {

    func testPreferredSchemeIsSilo() {
        XCTAssertEqual(SiloDeepLink.preferredScheme, "silo")
    }

    func testAcceptsBothSchemes() throws {
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "silo://item/movie-1"))))
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "continuum://item/movie-1"))))
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "silo://downloads"))))
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "continuum://downloads"))))
    }

    /// The system hands back whatever casing the sender used, so the check
    /// must be case-insensitive.
    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertTrue(SiloDeepLink.isSupported(scheme: "SILO"))
        XCTAssertTrue(SiloDeepLink.isSupported(scheme: "Continuum"))
    }

    func testRejectsOtherSchemes() throws {
        XCTAssertFalse(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "https://silo.example.test/item/movie-1"))))
        XCTAssertFalse(SiloDeepLink.isSupported(scheme: "jellyfin"))
        XCTAssertFalse(SiloDeepLink.isSupported(scheme: nil))
    }
}
