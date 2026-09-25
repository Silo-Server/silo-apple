#if os(iOS) || os(tvOS)
import AppIntents
import XCTest
@testable import Silo

/// Siri's in-app search reaches Search through a `silo://search` link, so a
/// term has to survive the URL round trip unchanged.
@MainActor
final class SiriIntentTests: XCTestCase {
    func testTermSurvivesLinkRoundTrip() throws {
        for term in ["The Office", "Tom & Jerry", "50% off?", "Amélie", "a+b=c #1"] {
            let url = try XCTUnwrap(SiriSearchLink.url(term: term))
            XCTAssertEqual(url.scheme, "silo")
            XCTAssertEqual(SiriSearchLink.term(from: url), term, "\(url)")
        }
    }

    func testTermIsTrimmedAndBlankOpensEmptySearch() throws {
        XCTAssertEqual(SiriSearchLink.term(from: try XCTUnwrap(URL(string: "silo://search?q=%20Dune%0A"))), "Dune")
        XCTAssertEqual(SiriSearchLink.term(from: try XCTUnwrap(URL(string: "silo://search"))), "")
        XCTAssertEqual(SiriSearchLink.term(from: try XCTUnwrap(URL(string: "continuum://search?q=Dune"))), "Dune")
    }

    func testOtherLinksAreNotSearchLinks() throws {
        XCTAssertNil(SiriSearchLink.term(from: try XCTUnwrap(URL(string: "silo://item/abc?q=Dune"))))
        XCTAssertNil(SiriSearchLink.term(from: try XCTUnwrap(URL(string: "https://search?q=Dune"))))
    }

    func testIntentHandsTermToDeepLinkInbox() async throws {
        let coordinator = SiloDeepLinkCoordinator.shared
        _ = coordinator.consumePendingURL()
        defer { _ = coordinator.consumePendingURL() }

        let intent = SearchInSiloIntent()
        intent.criteria = StringSearchCriteria(term: "Blade Runner")
        _ = try await intent.perform()

        let url = try XCTUnwrap(coordinator.consumePendingURL())
        XCTAssertEqual(SiriSearchLink.term(from: url), "Blade Runner")
    }
}
#endif
