import Foundation
import XCTest
@testable import Silo

/// What the up-next screen offers during a shuffle, and how a multi-part item
/// plays through before the shuffle moves on.
final class PlayerShuffleStateTests: XCTestCase {
    private func item(_ id: String, type: String = "movie", title: String? = nil,
                      season: Int? = nil, episode: Int? = nil) throws -> ShuffleItem {
        var fields: [String: Any] = ["content_id": id, "type": type, "title": title ?? id,
                                     "poster_url": "https://art.example/\(id)-poster.jpg",
                                     "backdrop_url": "https://art.example/\(id)-backdrop.jpg"]
        if type == "episode" {
            fields["series_title"] = "Echo Station"
            fields["season_number"] = season
            fields["episode_number"] = episode
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try HTTPClient.makeJSONDecoder().decode(ShuffleItem.self, from: data)
    }

    private func shuffle(id: String = "s1", current: String, next: String) throws -> APIv2Shuffle {
        let json = """
        {"id":"\(id)","scope":{"kind":"library","id":"1","title":"Movies"},
         "current":{"content_id":"\(current)","type":"movie","title":"\(current)"},
         "next":{"content_id":"\(next)","type":"movie","title":"\(next)"}}
        """
        return try HTTPClient.makeJSONDecoder().decode(APIv2Shuffle.self, from: Data(json.utf8))
    }

    private let conflict = APIv2Error.problem(APIv2Problem(
        type: "https://siloserver.org/docs/api/v2/problems/conflict", title: "Conflict", status: 409,
        detail: "Nothing here can be played.", instance: nil, errors: nil
    ))

    // MARK: Up next

    func testOffersTheServersNextPick() throws {
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "b"))
        state.markPlayed("a")
        XCTAssertEqual(state.upNext?.contentId, "b")
        XCTAssertTrue(state.canPickAnother)
        XCTAssertEqual(state.advanceFromContentId, "a")
    }

    func testOneItemScopeShowsTheFinishedState() throws {
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "a"))
        state.markPlayed("a")
        XCTAssertNil(state.upNext)
        XCTAssertFalse(state.canPickAnother)
    }

    func testAnAdvancedPickThatNeverPlayedIsStillNext() throws {
        // Advance succeeded, but the new current item failed to load: the
        // next press must play it rather than advance past it.
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "b"))
        state.markPlayed("a")
        state.apply(try shuffle(current: "b", next: "c"))
        XCTAssertEqual(state.upNext?.contentId, "b")
        XCTAssertFalse(state.canPickAnother)
        XCTAssertEqual(state.advanceFromContentId, "a")

        state.markPlayed("b")
        XCTAssertEqual(state.upNext?.contentId, "c")
        XCTAssertTrue(state.canPickAnother)
    }

    func testReadConflictFinishesAndALaterPickReopens() throws {
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "b"))
        state.markPlayed("a")
        state.applyRefreshFailure(conflict)
        XCTAssertTrue(state.isExhausted)
        XCTAssertNil(state.upNext)

        state.apply(try shuffle(current: "a", next: "c"))
        XCTAssertEqual(state.upNext?.contentId, "c")
    }

    func testOtherReadFailuresKeepTheLastPick() throws {
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "b"))
        state.markPlayed("a")
        state.applyRefreshFailure(URLError(.notConnectedToInternet))
        state.applyRefreshFailure(APIv2Error.httpStatus(503))
        XCTAssertEqual(state.upNext?.contentId, "b")
    }

    func testAnotherShufflesAnswerIsIgnored() throws {
        var state = PlayerShuffleState(shuffle: try shuffle(current: "a", next: "b"))
        state.apply(try shuffle(id: "other", current: "x", next: "y"))
        XCTAssertEqual(state.upNext?.contentId, "b")
    }

    // MARK: Up-next card

    func testMoviePickHasNoEpisodeLineAndShowsItsBackdrop() throws {
        let pick = PlayerNextUpEpisode(shufflePick: try item("movie-1", title: "Alpha Run"))
        XCTAssertNil(pick.episodeLabel)
        XCTAssertNil(pick.seriesTitle)
        XCTAssertEqual(pick.title, "Alpha Run")
        XCTAssertEqual(pick.stillUrl, "https://art.example/movie-1-backdrop.jpg")
    }

    func testEpisodePickKeepsItsSeriesAndStill() throws {
        let pick = PlayerNextUpEpisode(shufflePick: try item("ep-2", type: "episode", title: "Pilot", season: 0, episode: 1))
        XCTAssertEqual(pick.episodeLabel, "S0:E1")
        XCTAssertEqual(pick.seriesTitle, "Echo Station")
        XCTAssertEqual(pick.stillUrl, "https://art.example/ep-2-poster.jpg")
    }

    // MARK: Multi-part items

    private func part(_ fileId: Int, _ index: Int?, group: String? = "Delta Split", resolution: String = "1080p") -> FileVersion {
        FileVersion(fileId: fileId, fileName: nil, resolution: resolution, codecVideo: nil, codecAudio: nil, hdr: nil,
                    container: nil, fileSize: nil, duration: nil, bitrate: nil, videoTracks: nil, audioTracks: nil,
                    subtitleTracks: nil, chapters: nil, presentationKind: index == nil ? nil : "multipart_movie",
                    presentationGroupKey: group, presentationPartIndex: index, presentationPartTotal: index == nil ? nil : 2)
    }

    func testPlayThroughStartsAtPartOneAndMovesToPartTwo() {
        let versions = [part(16, 2), part(18, 1)]
        XCTAssertEqual(PlayerMultipartPolicy.firstPart(for: versions[0], in: versions)?.fileId, 18)
        XCTAssertNil(PlayerMultipartPolicy.firstPart(for: versions[1], in: versions))
        XCTAssertEqual(PlayerMultipartPolicy.nextPart(after: versions[1], in: versions)?.fileId, 16)
        XCTAssertNil(PlayerMultipartPolicy.nextPart(after: versions[0], in: versions))
    }

    func testNextPartKeepsTheResolutionThatWasPlaying() {
        let versions = [part(1, 1, resolution: "2160p"), part(2, 2, resolution: "1080p"), part(3, 2, resolution: "2160p")]
        XCTAssertEqual(PlayerMultipartPolicy.nextPart(after: versions[0], in: versions)?.fileId, 3)
    }

    func testSingleFileItemsHaveNoParts() {
        let single = part(5, nil, group: nil)
        XCTAssertNil(PlayerMultipartPolicy.nextPart(after: single, in: [single]))
        XCTAssertNil(PlayerMultipartPolicy.firstPart(for: single, in: [single]))
    }

    // MARK: Entry points

    func testShuffleIsOfferedForMovieTVAndMixedLibrariesOnly() {
        for type in ["movies", "series", "tv", "mixed"] {
            XCTAssertTrue(ShuffleAvailability.isShuffleLibraryType(type), type)
        }
        for type in ["audiobooks", "music", "", nil] as [String?] {
            XCTAssertFalse(ShuffleAvailability.isShuffleLibraryType(type), type ?? "nil")
        }
        XCTAssertFalse(ShuffleAvailability.hasEnoughToShuffle(playableCount: 1))
        XCTAssertTrue(ShuffleAvailability.hasEnoughToShuffle(playableCount: 2))
    }

    func testStartFailuresExplainThemselves() {
        XCTAssertEqual(ShuffleLauncher.failureMessage(for: conflict), "Nothing here can be played.")
        XCTAssertEqual(ShuffleLauncher.failureMessage(for: URLError(.timedOut)), "Couldn't start the shuffle. Try again.")
    }
}
