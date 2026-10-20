/// Which Home list a card's dismissal goes to, and so what its menu calls it.
///
/// The server keys the two lists differently. In-progress items are
/// dismissed against their exact `progress_updated_at`, so resuming playback
/// re-surfaces them. Next Up episodes have no progress row; they are
/// dismissed on the `next_up` surface keyed by series. Sending a fabricated
/// timestamp for a Next Up card is accepted by the server but never matches
/// anything, so the card returns on the next fresh fetch.
enum HomeDismissal: Equatable {
    case continueWatching(progressUpdatedAt: String)
    case nextUp(seriesId: String)

    /// `nil` when neither surface can represent the card.
    init?(_ item: SectionItem) {
        if let progressUpdatedAt = item.progressUpdatedAt, !progressUpdatedAt.isEmpty {
            self = .continueWatching(progressUpdatedAt: progressUpdatedAt)
        } else if let seriesId = item.seriesId, !seriesId.isEmpty {
            self = .nextUp(seriesId: seriesId)
        } else {
            return nil
        }
    }

    /// The long-press label names the list the card is removed from.
    static func menuTitle(for item: SectionItem) -> String {
        if case .nextUp = HomeDismissal(item) {
            return "Remove from Next Up"
        }
        return "Remove from Continue Watching"
    }
}

/// Pure transformations for profile-scoped Home section state.
///
/// Keeping the transformation independent from the view model lets the live
/// screen and `ResponseCache` apply exactly the same update after a mutation.
enum HomeSectionsMutation {
    private static let playbackSectionTypes: Set<String> = [
        "continue_watching",
        "in_progress",
        "next_up",
    ]

    /// Removes a dismissed card from the rows built from playback state.
    /// Dismissing an episode or a series drops the whole show on the server,
    /// from either list, so every card of that series leaves those rows too.
    /// Next Up appears both as its own row and merged into Continue Watching.
    static func removingDismissedItem(
        _ item: SectionItem,
        from sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        let seriesId = droppedSeriesId(for: item)
        return removingItems(from: sections, sectionTypes: playbackSectionTypes) { card in
            card.contentId == item.contentId
                || seriesId.map { card.contentId == $0 || card.seriesId == $0 } ?? false
        }
    }

    /// Removes a newly completed item from rows whose membership is derived
    /// from playback state. Other Home rows can still show the same title.
    static func removingCompletedItem(
        contentId: String,
        from sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        removingItems(from: sections, sectionTypes: playbackSectionTypes) { $0.contentId == contentId }
    }

    /// The show the server drops for this card's dismissal: an episode's
    /// series, or the series itself. Movies and books go one card at a time.
    private static func droppedSeriesId(for item: SectionItem) -> String? {
        if SiloMediaType.isSeries(item.type) { return item.contentId }
        guard SiloMediaType.isEpisode(item.type),
              let seriesId = item.seriesId, !seriesId.isEmpty else { return nil }
        return seriesId
    }

    private static func removingItems(
        from sections: [ResolvedSection],
        sectionTypes: Set<String>,
        where isRemoved: (SectionItem) -> Bool
    ) -> [ResolvedSection] {
        sections.map { section in
            guard sectionTypes.contains(section.sectionType.lowercased()) else {
                return section
            }

            let items = section.items.filter { !isRemoved($0) }
            let removedCount = section.items.count - items.count
            guard removedCount > 0 else { return section }

            return ResolvedSection(
                id: section.id,
                sectionType: section.sectionType,
                title: section.title,
                featured: section.featured,
                itemLimit: section.itemLimit,
                totalCount: section.totalCount.map { max(0, $0 - removedCount) },
                isCustom: section.isCustom,
                customized: section.customized,
                items: items
            )
        }
    }
}
