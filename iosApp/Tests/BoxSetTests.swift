import Foundation
import XCTest
@testable import Silo

/// Movie box sets (silo-server#677). A library that reports
/// `box_sets_enabled` browses with `group=box_set` and the server answers
/// `box_set` cards in place of a collection's movies; the box set read lists
/// its movies in release order; search lists matching box sets ahead of
/// titles. A server or library without box sets behaves exactly as before.
@MainActor
final class BoxSetTests: XCTestCase {
    private static let catalogPath = "/api/v2/catalog"
    private static let boxSetSearchPath = "/api/v2/catalog/box-sets"
    private static let peoplePath = "/api/v2/catalog/people"

    private let harryPotter = #"{"id":"1241","library_id":"1","title":"Harry Potter Collection","overview":"Wizards.","poster_url":"/api/v2/artwork/tmdb/collections/1241/poster/w300.webp","poster_thumbhash":"x/cF","movie_count":8,"played_count":3,"first_year":2001,"last_year":2011}"#
    private let notFound = #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"Not found","instance":"urn:test"}"#

    private var stub = APIv2TestStub()

    override func setUp() async throws {
        try await super.setUp()
        stub = APIv2TestStub()
    }

    private func api() async throws -> SiloAPI {
        let name = "BoxSetTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "box-set-test")
        await tokens.setServerUrl("https://boxsets.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens)
    }

    private func movie(_ id: String, _ title: String, year: Int, played: Bool) -> String {
        #"{"content_id":"\#(id)","type":"movie","title":"\#(title)","year":\#(year),"user_state":{"played":\#(played),"is_favorite":false,"in_watchlist":false}}"#
    }

    // MARK: Browse

    func testBoxSetLibraryBrowsesGroupedAndOthersDoNot() throws {
        let grouped = try CatalogQueryBuilder.build(.none, libraryId: 1, mediaType: .movie, limit: 60,
                                                    includeType: false, groupsBoxSets: true).getParameters()
        XCTAssertEqual(grouped["group"], "box_set")

        let plain = try CatalogQueryBuilder.build(.none, libraryId: 1, mediaType: .movie, limit: 60,
                                                  includeType: false).getParameters()
        XCTAssertNil(plain["group"], "a library without box sets sends exactly what it sent before")

        // A cached page of one list never paints the other.
        XCTAssertNotEqual(CatalogQueryBuilder.cacheKeyFragment(.none, groupsBoxSets: true),
                          CatalogQueryBuilder.cacheKeyFragment(.none, groupsBoxSets: false))
        XCTAssertEqual(CatalogQueryBuilder.cacheKeyFragment(.none, groupsBoxSets: false),
                       CatalogFilterState.none.cacheKeyFragment)
    }

    func testGroupedPageDecodesBoxSetCardsBesideMovies() async throws {
        let api = try await api()
        stub.reply(path: Self.catalogPath, 200, #"{"items":[\#(movie("movie-1", "Arrival", year: 2016, played: false)),{"content_id":"box_set:1241","type":"box_set","title":"Harry Potter Collection","year":2001,"user_state":{"played":false,"is_favorite":false,"in_watchlist":false},"box_set":\#(harryPotter)}],"page":{"has_more":false},"total":2,"total_exact":true}"#)
        let query = CatalogQueryBuilder.build(.none, libraryId: 1, mediaType: .movie, limit: 60,
                                              includeType: false, groupsBoxSets: true)

        let items = try await api.catalogPage(query).response.items

        XCTAssertEqual(stub.requests.last { $0.path == Self.catalogPath }?.query["group"], "box_set")
        XCTAssertEqual(items.map(\.isBoxSet), [false, true], "the client keeps the server's grouping and order")
        let boxSet = try XCTUnwrap(items[1].boxSet)
        XCTAssertEqual(boxSet.id, "1241")
        XCTAssertEqual(boxSet.appLibraryId, 1)
        XCTAssertEqual(Route.boxSet(boxSet), .boxSet(id: "1241", libraryId: 1))
        XCTAssertEqual(boxSet.cardCaption, "3 / 8 watched")
        XCTAssertEqual(boxSet.watchedProgress ?? 0, 0.375, accuracy: 0.0001)
    }

    func testLibrariesReportWhetherTheyGroupBoxSets() async throws {
        let api = try await api()
        stub.reply(path: "/api/v2/user/libraries", 200, #"{"items":[{"id":"1","name":"Movies","type":"movies","sort_order":1,"box_sets_enabled":true},{"id":"2","name":"Films","type":"movies","sort_order":2,"box_sets_enabled":false},{"id":"3","name":"Old","type":"movies","sort_order":3}]}"#)

        let libraries = try await api.libraries().libraries

        XCTAssertEqual(libraries.map(\.browsesBoxSets), [true, false, false],
                       "a server that predates box sets omits the field")
    }

    // MARK: Box set page

    func testBoxSetReadKeepsReleaseOrderAndPlaysTheFirstUnplayedMovie() async throws {
        let api = try await api()
        let body = String(harryPotter.dropLast()) + #","items":[\#(movie("hp1", "Philosopher's Stone", year: 2001, played: true)),\#(movie("hp2", "Chamber of Secrets", year: 2002, played: false)),\#(movie("hp3", "Prisoner of Azkaban", year: 2004, played: true))]}"#
        stub.reply(path: "/api/v2/catalog/box-sets/1241", 200, body)

        let detail = try await api.boxSet(id: "1241", libraryId: 1)

        let request = try XCTUnwrap(stub.requests.last { $0.path == "/api/v2/catalog/box-sets/1241" })
        XCTAssertEqual(request.query["library_id"], "1")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(detail.items.map(\.contentId), ["hp1", "hp2", "hp3"])
        XCTAssertEqual(detail.nextMovie?.contentId, "hp2")
        XCTAssertEqual(detail.playLabel, "Continue · Chamber of Secrets")
        XCTAssertEqual(detail.factTokens, ["8 films", "2001 – 2011", "3 of 8 watched"])
    }

    func testNextMovieStartsOverOnceEveryMovieIsPlayed() {
        let set = CatalogBoxSet(id: "1", libraryId: "1", title: "Trilogy", movieCount: 2, playedCount: 2)
        let detail = CatalogBoxSetDetail(boxSet: set, items: [
            BrowseItem(boxSetTestMovie: "a", played: true),
            BrowseItem(boxSetTestMovie: "b", played: true),
        ])
        XCTAssertEqual(detail.nextMovie?.contentId, "a")
        XCTAssertEqual(detail.playVerb, "Play", "a finished box set plays from the start")
    }

    func testUnavailableBoxSetExplainsWhy() async throws {
        let api = try await api()
        stub.reply(path: "/api/v2/catalog/box-sets/1241", 404, notFound)
        let model = BoxSetDetailViewModel(id: "1241", libraryId: 1, api: api)

        await model.load()

        let error = try XCTUnwrap(model.error)
        XCTAssertTrue(error.isNotFound)
        XCTAssertTrue(error.message.contains("turned off for this library"), error.message)
        XCTAssertNil(model.detail)
    }

    func testYearsAndFilmCountReadNaturally() {
        func set(_ first: Int?, _ last: Int?, count: Int = 1) -> CatalogBoxSet {
            CatalogBoxSet(id: "1", libraryId: "1", title: "T", movieCount: count, playedCount: 0,
                          firstYear: first, lastYear: last)
        }
        XCTAssertEqual(set(2001, 2011).yearsText, "2001 – 2011")
        XCTAssertEqual(set(2021, 2021).yearsText, "2021")
        XCTAssertNil(set(nil, nil).yearsText)
        XCTAssertEqual(set(nil, nil, count: 1).cardCaption, "1 film")
        XCTAssertEqual(set(nil, nil, count: 4).filmCountText, "4 films")
        XCTAssertNil(set(nil, nil).watchedProgress)
    }

    // MARK: Search

    private func searchModel(_ api: SiloAPI, boxSetsEnabled: Bool) -> SearchViewModel {
        let model = SearchViewModel(api: api, includesBoxSets: true)
        model.boxSetsEnabled = boxSetsEnabled
        model.query = "potter"
        return model
    }

    private func waitForBoxSets(_ model: SearchViewModel) async {
        for _ in 0..<200 where model.isSearchingBoxSets {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var boxSetSearches: [String?] {
        stub.requests.filter { $0.path == Self.boxSetSearchPath }.map { $0.query["q"] }
    }

    func testSearchListsMatchingBoxSetsBesideTitles() async throws {
        let api = try await api()
        stub.reply(path: Self.boxSetSearchPath, 200, #"{"items":[\#(harryPotter)]}"#)
        stub.reply(path: Self.catalogPath, 200, #"{"items":[\#(movie("hp1", "Philosopher's Stone", year: 2001, played: false))],"page":{"has_more":false},"total":1,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: true)

        await model.performSearch()
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, ["potter"])
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])
        XCTAssertEqual(model.results.map(\.contentId), ["hp1"], "the movies stay listed as today")
        XCTAssertEqual(model.contentState, .results)
    }

    func testSearchWithoutBoxSetLibrariesNeverAsks() async throws {
        let api = try await api()
        stub.reply(path: Self.catalogPath, 200, #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: false)

        await model.performSearch()
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, [])
        XCTAssertEqual(model.contentState, .noResults)
    }

    func testLibrariesArrivingAfterASearchAddTheirBoxSets() async throws {
        let api = try await api()
        stub.reply(path: Self.boxSetSearchPath, 200, #"{"items":[\#(harryPotter)]}"#)
        stub.reply(path: Self.catalogPath, 200, #"{"items":[\#(movie("hp1", "Philosopher's Stone", year: 2001, played: false))],"page":{"has_more":false},"total":1,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: false)
        await model.performSearch()

        model.boxSetsEnabled = true
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, ["potter"])
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])
        XCTAssertEqual(model.results.map(\.contentId), ["hp1"])
    }

    func testLibrariesArrivingWhileTitlesLoadAddTheirBoxSets() async throws {
        let api = try await api()
        stub.reply(path: Self.boxSetSearchPath, 200, #"{"items":[\#(harryPotter)]}"#)
        stub.reply(path: Self.catalogPath, 200, #"{"items":[\#(movie("hp1", "Philosopher's Stone", year: 2001, played: false))],"page":{"has_more":false},"total":1,"total_exact":true}"#)
        stub.hold(path: Self.catalogPath)
        let model = searchModel(api, boxSetsEnabled: false)
        let search = Task { await model.performSearch() }
        await stub.waitUntilHeld()
        XCTAssertTrue(model.isSearching)
        XCTAssertFalse(model.hasSearched, "the first search is still waiting for its titles")

        model.boxSetsEnabled = true
        stub.release()
        await search.value
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, ["potter"])
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])
        XCTAssertEqual(model.results.map(\.contentId), ["hp1"])
    }

    func testLibrariesArrivingBeforeTheSearchDecidesAskOnce() async throws {
        let api = try await api()
        let capabilitiesPath = "/api/v2/catalog/search/capabilities"
        stub.reply(path: capabilitiesPath, 200, #"{"revision":"r","state":"available","allowed":true,"people_media_scope":true,"video_with_episodes_scope":true}"#)
        stub.reply(path: Self.boxSetSearchPath, 200, #"{"items":[\#(harryPotter)]}"#)
        stub.reply(path: Self.catalogPath, 200, #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#)
        stub.hold(path: capabilitiesPath)
        let model = SearchViewModel(api: api, includesEpisodes: true, includesBoxSets: true)
        model.audiobooksEnabled = false
        model.query = "potter"
        let search = Task { await model.performSearch() }
        await stub.waitUntilHeld()

        // The search reads the flag itself once its scope is known.
        model.boxSetsEnabled = true
        stub.release()
        await search.value
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, ["potter"], "one lookup, not one from the flag and one from the search")
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])
    }

    func testNewQueryReplacesBoxSetsWhenItsLookupAnswers() async throws {
        let api = try await api()
        stub.sequence(path: Self.boxSetSearchPath, [
            .json(200, #"{"items":[\#(harryPotter)]}"#),
            .json(200, #"{"items":[]}"#),
        ])
        stub.reply(path: Self.catalogPath, 200, #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: true)
        await model.performSearch()
        await waitForBoxSets(model)
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])

        model.query = "heat"
        stub.hold(path: Self.boxSetSearchPath)
        let search = Task { await model.performSearch() }
        await stub.waitUntilHeld()
        // Like the titles, the section keeps the last answer until the new
        // one arrives rather than blanking on every query.
        XCTAssertEqual(model.boxSets.map(\.id), ["1241"])
        XCTAssertTrue(model.isSearchingBoxSets)

        stub.release()
        await search.value
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, ["potter", "heat"])
        XCTAssertTrue(model.boxSets.isEmpty, "no Harry Potter card left behind for the new query")
    }

    func testSeriesSearchLeavesBoxSetsOut() async throws {
        let api = try await api()
        stub.reply(path: Self.catalogPath, 200, #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: true)
        model.selectedMediaType = .series

        await model.performSearch()
        await waitForBoxSets(model)

        XCTAssertEqual(boxSetSearches, [])
        XCTAssertTrue(model.boxSets.isEmpty)
    }

    func testFailedBoxSetSearchKeepsTheTitles() async throws {
        let api = try await api()
        stub.reply(path: Self.boxSetSearchPath, 404, notFound)
        stub.reply(path: Self.catalogPath, 200, #"{"items":[\#(movie("hp1", "Philosopher's Stone", year: 2001, played: false))],"page":{"has_more":false},"total":1,"total_exact":true}"#)
        let model = searchModel(api, boxSetsEnabled: true)

        await model.performSearch()
        await waitForBoxSets(model)

        XCTAssertTrue(model.boxSets.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.results.map(\.contentId), ["hp1"])
    }
}

private extension BrowseItem {
    init(boxSetTestMovie id: String, played: Bool) {
        self.init(
            contentId: id, type: "movie", title: id, year: nil, genres: nil, contentRating: nil,
            advisoryAge: nil, advisorySource: nil, status: nil, ratingImdb: nil, ratingTmdb: nil,
            ratingRtCritic: nil, ratingRtAudience: nil, runtime: nil, originalLanguage: nil,
            studios: nil, networks: nil, showStatus: nil, overview: nil, posterThumbhash: nil,
            backdropThumbhash: nil, addedAt: nil, releaseDate: nil, lastAirDate: nil,
            userState: MediaItemUserState(played: played), overlaySummary: nil
        )
    }
}
