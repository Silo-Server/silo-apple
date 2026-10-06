import XCTest
@testable import Silo

/// An empty browse grid must say whether the library is empty or the active
/// filters match nothing, and only the filtered case may ask the catalog.
final class BrowseEmptyReasonTests: XCTestCase {
    private struct ProbeFailure: Error {}

    private var genreFilter: CatalogFilterState {
        var state = CatalogFilterState()
        state.genres = ["Drama"]
        return state
    }

    func testUnfilteredEmptyPageIsAnEmptyLibraryWithoutAProbe() async {
        var probed = false
        var sortedOnly = CatalogFilterState()
        sortedOnly.sort = .addedAt
        sortedOnly.matchAll = false

        let reason = await BrowseEmptyReason.classify(filter: sortedOnly) {
            probed = true
            return true
        }

        XCTAssertEqual(reason, .libraryEmpty)
        XCTAssertFalse(probed, "sort and match mode alone never narrow the page")
    }

    func testFiltersOverALibraryWithItemsMatchNothing() async {
        let reason = await BrowseEmptyReason.classify(filter: genreFilter) { true }
        XCTAssertEqual(reason, .noFilterMatches)
    }

    /// Covers a profile whose rating limits hide every title: the probe runs
    /// as that profile and finds nothing, so the library reads as empty.
    func testFiltersOverALibraryWithNoVisibleItemsShowTheEmptyLibrary() async {
        let reason = await BrowseEmptyReason.classify(filter: genreFilter) { false }
        XCTAssertEqual(reason, .libraryEmpty)
    }

    func testFailedProbeKeepsTheFilterMessage() async {
        let reason = await BrowseEmptyReason.classify(filter: genreFilter) { throw ProbeFailure() }
        XCTAssertEqual(reason, .noFilterMatches)
    }

    func testNamePrefixCountsAsAFilter() async {
        var state = CatalogFilterState()
        state.namePrefix = "Q"
        let reason = await BrowseEmptyReason.classify(filter: state) { true }
        XCTAssertEqual(reason, .noFilterMatches)
    }

    func testLibraryProbeAsksForOneUnfilteredItem() throws {
        let parameters = try CatalogQueryBuilder.libraryProbe(libraryId: 2).getParameters()

        XCTAssertEqual(parameters["library_id"], "2")
        XCTAssertEqual(parameters["limit"], "1")
        XCTAssertEqual(parameters["skip_total"], "true")
        for key in ["groups", "name_prefix", "type", "q"] {
            XCTAssertNil(parameters[key], "\(key) would narrow the probe")
        }
    }
}
