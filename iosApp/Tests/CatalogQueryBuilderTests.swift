import XCTest
@testable import Silo

/// Verifies the exact catalog wire format produced by `CatalogQueryBuilder`
/// against what `silo-server/internal/catalog/catalog_parser.go` parses.
/// This is the one place a silent mismatch would produce "green build, wrong
/// server results", so it gets focused coverage.
final class CatalogQueryBuilderTests: XCTestCase {

    private func build(_ state: CatalogFilterState,
                       libraryId: Int? = 1,
                       mediaType: BrowseMediaType = .movie,
                       includeType: Bool = false) -> [String: String] {
        CatalogQueryBuilder.build(state, libraryId: libraryId, mediaType: mediaType,
                                  offset: 0, limit: 60, includeType: includeType)
    }

    func testDefaultStateBaseParams() {
        let q = build(.none, libraryId: 5)
        XCTAssertEqual(q["source"], "query")
        XCTAssertEqual(q["sort"], "title")
        XCTAssertEqual(q["order"], "asc")
        XCTAssertEqual(q["match"], "all")
        XCTAssertEqual(q["library_id"], "5")
        XCTAssertEqual(q["offset"], "0")
        XCTAssertEqual(q["limit"], "60")
        XCTAssertNil(q["type"], "iOS omits the media-scope param")
        XCTAssertNil(q["groups[0][match]"], "no facets → no groups")
    }

    func testAddedAtSortFixesPhantom() {
        var s = CatalogFilterState(); s.sort = .addedAt
        let q = build(s)
        XCTAssertEqual(q["sort"], "added_at", "must be canonical, not the old 'added' phantom")
        XCTAssertEqual(q["order"], "desc", "added_at default order")
    }

    func testSortOrderFlip() {
        var s = CatalogFilterState(); s.sort = .title; s.order = .desc
        XCTAssertEqual(build(s)["order"], "desc")
    }

    func testTypeParamGatedByIncludeType() {
        XCTAssertEqual(build(.none, mediaType: .series, includeType: true)["type"], "series")
        XCTAssertNil(build(.none, mediaType: .audiobook, includeType: true)["type"],
                     "audiobook scope omits type even when requested")
        XCTAssertNil(build(.none, mediaType: .series, includeType: false)["type"])
    }

    func testMixedLibraryTypeScope() {
        XCTAssertNil(build(.none, mediaType: .mixed, includeType: true)["type"],
                     "mixed browses merged — no library-derived scope")

        // The user-chosen Type facet always scopes, even when includeType is
        // false (the iOS path), and wins over the library-derived scope.
        var s = CatalogFilterState(); s.mediaScope = "series"
        XCTAssertEqual(build(s, mediaType: .mixed, includeType: false)["type"], "series")
        XCTAssertEqual(build(s, mediaType: .mixed, includeType: true)["type"], "series")
        XCTAssertNil(build(s, mediaType: .mixed)["groups[0][match]"],
                     "media scope is a query param, not a rule group")
    }

    func testMultiGenreBecomesOneAnyGroup() {
        var s = CatalogFilterState(); s.genres = ["Drama", "Action"]
        let q = build(s)
        XCTAssertEqual(q["groups[0][match]"], "any")
        XCTAssertEqual(q["groups[0][rules][0][field]"], "genre")
        XCTAssertEqual(q["groups[0][rules][0][op]"], "contains")
        // Values are emitted sorted for a stable key.
        XCTAssertEqual(q["groups[0][rules][0][value]"], "Action")
        XCTAssertEqual(q["groups[0][rules][1][value]"], "Drama")
    }

    func testDecadeLowersToYearBetween() {
        var s = CatalogFilterState(); s.decades = [2010]
        let q = build(s)
        XCTAssertEqual(q["groups[0][rules][0][field]"], "year")
        XCTAssertEqual(q["groups[0][rules][0][op]"], "between")
        XCTAssertEqual(q["groups[0][rules][0][value][0]"], "2010")
        XCTAssertEqual(q["groups[0][rules][0][value][1]"], "2019")
    }

    func testWatchStatusUnwatchedIsWatchedFalse() {
        var s = CatalogFilterState(); s.watchStatus = .unwatched
        let q = build(s)
        XCTAssertEqual(q["groups[0][rules][0][field]"], "watched")
        XCTAssertEqual(q["groups[0][rules][0][op]"], "is")
        XCTAssertEqual(q["groups[0][rules][0][value]"], "false")
    }

    func testHDRBooleanRule() {
        var s = CatalogFilterState(); s.hdr = true
        let q = build(s)
        XCTAssertEqual(q["groups[0][rules][0][field]"], "hdr")
        XCTAssertEqual(q["groups[0][rules][0][op]"], "is")
        XCTAssertEqual(q["groups[0][rules][0][value]"], "true")
    }

    func testDynamicRangeValuesShareOneAnyGroup() {
        var s = CatalogFilterState()
        s.hdr = true
        s.dolbyVision = true

        let q = build(s)
        XCTAssertEqual(q["groups[0][match]"], "any")
        XCTAssertEqual(q["groups[0][rules][0][field]"], "hdr")
        XCTAssertEqual(q["groups[0][rules][0][op]"], "is")
        XCTAssertEqual(q["groups[0][rules][0][value]"], "true")
        XCTAssertEqual(q["groups[0][rules][1][field]"], "dolby_vision")
        XCTAssertEqual(q["groups[0][rules][1][op]"], "is")
        XCTAssertEqual(q["groups[0][rules][1][value]"], "true")
        XCTAssertNil(q["groups[1][match]"])
    }

    func testMatchAnyTopLevel() {
        var s = CatalogFilterState(); s.matchAll = false
        XCTAssertEqual(build(s)["match"], "any")
    }

    func testIncludeTotalFalseEmitsFlag() {
        let q = CatalogQueryBuilder.build(.none, libraryId: 1, mediaType: .movie,
                                          offset: 0, limit: 1, includeTotal: false, includeType: false)
        XCTAssertEqual(q["include_total"], "false")
    }

    func testCacheKeyFragmentIsSetOrderIndependent() {
        var a = CatalogFilterState(); a.genres = ["Drama", "Action"]; a.decades = [2010]
        var b = CatalogFilterState(); b.genres = ["Action", "Drama"]; b.decades = [2010]
        XCTAssertEqual(a.cacheKeyFragment, b.cacheKeyFragment)
    }

    func testCacheKeyFragmentEscapesValueDelimiters() {
        var grouped = CatalogFilterState(); grouped.genres = ["A,B"]
        var split = CatalogFilterState(); split.genres = ["A", "B"]
        XCTAssertNotEqual(grouped.cacheKeyFragment, split.cacheKeyFragment)

        var piped = CatalogFilterState(); piped.namePrefix = "A|B"
        var plain = CatalogFilterState(); plain.namePrefix = "A"; plain.genres = ["B"]
        XCTAssertNotEqual(piped.cacheKeyFragment, plain.cacheKeyFragment)
    }

    func testResetFiltersPreservesSortOrderAndPrefix() {
        var s = CatalogFilterState()
        s.sort = .addedAt
        s.order = .asc
        s.namePrefix = "M"
        s.genres = ["Drama"]
        s.hdr = true
        s.matchAll = false

        s.resetFilters()

        XCTAssertEqual(s.sort, .addedAt)
        XCTAssertEqual(s.order, .asc)
        XCTAssertEqual(s.namePrefix, "M")
        XCTAssertTrue(s.genres.isEmpty)
        XCTAssertFalse(s.hdr)
        XCTAssertTrue(s.matchAll)
    }
}
