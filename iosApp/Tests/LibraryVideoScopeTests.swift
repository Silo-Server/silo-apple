import XCTest
@testable import Silo

final class LibraryVideoScopeTests: XCTestCase {
    func testRestartThenFailureDoesNotRestoreOldTitlesOrProgress() async throws {
        let removed = try item("removed", "series")
        let previous = try item("retained", "episode", progress: 10)
        let current = try item("retained", "episode", progress: 90)
        let film = try item("film", "movie")
        var cursors: [Int?] = []
        let result = try await LibraryVideoScope.series.refill(row(items: [removed, previous, film], total: 10)) { (cursor: Int?) in
            cursors.append(cursor)
            switch cursor {
            case nil: return LibraryScopedPage(items: [removed], next: 1)
            case 1: return LibraryScopedPage(items: [current], next: 2, startsOver: true)
            default: throw URLError(.timedOut)
            }
        }
        XCTAssertEqual(cursors, [nil, 1, 2])
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.section.items.map(\.id), ["retained"])
        XCTAssertEqual(result.section.items.first?.positionSeconds, 90)
    }

    func testFailedShelfRetainsInlineTitlesWithoutDiscardingSuccessfulShelves() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        let rows = [row(items: [film, show], total: 3, id: "failed"),
                    row(items: [film], total: 2, id: "healthy")]
        let results = try await LibraryVideoScope.series.refillSections(rows) { (row: ResolvedSection, _: Int?) -> LibraryScopedPage<Int> in
            if row.id == "failed" { throw URLError(.timedOut) }
            return LibraryScopedPage(items: [show], next: nil)
        }
        XCTAssertEqual(results.map { $0.section.id }, ["failed", "healthy"])
        XCTAssertEqual(results.map(\.incomplete), [true, false])
        XCTAssertEqual(results.map { $0.section.items.map(\.id) }, [["show"], ["show"]])
    }

    func testOwnerChangesAreNeverConvertedToPartialShelves() async throws {
        let film = try item("film", "movie")
        for ownerError in [HTTPError.requestIdentityChanged, HTTPError.authorityChanged] {
            do {
                _ = try await LibraryVideoScope.series.refill(row(items: [film], total: 2)) { (_: Int?) -> LibraryScopedPage<Int> in
                    throw ownerError
                }
                XCTFail("Owner changes must abort the read")
            } catch let error as HTTPError {
                XCTAssertEqual(error.description, ownerError.description)
            }
        }
    }

    func testCancelledShelfDoesNotBecomePartialSuccess() async throws {
        let film = try item("film", "movie")
        do {
            _ = try await LibraryVideoScope.series.refill(row(items: [film], total: 2)) { (_: Int?) -> LibraryScopedPage<Int> in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRefillsThreeShelvesAtATimeInLayoutAndCursorOrder() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        let started = expectation(description: "Three shelves begin before the first completes")
        started.expectedFulfillmentCount = 3
        let probe = ShelfRefillProbe(started: started, film: film, show: show)
        let rows = (0..<6).map { index in
            ResolvedSection(id: String(index), sectionType: "recently_added", title: "Shelf \(index)",
                            featured: false, itemLimit: 1, totalCount: 2, isCustom: false,
                            customized: false, items: [film])
        }
        let task = Task {
            try await LibraryVideoScope.series.refillSections(rows) { row, cursor in
                await probe.page(row.id, cursor: cursor)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let active = await probe.active
        XCTAssertEqual(active, 3)
        await probe.release()
        let results = try await task.value
        let peak = await probe.peak
        let cursors = await probe.cursors
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(results.map { $0.section.id }, rows.map(\.id))
        XCTAssertEqual(results.flatMap { $0.section.items }.map(\.id), Array(repeating: "show", count: 6))
        XCTAssertEqual(cursors.count, 6)
        for values in cursors.values { XCTAssertEqual(values, [nil, 1]) }
    }

    func testSectionPagingDoesNotSendFilterOverlays() throws {
        var query = APIv2CatalogQuery()
        query.source = "section"
        query.scope = "library"
        query.libraryId = "7"
        query.sectionId = "recent"
        query.limit = 100
        let parameters = try query.getParameters()
        XCTAssertEqual(parameters["section_id"], "recent")
        XCTAssertEqual(parameters["library_id"], "7")
        XCTAssertNil(parameters["match"])
        XCTAssertNil(parameters["type"])
        XCTAssertNil(parameters["sort"])
    }

    func testPagedEpisodePreservesPlaybackContext() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(BrowseItem.self, from: Data("""
        {"content_id":"episode","type":"episode","title":"Episode","series_id":"show","series_title":"Show",
         "season_number":2,"episode_number":3,"position_seconds":73,"duration_seconds":1200,"item_source":"continue_watching"}
        """.utf8))
        let sectionItem = SectionItem(browseItem: item)
        XCTAssertEqual(sectionItem.seriesId, "show")
        XCTAssertEqual(sectionItem.seasonNumber, 2)
        XCTAssertEqual(sectionItem.episodeNumber, 3)
        XCTAssertEqual(sectionItem.positionSeconds, 73)
        XCTAssertEqual(sectionItem.durationSeconds, 1200)
        XCTAssertEqual(sectionItem.itemSource, "continue_watching")
    }

    func testSeriesTabCannotBeBroadenedBySavedTypeOrMatchAny() throws {
        var filters = CatalogFilterState()
        filters.mediaScope = "movie"
        filters.matchAll = false
        filters.genres = ["Drama"]
        let query = try CatalogQueryBuilder.build(filters, libraryId: 7, mediaType: .mixed,
                                                  limit: 60, includeType: false,
                                                  enforcedScope: .series).getParameters()
        XCTAssertEqual(query["type"], "series")
        XCTAssertEqual(query["library_id"], "7")
        XCTAssertEqual(query["match"], "any")
        let groups = try XCTUnwrap(query["groups"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(groups.utf8)) as? [[String: Any]])
        let rules = decoded.flatMap { $0["rules"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(rules.compactMap { $0["field"] as? String }, ["genre"])
    }

    func testSeriesShelfRefillsBeyondFirstMoviePage() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        let original = row(items: [film], total: 2, limit: 1)
        var cursors: [Int?] = []
        let result = try await LibraryVideoScope.series.refill(original) { (cursor: Int?) in
            cursors.append(cursor)
            return cursor == nil ? LibraryScopedPage(items: [film], next: 1)
                : LibraryScopedPage(items: [show], next: nil)
        }
        XCTAssertEqual(cursors, [nil, 1])
        XCTAssertEqual(result.section.items.map(\.id), ["show"])
        XCTAssertFalse(result.incomplete)
        XCTAssertNil(result.section.totalCount, "The unfiltered total must not be shown as a typed count")
    }

    /// Recently Added / Recently Released report `total_count = len(items)`
    /// after their LIMIT, so a full inline slice of movies says nothing about
    /// older series. The shelf must still page the section source.
    func testInlineTotalEqualToSliceIsNotTreatedAsExhausted() async throws {
        let episode = try item("episode", "episode", progress: 73)
        let film = try item("film", "movie")
        let pagedEpisode = try item("episode", "episode")
        let olderShow = try item("older", "series")
        var cursors: [Int?] = []
        let result = try await LibraryVideoScope.series.refill(row(items: [film, episode], total: 2)) { (cursor: Int?) in
            cursors.append(cursor)
            return LibraryScopedPage(items: [film, pagedEpisode, olderShow], next: nil)
        }
        XCTAssertEqual(cursors, [nil])
        XCTAssertEqual(result.section.items.map(\.id), ["episode", "older"])
        XCTAssertEqual(result.section.items.first?.positionSeconds, 73, "The inline row's progress wins over the paged copy")
        XCTAssertFalse(result.incomplete)
    }

    func testFullScopedInlineSliceIsNotFetchedAgain() async throws {
        let shows = try (0..<2).map { try item("show\($0)", "series") }
        let result = try await LibraryVideoScope.series.refill(row(items: shows, total: 50, limit: 2)) { (_: Int?) -> LibraryScopedPage<Int> in
            XCTFail("A scoped slice that already fills the shelf needs no refill")
            return LibraryScopedPage(items: [], next: nil)
        }
        XCTAssertEqual(result.section.items.map(\.id), ["show0", "show1"])
        XCTAssertFalse(result.incomplete)
    }

    /// The section catalog source pages the admin definition, not a profile
    /// override, so a customized or profile-added row keeps its own items.
    func testProfileCustomizedShelvesAreNotRefilledFromTheAdminDefinition() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        // (customized, isCustom, totalCount, expected incomplete): the row keeps
        // its own items, and is only complete when the inline window is.
        for (customized, isCustom, total, incomplete) in [(true, false, 21, true), (false, true, 21, true),
                                                          (true, false, 2, false), (false, true, 2, false)] {
            let original = ResolvedSection(id: "random", sectionType: "random", title: "Random", featured: false,
                                           itemLimit: 20, totalCount: total, isCustom: isCustom,
                                           customized: customized, items: [film, show])
            let result = try await LibraryVideoScope.series.refill(original) { (_: Int?) -> LibraryScopedPage<Int> in
                XCTFail("A profile-customized row must not be refilled from the admin definition")
                return LibraryScopedPage(items: [], next: nil)
            }
            XCTAssertEqual(result.section.items.map(\.id), ["show"])
            XCTAssertEqual(result.incomplete, incomplete)
        }
    }

    /// A full customized window (20 movies, more behind it) cannot prove the
    /// selected type is absent, so the empty Series row must report incomplete.
    func testFullCustomizedWindowIsNeverReportedComplete() async throws {
        let movies = try (0..<20).map { try item("m\($0)", "movie") }
        let original = ResolvedSection(id: "random", sectionType: "random", title: "Random", featured: false,
                                       itemLimit: 20, totalCount: 20, isCustom: false,
                                       customized: true, items: movies)
        let result = try await LibraryVideoScope.series.refill(original) { (_: Int?) -> LibraryScopedPage<Int> in
            XCTFail("A profile-customized row must not be refilled from the admin definition")
            return LibraryScopedPage(items: [], next: nil)
        }
        XCTAssertTrue(result.section.items.isEmpty)
        XCTAssertTrue(result.incomplete)
    }

    func testEmptyPageWithContinuationKeepsPaging() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        var cursors: [Int?] = []
        let result = try await LibraryVideoScope.series.refill(row(items: [film], total: 1)) { (cursor: Int?) in
            cursors.append(cursor)
            switch cursor {
            case nil: return LibraryScopedPage(items: [], next: 1)
            default: return LibraryScopedPage(items: [show], next: nil)
            }
        }
        XCTAssertEqual(cursors, [nil, 1])
        XCTAssertEqual(result.section.items.map(\.id), ["show"])
        XCTAssertFalse(result.incomplete)
    }

    func testBoundedRefillDoesNotClaimAnEmptyLibraryWhenMatchingItemsMayBeLater() async throws {
        let film = try item("film", "movie")
        var reads = 0
        let result = try await LibraryVideoScope.series.refill(row(items: [film], total: 10_000)) { (cursor: Int?) in
            reads += 1
            return LibraryScopedPage(items: [film], next: reads)
        }
        XCTAssertEqual(reads, 8)
        XCTAssertTrue(result.incomplete)
        XCTAssertTrue(result.section.items.isEmpty)
    }

    func testMoviesRejectSeriesAndEpisodes() {
        XCTAssertTrue(LibraryVideoScope.movie.contains(" Movie "))
        XCTAssertFalse(LibraryVideoScope.movie.contains("series"))
        XCTAssertFalse(LibraryVideoScope.movie.contains("episode"))
        XCTAssertFalse(LibraryVideoScope.series.contains("audiobook"))
    }

    func testScopesAcceptEverySiloMediaTypeSpelling() {
        for type in ["movie", "Movies", "film"] {
            XCTAssertTrue(LibraryVideoScope.movie.contains(type), type)
            XCTAssertFalse(LibraryVideoScope.series.contains(type), type)
        }
        for type in ["series", "show", "shows", "tv", "tvshows", "episode", " Episodes "] {
            XCTAssertTrue(LibraryVideoScope.series.contains(type), type)
            XCTAssertFalse(LibraryVideoScope.movie.contains(type), type)
        }
    }

    #if os(tvOS)
    func testOnlyAnExplicitVideoTabNarrowsAMixedLibrary() {
        let mixed = Library(id: 1, name: "Everything", type: "mixed", sortOrder: nil)
        let movies = Library(id: 2, name: "Films", type: "movie", sortOrder: nil)
        XCTAssertTrue(mixed.isMixedLibrary)
        XCTAssertEqual(TVLibraryTypeTabView.mediaScope(for: .movies, library: mixed, scopesMixedLibraries: true), .movie)
        XCTAssertEqual(TVLibraryTypeTabView.mediaScope(for: .series, library: mixed, scopesMixedLibraries: true), .series)
        // A pinned shortcut resolves its pill vocabulary from the first
        // matching tab type (.movies for a mixed library); it must not hide series.
        XCTAssertNil(TVLibraryTypeTabView.mediaScope(for: .movies, library: mixed, scopesMixedLibraries: false))
        XCTAssertNil(TVLibraryTypeTabView.mediaScope(for: .movies, library: movies, scopesMixedLibraries: true))
        XCTAssertNil(TVLibraryTypeTabView.mediaScope(for: .movies, library: nil, scopesMixedLibraries: true))
    }
    #endif

    private func item(_ id: String, _ type: String, progress: Int = 0) throws -> SectionItem {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SectionItem.self, from: Data("""
        {"content_id":"\(id)","type":"\(type)","title":"\(id)","position_seconds":\(progress)}
        """.utf8))
    }

    private func row(items: [SectionItem], total: Int, limit: Int = 20, id: String = "recent") -> ResolvedSection {
        ResolvedSection(id: id, sectionType: "recently_added", title: "Recent", featured: false,
                        itemLimit: limit, totalCount: total, isCustom: false, customized: false, items: items)
    }
}

private actor ShelfRefillProbe {
    let started: XCTestExpectation
    let film: SectionItem
    let show: SectionItem
    var active = 0
    var peak = 0
    var cursors: [String: [Int?]] = [:]
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(started: XCTestExpectation, film: SectionItem, show: SectionItem) {
        self.started = started; self.film = film; self.show = show
    }

    func page(_ id: String, cursor: Int?) async -> LibraryScopedPage<Int> {
        cursors[id, default: []].append(cursor)
        active += 1; peak = max(peak, active)
        if !released {
            started.fulfill()
            await withCheckedContinuation { waiting.append($0) }
        }
        await Task.yield()
        active -= 1
        return cursor == nil ? LibraryScopedPage(items: [film], next: 1)
            : LibraryScopedPage(items: [show], next: nil)
    }

    func release() {
        released = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
