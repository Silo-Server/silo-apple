import XCTest
@testable import Silo

final class SeriesEpisodeWindowTests: XCTestCase {
    func testContinuousOrderAndSpecialsLast() throws {
        let seasons = try [0, 3, 1, 2].map(season)
        let window = SeriesEpisodeWindow.snapshot(seasons: seasons, selected: 2, pages: [
            0: [try episode(0, 1)], 1: [try episode(1, 2), try episode(1, 1)],
            2: [try episode(2, 1)], 3: [try episode(3, 1)],
        ])
        XCTAssertEqual(window.episodes.map(\.contentId), ["s1e1", "s1e2", "s2e1", "s3e1", "s0e1"])
        XCTAssertNil(window.previousSeason)
        XCTAssertNil(window.nextSeason)
    }

    func testMissingSeasonDoesNotJoinNonadjacentRuns() throws {
        let seasons = try (1...4).map(season)
        let window = SeriesEpisodeWindow.snapshot(seasons: seasons, selected: 3, pages: [
            1: [try episode(1, 1)], 3: [try episode(3, 1)],
        ])
        XCTAssertEqual(window.episodes.map(\.contentId), ["s3e1"])
        XCTAssertEqual(window.previousSeason, 2)
        XCTAssertEqual(window.nextSeason, 4)
    }

    func testLoadedEmptySeasonsAreTraversed() throws {
        let window = SeriesEpisodeWindow.snapshot(seasons: try (1...4).map(season), selected: 1, pages: [
            1: [try episode(1, 1)], 2: [], 3: [try episode(3, 1)],
        ])
        XCTAssertEqual(window.episodes.map(\.contentId), ["s1e1", "s3e1"])
        XCTAssertEqual(window.nextSeason, 4)
    }

    func testUnloadedJumpDoesNotShowThePreviousSeasonsEpisodes() throws {
        let window = SeriesEpisodeWindow.snapshot(seasons: try (1...3).map(season), selected: 3, pages: [
            1: [try episode(1, 1)],
        ])
        XCTAssertTrue(window.episodes.isEmpty)
    }

    func testDuplicateSeasonsAndEpisodeIdentitiesDoNotCreateDuplicateCards() throws {
        let shared = try episode(1, 1)
        let window = SeriesEpisodeWindow.snapshot(seasons: try [1, 1, 2].map(season), selected: 1, pages: [
            1: [shared, shared], 2: [shared, try episode(2, 1)],
        ])
        XCTAssertEqual(window.episodes.map(\.contentId), ["s1e1", "s2e1"])
    }

    func testLargeSeriesRetainsFivePagesAndPreservesTheFocusedEpisodeAcrossEviction() throws {
        let seasons = try (1...30).map(season)
        let pages = try Dictionary(uniqueKeysWithValues: (1...30).map { number in
            (number, try (1...100).map { try episode(number, $0) })
        })
        let before = SeriesEpisodeWindow.retainedPages(seasons: seasons, selected: 15, pages: pages)
        XCTAssertEqual(Set(before.keys), Set(13...17))
        let after = SeriesEpisodeWindow.retainedPages(seasons: seasons, selected: 16, pages: pages)
        XCTAssertEqual(Set(after.keys), Set(14...18))
        let oldWindow = SeriesEpisodeWindow.snapshot(seasons: seasons, selected: 15, pages: before)
        let newWindow = SeriesEpisodeWindow.snapshot(seasons: seasons, selected: 16, pages: after)
        XCTAssertEqual(oldWindow.episodes.count, 500)
        XCTAssertEqual(newWindow.episodes.count, 500)
        XCTAssertEqual(oldWindow.episodes.firstIndex(where: { $0.contentId == "s16e1" }), 300)
        XCTAssertEqual(newWindow.episodes.firstIndex(where: { $0.contentId == "s16e1" }), 200)
        XCTAssertEqual(newWindow.previousSeason, 13)
        XCTAssertEqual(newWindow.nextSeason, 19)
    }

    func testEmptyPagesSurviveEvictionWithoutDisplacingRealEpisodes() throws {
        let seasons = try (1...9).map(season)
        var pages = try Dictionary(uniqueKeysWithValues: (1...9).map { ($0, [try episode($0, 1)]) })
        pages[2] = []
        pages[3] = []
        let retained = SeriesEpisodeWindow.retainedPages(seasons: seasons, selected: 7, pages: pages)
        XCTAssertEqual(retained.values.filter { !$0.isEmpty }.count, 5)
        XCTAssertEqual(retained[2], [])
        XCTAssertEqual(retained[3], [])
    }

    @MainActor
    func testEpisodeEntryUsesRequestedSeasonInsteadOfFirstUnplayedSeason() throws {
        let model = ItemDetailViewModel()
        let seasons = try (1...38).map(season)
        model.initialResumeSeasonNumber = 38
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 38)
        model.initialResumeSeasonNumber = nil
        XCTAssertEqual(model.preferredInitialSeason(seasons: seasons)?.seasonNumber, 1)
    }

    @MainActor
    func testMissingRequestedSeasonFallsBackToAvailableSeasons() throws {
        let model = ItemDetailViewModel()
        model.initialResumeSeasonNumber = 38
        XCTAssertEqual(model.preferredInitialSeason(seasons: try [2, 3].map(season))?.seasonNumber, 2)
    }

    func testParentSeriesRouteRetainsExactEpisodeAcrossCopies() throws {
        let item = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"episode-38-1","type":"episode","title":"Episode","seriesId":"series","seriesTitle":"Series","seasonNumber":38,"episodeNumber":1}"#.utf8
        ))
        let seed = TVItemDetailRouteSeed.destination(contentId: "series", from: item)
        let routeCopy = seed
        XCTAssertEqual(routeCopy.episodeContext?.seriesContentId, "series")
        XCTAssertEqual(routeCopy.episodeContext?.seasonNumber, 38)
        XCTAssertEqual(routeCopy.episodeContext?.episodeContentId, "episode-38-1")
        XCTAssertEqual(seed.episodeContext, routeCopy.episodeContext)
        XCTAssertEqual(seed.mediaType, "series")
    }

    func testUnrelatedDestinationDoesNotReceiveEpisodeIntent() throws {
        let item = try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"episode","type":"episode","title":"Episode","seriesId":"series","seasonNumber":4,"episodeNumber":1}"#.utf8
        ))
        XCTAssertNil(TVItemDetailRouteSeed.destination(contentId: "other", from: item).episodeContext)
        XCTAssertNil(TVItemDetailRouteSeed.destination(contentId: "episode", from: item).episodeContext)
    }

    private func season(_ number: Int) throws -> Season {
        try JSONDecoder().decode(Season.self, from: Data(
            "{\"contentId\":\"season-\(number)\",\"seasonNumber\":\(number)}".utf8
        ))
    }

    private func episode(_ season: Int, _ number: Int) throws -> EpisodeListItem {
        try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            "{\"contentId\":\"s\(season)e\(number)\",\"seasonNumber\":\(season),\"episodeNumber\":\(number)}".utf8
        ))
    }
}
