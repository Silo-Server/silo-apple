#if os(iOS) || os(tvOS)
import AppIntents
import Network
import XCTest
@testable import Silo

/// Siri's intents reach the app through `silo://` links, so spoken words
/// have to survive the round trip, and "play <title>" must start playback
/// only when exactly one library title matches.
@MainActor
final class SiriIntentTests: XCTestCase {
    // MARK: - Links

    func testWordsSurviveLinkRoundTrip() throws {
        for words in ["The Office", "Tom & Jerry", "50% off?", "Amélie", "a+b=c #1"] {
            for link in [SiriLink.search(term: words), .play(title: words, onTV: false), .play(title: words, onTV: true)] {
                let url = try XCTUnwrap(link.url)
                XCTAssertEqual(url.scheme, "silo")
                XCTAssertEqual(SiriLink(url: url), link, "\(url)")
            }
        }
    }

    func testLinkParsing() throws {
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(URL(string: "silo://search?q=%20Dune%0A"))), .search(term: "Dune"))
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(URL(string: "silo://search"))), .search(term: ""))
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(URL(string: "continuum://play?q=Dune"))), .play(title: "Dune", onTV: false))
        // A play link needs a title; the exact-item link is not a Siri link.
        XCTAssertNil(SiriLink(url: try XCTUnwrap(URL(string: "silo://play?q=%20"))))
        XCTAssertNil(SiriLink(url: try XCTUnwrap(URL(string: "silo://play/abc123"))))
        XCTAssertNil(SiriLink(url: try XCTUnwrap(URL(string: "silo://item/abc?q=Dune"))))
        XCTAssertNil(SiriLink(url: try XCTUnwrap(URL(string: "https://search?q=Dune"))))
    }

    func testIntentsHandWordsToDeepLinkInbox() async throws {
        let coordinator = SiloDeepLinkCoordinator.shared
        _ = coordinator.consumePendingURL()
        defer { _ = coordinator.consumePendingURL() }

        var search = SearchInSiloIntent()
        search.criteria = StringSearchCriteria(term: "Blade Runner")
        _ = try await search.perform()
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(coordinator.consumePendingURL())), .search(term: "Blade Runner"))

        var play = PlayInSiloIntent()
        play.term = "Dune"
        _ = try await play.perform()
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(coordinator.consumePendingURL())), .play(title: "Dune", onTV: false))

        #if os(iOS)
        var onTV = PlayOnTVIntent()
        onTV.term = "Dune"
        _ = try await onTV.perform()
        XCTAssertEqual(SiriLink(url: try XCTUnwrap(coordinator.consumePendingURL())), .play(title: "Dune", onTV: true))
        #endif
    }

    // MARK: - Title matching

    private typealias Candidate = SiriPlaybackResolver.Candidate

    private let library: [Candidate] = [
        Candidate(contentId: "dune-2021", title: "Dune", type: "movie", year: 2021),
        Candidate(contentId: "dune-1984", title: "Dune", type: "movie", year: 1984),
        Candidate(contentId: "dune-part-two", title: "Dune: Part Two", type: "movie", year: 2024),
        Candidate(contentId: "tom-jerry", title: "Tom & Jerry", type: "movie", year: 2021),
        Candidate(contentId: "spider-man", title: "Spider-Man", type: "movie", year: 2002),
        Candidate(contentId: "br-2049", title: "Blade Runner 2049", type: "movie", year: 2017),
        Candidate(contentId: "severance", title: "Severance", type: "series", year: 2022),
    ]

    private func resolver(
        home: [ResolvedSection] = [],
        seasons: [Season] = [],
        episodes: [EpisodeListItem] = []
    ) -> SiriPlaybackResolver {
        SiriPlaybackResolver(
            search: { [library] text in
                let key = SiriPlaybackResolver.matchKey(text)
                return library.filter { SiriPlaybackResolver.matchKey($0.title).contains(key) }
            },
            homeSections: { home },
            seasons: { _ in seasons },
            episodes: { _, _ in episodes }
        )
    }

    func testSingleExactTitlePlays() async throws {
        let outcome = try await resolver().resolve("tom and jerry")
        XCTAssertEqual(outcome, .play(contentId: "tom-jerry", titleContentId: "tom-jerry"))
        let spiderMan = try await resolver().resolve("Spider Man")
        XCTAssertEqual(spiderMan, .play(contentId: "spider-man", titleContentId: "spider-man"))
        XCTAssertEqual(SiriPlaybackResolver.matchKey("How It’s Made"), SiriPlaybackResolver.matchKey("how its made"))
    }

    func testSeveralOrNoMatchesOpenSearch() async throws {
        let dune = try await resolver().resolve("Dune")
        XCTAssertEqual(dune, .search(term: "Dune"))
        let missing = try await resolver().resolve("Dun")
        XCTAssertEqual(missing, .search(term: "Dun"))
    }

    func testTrailingYearPicksReleaseOnlyWhenWholeTitleMissing() async throws {
        let dune = try await resolver().resolve("Dune 1984")
        XCTAssertEqual(dune, .play(contentId: "dune-1984", titleContentId: "dune-1984"))
        let bladeRunner = try await resolver().resolve("Blade Runner 2049")
        XCTAssertEqual(bladeRunner, .play(contentId: "br-2049", titleContentId: "br-2049"))
        XCTAssertNil(SiriPlaybackResolver.splitTrailingYear("1917"))
    }

    func testSeriesPlaysNextUpEpisode() async throws {
        let seasons = try decode([Season].self, """
        [{"contentId": "s1", "seasonNumber": 1, "episodeCount": 2, "userData": {"played": true, "watchedCount": 2}},
         {"contentId": "s2", "seasonNumber": 2, "episodeCount": 3, "userData": {"played": false, "watchedCount": 1}}]
        """)
        let episodes = try decode([EpisodeListItem].self, """
        [{"contentId": "e1", "seasonNumber": 2, "episodeNumber": 1, "userData": {"played": true}},
         {"contentId": "e2", "seasonNumber": 2, "episodeNumber": 2, "userData": {"played": false}},
         {"contentId": "e3", "seasonNumber": 2, "episodeNumber": 3}]
        """)
        var requestedSeason: Int?
        var resolver = resolver(seasons: seasons)
        resolver.episodes = { _, season in
            requestedSeason = season
            return episodes
        }
        let outcome = try await resolver.resolve("severance")
        XCTAssertEqual(outcome, .play(contentId: "e2", titleContentId: "severance"))
        XCTAssertEqual(requestedSeason, 2)
    }

    func testSeriesResumesHomeEpisodeBeforeSeasonCounts() async throws {
        let items = try decode([SectionItem].self, """
        [{"contentId": "other-e1", "type": "episode", "title": "Pilot", "seriesId": "other"},
         {"contentId": "sev-s2e4", "type": "episode", "title": "Woe's Hollow", "seriesId": "severance"}]
        """)
        func section(_ type: String, _ items: [SectionItem]) -> ResolvedSection {
            ResolvedSection(id: type, sectionType: type, title: type, featured: nil, itemLimit: nil,
                            totalCount: nil, isCustom: nil, customized: nil, items: items)
        }
        let nextUpOnly = try await resolver(home: [section("next_up", items)]).resolve("Severance")
        XCTAssertEqual(nextUpOnly, .play(contentId: "sev-s2e4", titleContentId: "severance"))

        let inProgress = try decode([SectionItem].self, """
        [{"contentId": "sev-s1e9", "type": "episode", "title": "The We We Are", "seriesId": "severance"}]
        """)
        let both = try await resolver(
            home: [section("next_up", items), section("continue_watching", inProgress)]
        ).resolve("Severance")
        XCTAssertEqual(both, .play(contentId: "sev-s1e9", titleContentId: "severance"))
    }

    func testSeriesWithoutEpisodesOpensSearch() async throws {
        let outcome = try await resolver().resolve("Severance")
        XCTAssertEqual(outcome, .search(term: "Severance"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - TV choice

    #if os(iOS)
    private func tv(_ id: String, server: String = "home", version: Int = 2) -> SiloControlTarget {
        SiloControlTarget(
            id: id,
            name: id,
            endpoint: .hostPort(host: "127.0.0.1", port: 1),
            serverId: server,
            serverName: nil,
            protocolVersion: version
        )
    }

    func testTVChoice() {
        let onHome: (SiloControlTarget) -> Bool = { $0.serverId == "home" }
        let living = tv("living"), bedroom = tv("bedroom"), neighbour = tv("neighbour", server: "other")

        // The last-used TV wins, even on another server.
        XCTAssertEqual(SiriTVTarget.choose(from: [living, bedroom], preferredId: "bedroom", isOnActiveServer: onHome), bedroom)
        XCTAssertEqual(SiriTVTarget.choose(from: [neighbour], preferredId: "neighbour", isOnActiveServer: onHome), neighbour)
        // Otherwise only a single TV on this server is picked silently.
        XCTAssertEqual(SiriTVTarget.choose(from: [living, neighbour], preferredId: nil, isOnActiveServer: onHome), living)
        XCTAssertNil(SiriTVTarget.choose(from: [living, bedroom], preferredId: "gone", isOnActiveServer: onHome))
        XCTAssertNil(SiriTVTarget.choose(from: [neighbour], preferredId: nil, isOnActiveServer: onHome))
        XCTAssertNil(SiriTVTarget.choose(from: [], preferredId: nil, isOnActiveServer: onHome))
        // A TV too old to play under this profile is never chosen.
        XCTAssertNil(SiriTVTarget.choose(from: [tv("old", version: 1)], preferredId: "old", isOnActiveServer: onHome))
    }
    #endif
}
#endif
