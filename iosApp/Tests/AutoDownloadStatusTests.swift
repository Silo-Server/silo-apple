import Foundation
import XCTest
@testable import Silo

/// The auto-download screens' rules: which episodes a monitor covers, which
/// state a series reports first, the copy for each, and how the airing
/// calendar becomes upcoming episodes.
final class AutoDownloadStatusTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// Saturday, 3 October 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_028_800)

    // MARK: - Coverage

    func testCoverageFollowsTheMonitorRule() throws {
        XCTAssertTrue(covers(try subscription(.all), seasonNumber: 1))
        XCTAssertTrue(covers(try subscription(.future), seasonNumber: 1))
        let latest = try subscription(.latestSeason, target: 3)
        XCTAssertFalse(covers(latest, seasonNumber: 2))
        XCTAssertTrue(covers(latest, seasonNumber: 3))
        XCTAssertTrue(covers(latest, seasonNumber: 4))
        let picked = try subscription(.specificSeasons, seasons: [2, 4])
        XCTAssertTrue(covers(picked, seasonNumber: 4))
        XCTAssertFalse(covers(picked, seasonNumber: 3))
    }

    func testNextEpisodeSkipsUncoveredAndKnownEpisodes() {
        let upcoming = [
            episode("e7", season: 3, number: 7, daysAhead: 12),
            episode("e6", season: 3, number: 6, daysAhead: 5),
            episode("s2", season: 2, number: 9, daysAhead: 1),
        ]
        let next = AutoDownloadRules.nextEpisode(
            mode: .latestSeason, targetSeason: 3, seasonNumbers: nil, upcoming: upcoming, now: now
        )
        XCTAssertEqual(next?.contentId, "e6")

        let afterKnown = AutoDownloadRules.nextEpisode(
            mode: .latestSeason, targetSeason: 3, seasonNumbers: nil, upcoming: upcoming, excluding: ["e6"], now: now
        )
        XCTAssertEqual(afterKnown?.contentId, "e7")
    }

    // MARK: - Status order

    func testPausedOutranksEverything() throws {
        let status = AutoDownloadRules.status(
            for: try subscription(.all, active: false),
            activity: [activity(5, .downloading(fraction: 0.5))],
            upcoming: [episode("e6", season: 3, number: 6, daysAhead: 2)],
            knownEpisodeIds: []
        )
        XCTAssertEqual(status, .paused)
    }

    func testStorageLimitOutranksDownloads() throws {
        let limit = 25 * DownloadSettings.bytesPerGB
        let status = AutoDownloadRules.status(
            for: try subscription(.all, maxBytes: limit),
            activity: [activity(5, .downloading(fraction: 0.5)), activity(6, .storageLimit)],
            upcoming: [],
            knownEpisodeIds: []
        )
        XCTAssertEqual(status, .storageLimit(maxBytes: limit))
        XCTAssertEqual(AutoDownloadRules.statusLine(status), "Out of space · 25 GB limit")
    }

    func testDownloadInFlightOutranksWaitingAndUpcoming() throws {
        let status = AutoDownloadRules.status(
            for: try subscription(.all),
            activity: [activity(4, .waitingForWiFi), activity(5, .downloading(fraction: 0.62))],
            upcoming: [episode("e6", season: 3, number: 6, daysAhead: 2)],
            knownEpisodeIds: []
        )
        XCTAssertEqual(status, .downloading(episodeNumber: 5, fraction: 0.62))
        XCTAssertEqual(AutoDownloadRules.statusLine(status), "Downloading Episode 5 · 62%")
    }

    func testWaitingNamesTheEarliestEpisode() throws {
        let status = AutoDownloadRules.status(
            for: try subscription(.all),
            activity: [activity(6, .queued), activity(5, .waitingForWiFi)],
            upcoming: [],
            knownEpisodeIds: []
        )
        XCTAssertEqual(status, .waiting(episodeNumber: 5, phase: .waitingForWiFi))
        XCTAssertEqual(AutoDownloadRules.statusLine(status), "Episode 5 waits for Wi-Fi")
    }

    func testIdleSeriesNamesItsNextAiringOrIsUpToDate() throws {
        let sub = try subscription(.latestSeason, target: 3)
        let next = AutoDownloadRules.status(
            for: sub,
            activity: [],
            upcoming: [episode("e6", season: 3, number: 6, daysAhead: 5)],
            knownEpisodeIds: [],
            now: now
        )
        XCTAssertEqual(next, .next(episode("e6", season: 3, number: 6, daysAhead: 5)))
        XCTAssertEqual(AutoDownloadRules.status(for: sub, activity: [], upcoming: [], knownEpisodeIds: [], now: now), .upToDate)
        // An airing already past is the sync's to register, never "next".
        let aired = AutoDownloadRules.status(
            for: sub, activity: [], upcoming: [episode("e3", season: 3, number: 3, daysAhead: 0)], knownEpisodeIds: [], now: now
        )
        XCTAssertEqual(aired, .upToDate)
    }

    // MARK: - Copy

    func testNextEpisodeCopyUsesRelativeDays() {
        func line(_ days: Int, number: Int = 6) -> (String, String) {
            let status = AutoDownloadStatus.next(episode("e", season: 3, number: number, daysAhead: days))
            return (
                AutoDownloadRules.statusLine(status, now: now, calendar: calendar),
                AutoDownloadRules.headline(status, now: now, calendar: calendar)
            )
        }
        XCTAssertEqual(line(0).0, "Episode 6 today")
        XCTAssertEqual(line(1).1, "Episode 6 downloads tomorrow")
        XCTAssertEqual(line(5).0, "Episode 6 on Thursday")
        XCTAssertEqual(line(5).1, "Episode 6 downloads Thursday")
        XCTAssertEqual(line(12).0, "Episode 6 on Oct 15")
        XCTAssertEqual(line(17, number: 1).0, "Season 3 starts on Oct 20")
    }

    func testRuleSummaries() throws {
        XCTAssertEqual(AutoDownloadRules.ruleSummary(mode: .all, targetSeason: nil, seasonNumbers: nil), "All episodes")
        XCTAssertEqual(AutoDownloadRules.ruleSummary(mode: .future, targetSeason: nil, seasonNumbers: nil), "Future episodes")
        XCTAssertEqual(
            AutoDownloadRules.ruleSummary(mode: .latestSeason, targetSeason: 3, seasonNumbers: nil),
            "Last season · Season 3 on"
        )
        XCTAssertEqual(AutoDownloadRules.ruleSummary(for: try subscription(.future)), "Future episodes")
        XCTAssertEqual(AutoDownloadRules.ruleSummary(for: try subscription(.future, quality: "original")), "Future episodes")
        XCTAssertEqual(AutoDownloadRules.ruleSummary(for: try subscription(.future, quality: "10mbps")), "Future episodes · 10 Mbps")
        XCTAssertEqual(AutoDownloadRules.seasonList([4]), "Season 4")
        XCTAssertEqual(AutoDownloadRules.seasonList([3, 2]), "Seasons 2 and 3")
    }

    // MARK: - Calendar

    func testCalendarBecomesUpcomingEpisodesBySeries() throws {
        let json = """
        {"events": [
          {"date": "2026-10-02", "items": [
            {"content_id": "old", "type": "episode", "title": "Northwind", "series_id": "n",
             "season_number": 3, "episode_number": 4, "local_air_date": "2026-10-02"}
          ]},
          {"date": "2026-10-03", "items": [
            {"content_id": "today-undated", "type": "episode", "title": "Northwind", "series_id": "n",
             "season_number": 3, "episode_number": 5, "local_air_date": "2026-10-03"},
            {"content_id": "today-later", "type": "episode", "title": "Harbor Lights", "series_id": "h",
             "season_number": 2, "episode_number": 7, "air_at": "2026-10-03T21:00:00Z", "local_air_date": "2026-10-03"}
          ]},
          {"date": "2026-10-08", "items": [
            {"content_id": "e6", "type": "episode", "title": "Northwind", "episode_title": "Low Water",
             "series_id": "n", "season_number": 3, "episode_number": 6,
             "air_at": "2026-10-08T21:00:00Z", "local_air_date": "2026-10-08"},
            {"content_id": "movie", "type": "movie", "title": "Paper Moons", "local_air_date": "2026-10-08"}
          ]},
          {"date": "2026-10-20", "items": [
            {"content_id": "s4", "type": "season_premiere", "title": "Northwind", "series_id": "n",
             "season_number": 4, "local_air_date": "2026-10-20"}
          ]}
        ]}
        """
        let response = try HTTPClient.makeJSONDecoder().decode(CalendarResponse.self, from: Data(json.utf8))
        let upcoming = AutoDownloadSchedule.upcoming(from: response, now: now, calendar: calendar)
        XCTAssertEqual(Set(upcoming.keys), ["n", "h"])
        // Today's timed airing is still to come; today's undated one may have aired.
        XCTAssertEqual(upcoming["h"]?.map(\.contentId), ["today-later"])
        let episodes = try XCTUnwrap(upcoming["n"])
        XCTAssertEqual(episodes.map(\.contentId), ["e6", "s4"])
        XCTAssertEqual(episodes[0].title, "Low Water")
        XCTAssertEqual(episodes[0].airDate, ISO8601DateFormatter().date(from: "2026-10-08T21:00:00Z"))
        XCTAssertEqual(episodes[1].episodeNumber, 1)
    }

    // MARK: - Fixtures

    private func covers(_ subscription: DownloadSubscription, seasonNumber: Int) -> Bool {
        AutoDownloadRules.covers(
            mode: SubscriptionMode(rawValue: subscription.mode) ?? .all,
            targetSeason: subscription.targetSeason,
            seasonNumbers: subscription.seasonNumbers,
            seasonNumber: seasonNumber
        )
    }

    private func subscription(
        _ mode: SubscriptionMode,
        target: Int? = nil,
        seasons: [Int]? = nil,
        active: Bool = true,
        maxBytes: Int64 = 0,
        quality: String? = nil
    ) throws -> DownloadSubscription {
        var json: [String: Any] = [
            "id": "sub-1", "seriesId": "n", "mode": mode.rawValue,
            "deleteWatched": false, "maxStorageBytes": maxBytes, "active": active,
        ]
        json["targetSeason"] = target
        json["seasonNumbers"] = seasons
        json["quality"] = quality
        return try JSONDecoder().decode(DownloadSubscription.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func episode(_ id: String, season: Int, number: Int, daysAhead: Int) -> UpcomingEpisode {
        UpcomingEpisode(
            contentId: id,
            seriesId: "n",
            seasonNumber: season,
            episodeNumber: number,
            title: nil,
            airDate: now.addingTimeInterval(TimeInterval(daysAhead) * 86_400)
        )
    }

    private func activity(_ episode: Int, _ phase: AutoDownloadActivity.Phase) -> AutoDownloadActivity {
        AutoDownloadActivity(seasonNumber: 3, episodeNumber: episode, phase: phase)
    }
}
