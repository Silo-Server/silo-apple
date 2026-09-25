#if os(iOS) || os(tvOS)
import Foundation

/// The titles Siri recognizes by name in Silo's own phrases ("Play The End
/// of Oak Street with Silo"): the profile's Continue Watching, Next Up,
/// watchlist, and recently added rows, refreshed whenever Home loads.
///
/// Apple caps App Shortcuts at 1,000 phrases, and every title counts once
/// per phrase template, so the list stays short. Titles outside it still
/// play through `PlayInSiloIntent`, which takes any spoken title.
enum SiriTitleCatalog {
    struct Title: Codable, Equatable, Sendable {
        let contentId: String
        let title: String
        let year: Int?
        let isSeries: Bool
    }

    private struct Stored: Codable, Equatable {
        let profileId: String
        let titles: [Title]
    }

    /// 60 titles × 10 phrase templates stays well inside Apple's limit.
    static let limit = 60
    private static let defaultsKey = "siri.titleCatalog.v1"

    /// The active profile's titles. Another profile's list is never offered.
    static func titles(
        defaults: UserDefaults = .standard,
        profileId: String? = AuthService.shared.profileId
    ) -> [Title] {
        guard let profileId,
              let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.profileId == profileId else { return [] }
        return stored.titles
    }

    /// Replaces the list from freshly loaded Home rows. Returns true when it
    /// changed, which is when Siri needs to re-read it.
    @discardableResult
    static func update(
        from sections: [ResolvedSection],
        profileId: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let profileId else { return false }
        let stored = Stored(profileId: profileId, titles: titles(from: sections))
        if let data = defaults.data(forKey: defaultsKey),
           let previous = try? JSONDecoder().decode(Stored.self, from: data),
           previous == stored {
            return false
        }
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    /// Movies and series from the rows people resume from first, then the
    /// rows they pick new things from. Episodes stand for their series.
    static func titles(from sections: [ResolvedSection]) -> [Title] {
        func rank(_ section: ResolvedSection) -> Int? {
            let type = section.sectionType.lowercased()
            if section.isContinueWatchingSection { return 0 }
            if type.contains("next") { return 1 }
            if type.contains("watchlist") { return 2 }
            if type.contains("recently_added") { return 3 }
            return nil
        }
        let ranked = sections
            .enumerated()
            .compactMap { index, section in rank(section).map { (rank: $0, index: index, section: section) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }

        var seen = Set<String>()
        var result: [Title] = []
        for entry in ranked {
            for item in entry.section.items {
                guard let title = title(for: item), seen.insert(title.contentId).inserted else { continue }
                result.append(title)
                if result.count == limit { return result }
            }
        }
        return result
    }

    private static func title(for item: SectionItem) -> Title? {
        if item.type.lowercased() == "episode" {
            guard let seriesId = item.seriesId, !seriesId.isEmpty,
                  let seriesTitle = item.seriesTitle, !seriesTitle.isEmpty else { return nil }
            return Title(contentId: seriesId, title: seriesTitle, year: nil, isSeries: true)
        }
        if SiloMediaType.isSeries(item.type) {
            return Title(contentId: item.contentId, title: item.title, year: item.year, isSeries: true)
        }
        if SiloMediaType.isMovieLibrary(item.type) {
            return Title(contentId: item.contentId, title: item.title, year: item.year, isSeries: false)
        }
        return nil
    }
}
#endif
