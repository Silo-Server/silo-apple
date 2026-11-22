import Foundation

/// Names the owner of a personal collection that another profile on this
/// login made and shared, for the "by Name" line under its card.
enum CollectionOwnerName {
    /// The owner's name, or nil for the acting profile's own collection, for
    /// a server collection, and for a profile missing from `profiles`.
    static func otherProfile(
        _ creatorProfileId: String?,
        actingProfileId: String?,
        profiles: [UserProfile]?
    ) -> String? {
        guard let creatorProfileId, creatorProfileId != actingProfileId else { return nil }
        return profiles?.first(where: { $0.id == creatorProfileId })?.name
    }

    /// The "by Name" line for `card`, from the acting profile and `profiles`.
    @MainActor
    static func byline(for card: SectionCollectionCard, profiles: [UserProfile]?, locale: Locale) -> String? {
        otherProfile(card.creatorProfileId, actingProfileId: AuthService.shared.profileId, profiles: profiles)
            .map { AppLanguage.string(.collectionsCardByOwner($0), locale: locale) }
    }

    /// The "by Name" line for `card`, from the cached profile list of this login.
    @MainActor
    static func byline(for card: SectionCollectionCard, locale: Locale) -> String? {
        byline(for: card, profiles: ResponseCache.shared.get(CacheKey.profiles), locale: locale)
    }

    /// Whether any card in `cards` was made by another profile, so its row
    /// needs the profile list to name the owner.
    @MainActor
    static func needsProfiles(_ cards: [SectionCollectionCard]) -> Bool {
        let acting = AuthService.shared.profileId
        return cards.contains { $0.creatorProfileId.map { $0 != acting } ?? false }
    }

    /// The profile list of this login: the cached one, else the startup
    /// read (joined when it is still in flight). Nil when it can't be read;
    /// the cards then show their type line instead of the owner.
    @MainActor
    static func profiles() async -> [UserProfile]? {
        if let cached: [UserProfile] = ResponseCache.shared.get(CacheKey.profiles) { return cached }
        return try? await StartupContentPrefetcher.fetchProfiles()
    }
}
