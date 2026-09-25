#if os(iOS) || os(tvOS)
import Foundation

/// What a spoken "play <title>" resolves to.
enum SiriPlaybackOutcome: Equatable {
    /// Play `contentId`. For a series this is its next-up episode, and
    /// `titleContentId` is the series; for a movie the two are the same.
    case play(contentId: String, titleContentId: String)
    /// The match isn't clear (several titles, none, or a series with no
    /// episodes), so Search opens with the spoken words instead.
    case search(term: String)
}

/// Turns the words Siri heard into one library title to play.
///
/// Playback starts only for a single exact title match, so Siri never starts
/// the wrong film: "Dune" with three Dunes in the library opens Search, and
/// "Dune 1984" plays the 1984 one. Only movies and series take part.
struct SiriPlaybackResolver {
    struct Candidate: Equatable {
        let contentId: String
        let title: String
        let type: String
        let year: Int?
    }

    var search: (_ text: String) async throws -> [Candidate]
    /// The profile's Home rows; Continue Watching and Next Up name the
    /// episode each series resumes on.
    var homeSections: () async throws -> [ResolvedSection]
    var seasons: (_ seriesId: String) async throws -> [Season]
    var episodes: (_ seriesId: String, _ seasonNumber: Int) async throws -> [EpisodeListItem]

    static let live = SiriPlaybackResolver(
        search: { text in
            try await SiloAPI.shared.catalogPage(.search(text, type: "video", limit: 30))
                .response.items
                .map { Candidate(contentId: $0.contentId, title: $0.title, type: $0.type, year: $0.year) }
        },
        homeSections: { try await SiloAPI.shared.homeSections().sections },
        seasons: { try await SiloAPI.shared.seasons(seriesId: $0).seasons },
        episodes: { try await SiloAPI.shared.episodes(seriesId: $0, seasonNumber: $1).episodes }
    )

    func resolve(_ spoken: String) async throws -> SiriPlaybackOutcome {
        let term = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .search(term: term) }

        // A title that ends in a year ("Blade Runner 2049") is tried whole
        // first; only when that finds nothing is the year read as a release
        // year ("Dune 1984").
        var match = Self.singleMatch(in: try await search(term), title: term, year: nil)
        if match == nil, let (title, year) = Self.splitTrailingYear(term) {
            match = Self.singleMatch(in: try await search(title), title: title, year: year)
        }
        guard let match else { return .search(term: term) }
        return try await outcome(for: match, fallbackTerm: term)
    }

    /// A title Siri already identified by name. `title` is the Search
    /// fallback when a series has nothing to play.
    func resolve(contentId: String, title: String, isSeries: Bool) async throws -> SiriPlaybackOutcome {
        let candidate = Candidate(contentId: contentId, title: title, type: isSeries ? "series" : "movie", year: nil)
        return try await outcome(for: candidate, fallbackTerm: title)
    }

    private func outcome(for match: Candidate, fallbackTerm term: String) async throws -> SiriPlaybackOutcome {
        guard SiloMediaType.isSeries(match.type) else {
            return .play(contentId: match.contentId, titleContentId: match.contentId)
        }
        // Home names the exact episode a series resumes on, as its Continue
        // Watching and Next Up cards do. Without one (or when Home can't be
        // read), the series page's own season rule picks the episode.
        if let sections = try? await homeSections(),
           let episodeId = Self.resumeEpisode(forSeries: match.contentId, in: sections) {
            return .play(contentId: episodeId, titleContentId: match.contentId)
        }
        guard let season = SeriesNextUpPolicy.preferredSeason(in: try await seasons(match.contentId)),
              let episode = SeriesNextUpPolicy.nextUpEpisode(
                  in: try await episodes(match.contentId, season.seasonNumber)
              ) else {
            return .search(term: term)
        }
        return .play(contentId: episode.contentId, titleContentId: match.contentId)
    }

    /// The series' episode in Continue Watching, else in Next Up.
    static func resumeEpisode(forSeries seriesId: String, in sections: [ResolvedSection]) -> String? {
        let continueWatching = sections.filter(\.isContinueWatchingSection)
        let nextUp = sections.filter { $0.sectionType.lowercased().contains("next") }
        for section in continueWatching + nextUp {
            if let item = section.items.first(where: {
                $0.seriesId == seriesId && $0.contentId != seriesId
            }) {
                return item.contentId
            }
        }
        return nil
    }

    // MARK: - Matching

    /// The only candidate whose title equals `title` (and whose year equals
    /// `year`, when given), or nil when zero or several do.
    static func singleMatch(in candidates: [Candidate], title: String, year: Int?) -> Candidate? {
        let key = matchKey(title)
        let matches = candidates.filter {
            matchKey($0.title) == key && (year == nil || $0.year == year)
        }
        // The same title can come back twice from two libraries.
        let distinct = Dictionary(grouping: matches, by: \.contentId)
        return distinct.count == 1 ? matches.first : nil
    }

    /// Case, accents, punctuation, and "&" versus "and" don't matter:
    /// "tom and jerry", "Spider Man", and "how its made" all match
    /// "Tom & Jerry", "Spider-Man", and "How It's Made". Apostrophes join
    /// their word; other punctuation separates words.
    static func matchKey(_ title: String) -> String {
        let folded = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "['’‘ʼ]", with: "", options: .regularExpression)
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// "Dune 1984" → ("Dune", 1984). Nil when the words don't end in a
    /// plausible release year or nothing precedes it.
    static func splitTrailingYear(_ term: String) -> (title: String, year: Int)? {
        var words = term.split(separator: " ")
        guard words.count >= 2,
              let last = words.last,
              last.count == 4,
              let year = Int(last),
              (1880...2100).contains(year) else {
            return nil
        }
        words.removeLast()
        return (words.joined(separator: " "), year)
    }
}
#endif
