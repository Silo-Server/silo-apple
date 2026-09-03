/// Pure transformations for profile-scoped Home section state.
///
/// Keeping the transformation independent from the view model lets the live
/// screen and `ResponseCache` apply exactly the same update after a mutation.
enum HomeSectionsMutation {
    private static let continueWatchingSectionTypes: Set<String> = [
        "continue_watching",
        "in_progress",
    ]
    private static let completedItemSectionTypes: Set<String> = [
        "continue_watching",
        "in_progress",
        "next_up",
    ]

    static func removingContinueWatchingItem(
        contentId: String,
        from sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        removingItem(
            contentId: contentId,
            from: sections,
            sectionTypes: continueWatchingSectionTypes
        )
    }

    /// Removes a dismissed Next Up episode. The server surfaces Next Up both
    /// as its own row and merged into Continue Watching, so both must drop it.
    static func removingNextUpItem(
        contentId: String,
        from sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        removingItem(
            contentId: contentId,
            from: sections,
            sectionTypes: completedItemSectionTypes
        )
    }

    /// Removes a newly completed item from rows whose membership is derived
    /// from playback state. Other Home rows can still show the same title.
    static func removingCompletedItem(
        contentId: String,
        from sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        removingItem(
            contentId: contentId,
            from: sections,
            sectionTypes: completedItemSectionTypes
        )
    }

    private static func removingItem(
        contentId: String,
        from sections: [ResolvedSection],
        sectionTypes: Set<String>
    ) -> [ResolvedSection] {
        sections.map { section in
            guard sectionTypes.contains(section.sectionType.lowercased()) else {
                return section
            }

            let items = section.items.filter { $0.contentId != contentId }
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
