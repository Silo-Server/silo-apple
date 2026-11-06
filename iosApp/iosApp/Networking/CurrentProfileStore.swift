import Foundation

/// Session-scoped holder for the active profile so top-bar avatars render
/// from one cached value instead of every root page refetching the profile
/// list on appearance and briefly flashing the fallback initial.
///
/// Follows the `RequestsFeatureStore` precedent: a `@MainActor` `@Observable`
/// singleton, loaded once per session and reset on profile/server switch.
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing capability-store calls.
@MainActor
@Observable
final class CurrentProfileStore {
    static let shared = CurrentProfileStore()

    /// Nil until the first successful load; the avatar renders a fallback.
    private(set) var profile: UserProfile?

    /// Bumped on every `reset()` so a load that finishes after a sign-out
    /// or profile switch discards its result instead of repopulating the
    /// next account's avatar.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    /// Load the active profile if it isn't cached yet. Concurrent callers
    /// share one request. Pass `force` to refetch after a known change.
    func refresh(force: Bool = false) async {
        if !force, profile != nil { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let gen = generation
        let task = Task {
            // A load that `reset()` superseded must not clear its successor.
            defer { if gen == generation { inFlight = nil } }
            guard let profileId = AuthService.shared.profileId else { return }
            guard let profiles = try? await AuthService.shared.getProfiles(),
                  gen == generation else { return }
            profile = profiles.first(where: { $0.id == profileId })
                .map { Self.keepingCachedAvatar($0, from: profile) }
        }
        inFlight = task
        await task.value
    }

    /// Take the active profile from a list read elsewhere, such as the one
    /// Settings reads on every visit.
    func adopt(_ fresh: UserProfile) {
        guard fresh.id == AuthService.shared.profileId else { return }
        profile = Self.keepingCachedAvatar(fresh, from: profile)
    }

    /// `fresh`, with `cached`'s avatar URL while both name the same avatar
    /// object under different signatures and its image is still cached.
    /// Every profile read re-signs an uploaded avatar's URL, and the new URL
    /// would download the same image again. Once the image leaves the cache,
    /// the fresh URL wins, so an expired signature never sticks.
    ///
    /// The server keeps an upload's key across re-uploads, so a new image
    /// uploaded elsewhere looks the same here until the old one is evicted.
    static func keepingCachedAvatar(_ fresh: UserProfile, from cached: UserProfile?) -> UserProfile {
        guard let cached, cached.id == fresh.id, cached.avatarEmoji == fresh.avatarEmoji,
              let cachedURL = avatarURL(of: cached), let freshURL = avatarURL(of: fresh),
              cachedURL != freshURL,
              let identity = ArtworkCacheKey.unsignedIdentity(for: cachedURL),
              identity == ArtworkCacheKey.unsignedIdentity(for: freshURL),
              PosterImageCache.cachedVariant(of: cachedURL, for: CGSize(width: 1, height: 1)) != nil else {
            return fresh
        }
        return UserProfile(
            id: fresh.id,
            name: fresh.name,
            avatarEmoji: fresh.avatarEmoji,
            avatarImageUrl: cached.avatarImageUrl,
            hasPin: fresh.hasPin,
            isChild: fresh.isChild,
            isPrimary: fresh.isPrimary,
            subtitleLanguage: fresh.subtitleLanguage,
            subtitleMode: fresh.subtitleMode,
            showForcedSubtitles: fresh.showForcedSubtitles,
            preferredMetadataLanguage: fresh.preferredMetadataLanguage
        )
    }

    private static func avatarURL(of profile: UserProfile) -> URL? {
        ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl).flatMap(URL.init(string:))
    }

    func reset() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        profile = nil
    }
}
