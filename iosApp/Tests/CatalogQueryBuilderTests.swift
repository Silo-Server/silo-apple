import XCTest
@testable import Silo

/// Verifies the v2 catalog query `CatalogQueryBuilder` produces: the GET
/// parameters and the JSON rule groups the server's query executor reads.
/// A string where the server expects a boolean or a number fails the whole
/// query, so rule value types get focused coverage.
final class CatalogQueryBuilderTests: XCTestCase {

    private func build(_ state: CatalogFilterState,
                       libraryId: Int? = 1,
                       mediaType: BrowseMediaType = .movie,
                       includeType: Bool = false) throws -> [String: String] {
        try CatalogQueryBuilder.build(state, libraryId: libraryId, mediaType: mediaType,
                                      limit: 60, includeType: includeType).getParameters()
    }

    /// The `groups` parameter decoded back into JSON objects.
    private func groups(_ state: CatalogFilterState,
                        mediaType: BrowseMediaType = .movie) throws -> [[String: Any]] {
        let parameters = try build(state, mediaType: mediaType)
        let data = Data(try XCTUnwrap(parameters["groups"]).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func rules(_ group: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(group["rules"] as? [[String: Any]])
    }

    func testDefaultStateBaseParams() throws {
        let q = try build(.none, libraryId: 5)
        XCTAssertEqual(q["source"], "query")
        XCTAssertEqual(q["sort"], "title")
        XCTAssertEqual(q["match"], "all")
        XCTAssertEqual(q["library_id"], "5")
        XCTAssertEqual(q["limit"], "60")
        XCTAssertNil(q["type"], "iOS omits the media-scope param")
        XCTAssertNil(q["groups"], "no facets → no groups")
        for key in ["offset", "order", "snapshot_at", "include_total"] {
            XCTAssertNil(q[key], "\(key) is v1 paging")
        }
    }

    func testAddedAtSortIsSignedDescending() throws {
        var s = CatalogFilterState(); s.sort = .addedAt
        XCTAssertEqual(try build(s)["sort"], "-added_at", "added_at defaults to newest first")
    }

    func testSortOrderFlip() throws {
        var s = CatalogFilterState(); s.sort = .title; s.order = .desc
        XCTAssertEqual(try build(s)["sort"], "-title")
    }

    func testTypeParamGatedByIncludeType() throws {
        XCTAssertEqual(try build(.none, mediaType: .series, includeType: true)["type"], "series")
        XCTAssertNil(try build(.none, mediaType: .audiobook, includeType: true)["type"],
                     "audiobook scope omits type even when requested")
        XCTAssertNil(try build(.none, mediaType: .series, includeType: false)["type"])
    }

    func testMixedLibraryTypeScope() throws {
        XCTAssertNil(try build(.none, mediaType: .mixed, includeType: true)["type"],
                     "mixed browses merged — no library-derived scope")

        // The user-chosen Type facet is a grouped filter, even when includeType
        // is false (the iOS path), and wins over the library-derived scope.
        var s = CatalogFilterState(); s.mediaScope = "series"
        XCTAssertNil(try build(s, mediaType: .mixed, includeType: false)["type"],
                     "Type facet must not become unconditional media_scope")
        XCTAssertNil(try build(s, mediaType: .mixed, includeType: true)["type"],
                     "mixed library Type facet stays matchable")
        let group = try XCTUnwrap(try groups(s, mediaType: .mixed).first)
        XCTAssertEqual(group["match"] as? String, "all")
        let rule = try XCTUnwrap(try rules(group).first)
        XCTAssertEqual(rule["field"] as? String, "type")
        XCTAssertEqual(rule["op"] as? String, "is")
        XCTAssertEqual(rule["value"] as? String, "series")
    }

    func testMixedTypeFacetParticipatesInMatchAny() throws {
        var s = CatalogFilterState()
        s.matchAll = false
        s.mediaScope = "movie"
        s.genres = ["Drama"]

        XCTAssertEqual(try build(s, mediaType: .mixed)["match"], "any")
        let all = try groups(s, mediaType: .mixed)
        XCTAssertEqual(try rules(all[0]).first?["field"] as? String, "type")
        XCTAssertEqual(try rules(all[0]).first?["value"] as? String, "movie")
        XCTAssertEqual(try rules(all[1]).first?["field"] as? String, "genre")
        XCTAssertEqual(try rules(all[1]).first?["value"] as? String, "Drama")
    }

    func testMultiGenreBecomesOneAnyGroup() throws {
        var s = CatalogFilterState(); s.genres = ["Drama", "Action"]
        let group = try XCTUnwrap(try groups(s).first)
        XCTAssertEqual(group["match"] as? String, "any")
        let genreRules = try rules(group)
        XCTAssertEqual(genreRules.map { $0["field"] as? String }, ["genre", "genre"])
        XCTAssertEqual(genreRules.map { $0["op"] as? String }, ["contains", "contains"])
        // Values are emitted sorted for a stable query.
        XCTAssertEqual(genreRules.map { $0["value"] as? String }, ["Action", "Drama"])
    }

    func testDecadeLowersToNumericYearBetween() throws {
        var s = CatalogFilterState(); s.decades = [2010]
        let rule = try XCTUnwrap(try rules(try XCTUnwrap(try groups(s).first)).first)
        XCTAssertEqual(rule["field"] as? String, "year")
        XCTAssertEqual(rule["op"] as? String, "between")
        XCTAssertEqual(rule["value"] as? [Int], [2010, 2019])
    }

    func testWatchStatusUnwatchedIsBooleanFalse() throws {
        var s = CatalogFilterState(); s.watchStatus = .unwatched
        let rule = try XCTUnwrap(try rules(try XCTUnwrap(try groups(s).first)).first)
        XCTAssertEqual(rule["field"] as? String, "watched")
        XCTAssertEqual(rule["op"] as? String, "is")
        XCTAssertEqual(rule["value"] as? Bool, false)
        XCTAssertTrue(rule["value"].map { CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() } ?? false,
                      "the server rejects a string where it expects a boolean")
    }

    func testDynamicRangeValuesShareOneAnyGroupOfBooleans() throws {
        var s = CatalogFilterState()
        s.hdr = true
        s.dolbyVision = true

        let all = try groups(s)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0]["match"] as? String, "any")
        let flagRules = try rules(all[0])
        XCTAssertEqual(flagRules.map { $0["field"] as? String }, ["hdr", "dolby_vision"])
        XCTAssertEqual(flagRules.map { $0["op"] as? String }, ["is", "is"])
        for rule in flagRules {
            XCTAssertTrue(rule["value"].map { CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() } ?? false)
            XCTAssertEqual(rule["value"] as? Bool, true)
        }
    }

    func testMatchAnyTopLevel() throws {
        var s = CatalogFilterState(); s.matchAll = false
        XCTAssertEqual(try build(s)["match"], "any")
    }

    func testOversizedFiltersSwitchToThePOSTQuery() {
        var s = CatalogFilterState()
        XCTAssertEqual(CatalogQueryBuilder.build(s, libraryId: 1, mediaType: .movie, limit: 60).preferredOperation, .get)
        // Thousands of selected studios exceed the GET `groups` limit.
        s.studios = Set((0..<2000).map { "Studio number \($0)" })
        let query = CatalogQueryBuilder.build(s, libraryId: 1, mediaType: .movie, limit: 60)
        XCTAssertGreaterThan(try XCTUnwrap(try query.getParameters()["groups"]).utf8.count,
                             APIv2CatalogQuery.maxGetGroupsLength)
        XCTAssertEqual(query.preferredOperation, .query)
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
