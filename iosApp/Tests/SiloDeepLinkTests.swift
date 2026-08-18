import XCTest
@testable import Silo

/// Pins the single-scheme deep-link contract: `silo://` is what every builder
/// emits and the only scheme either Info.plist registers.
final class SiloDeepLinkTests: XCTestCase {

    func testPreferredSchemeIsSilo() {
        XCTAssertEqual(SiloDeepLink.preferredScheme, "silo")
    }

    func testAcceptsOnlySiloScheme() throws {
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "silo://item/movie-1"))))
        XCTAssertTrue(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "silo://downloads"))))
        XCTAssertEqual(SiloDeepLink.acceptedSchemes, ["silo"])
    }

    /// The system hands back whatever casing the sender used, so the check
    /// must be case-insensitive.
    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertTrue(SiloDeepLink.isSupported(scheme: "SILO"))
        XCTAssertTrue(SiloDeepLink.isSupported(scheme: "Silo"))
    }

    /// The pre-rename scheme is no longer registered in either Info.plist, so
    /// it must not be routed if something hands one to the app anyway.
    func testRejectsPreRenameScheme() throws {
        XCTAssertFalse(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "continuum://item/movie-1"))))
        XCTAssertFalse(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "continuum://downloads"))))
        XCTAssertFalse(SiloDeepLink.isSupported(scheme: "Continuum"))
    }

    func testRejectsOtherSchemes() throws {
        XCTAssertFalse(SiloDeepLink.isSupported(try XCTUnwrap(URL(string: "https://silo.example.test/item/movie-1"))))
        XCTAssertFalse(SiloDeepLink.isSupported(scheme: "jellyfin"))
        XCTAssertFalse(SiloDeepLink.isSupported(scheme: nil))
    }
}
