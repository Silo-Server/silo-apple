import XCTest
@testable import Silo

final class DetailPlayLabelTests: XCTestCase {
    func testEpisodeInProgressReadsResume() throws {
        let episode = try episode(position: 600, duration: 3000)
        XCTAssertEqual(DetailPlayLabel.episode(episode), "Resume S1·E2")
    }

    func testEpisodeWithoutProgressReadsPlay() throws {
        XCTAssertEqual(DetailPlayLabel.episode(try episode(position: nil, duration: nil)), "Play S1·E2")
    }

    func testFirstThirtySecondsAndLastFiveSecondsReadPlay() throws {
        XCTAssertEqual(DetailPlayLabel.episode(try episode(position: 30, duration: 3000)), "Play S1·E2")
        XCTAssertEqual(DetailPlayLabel.episode(try episode(position: 2996, duration: 3000)), "Play S1·E2")
        XCTAssertEqual(DetailPlayLabel.episode(try episode(position: 31, duration: 3000)), "Resume S1·E2")
    }

    func testMovieLabelFollowsTheSameRule() throws {
        XCTAssertEqual(DetailPlayLabel.item(try userData(position: 1200, duration: 7200)), "Resume")
        XCTAssertEqual(DetailPlayLabel.item(try userData(position: 10, duration: 7200)), "Play")
        XCTAssertEqual(DetailPlayLabel.item(nil), "Play")
    }

    /// Builds watch state the way the detail reads do: the server's
    /// snake_case `user_data` through the production decoder and projection.
    private func userData(position: Double?, duration: Double?) throws -> LeafItemUserData {
        var object: [String: Any] = [
            "played": false, "watched_count": 0, "unplayed_count": 1,
            "in_progress_count": position == nil ? 0 : 1,
        ]
        if let position {
            object["position_seconds"] = position
            object["is_in_progress"] = true
        }
        if let duration { object["duration_seconds"] = duration }
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.WatchRollup.self, from: data)
        return try LeafItemUserData(catalog: wire)
    }

    private func episode(position: Double?, duration: Double?) throws -> EpisodeListItem {
        EpisodeListItem(
            contentId: "episode-1-2",
            seasonNumber: 1,
            episodeNumber: 2,
            title: "Second",
            overview: nil,
            airDate: nil,
            runtime: nil,
            imdbId: nil,
            tmdbId: nil,
            tvdbId: nil,
            stillUrl: nil,
            stillThumbhash: nil,
            userData: try userData(position: position, duration: duration),
            files: nil
        )
    }
}
