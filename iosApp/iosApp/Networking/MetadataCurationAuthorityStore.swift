#if os(iOS)
import Foundation

/// Pure client-side mirror of `web/src/lib/permissions.ts` and `MediaItemMenu.tsx`.
///
/// Admin powers apply only on the admin account's primary household profile
/// (or when no profile is selected). When an active `profileId` is selected,
/// fail closed until the matching `UserProfile` record has loaded so a kid or
/// non-primary profile never briefly sees admin curation chrome.
enum MetadataCurationPolicy {
    static let permissionMetadataCuration = "metadata_curation"

    static func isActingAdmin(
        account: APIv2Account?,
        profile: UserProfile?,
        activeProfileId: String? = nil
    ) -> Bool {
        guard account?.role == .admin else { return false }
        if let activeProfileId, !activeProfileId.isEmpty {
            guard let profile, profile.id == activeProfileId else { return false }
            return profile.isPrimary
        }
        guard let profile else { return true }
        return profile.isPrimary
    }

    static func hasPermission(
        _ permission: String,
        account: APIv2Account?,
        profile: UserProfile?,
        activeProfileId: String? = nil
    ) -> Bool {
        guard let account else { return false }
        if isActingAdmin(account: account, profile: profile, activeProfileId: activeProfileId) {
            return true
        }
        return account.permissions?.contains(permission) == true
    }

    static func canCurateMetadata(
        account: APIv2Account?,
        profile: UserProfile?,
        activeProfileId: String? = nil
    ) -> Bool {
        hasPermission(
            permissionMetadataCuration,
            account: account,
            profile: profile,
            activeProfileId: activeProfileId
        )
    }

    static func canEditArtwork(
        account: APIv2Account?,
        profile: UserProfile?,
        activeProfileId: String? = nil
    ) -> Bool {
        isActingAdmin(account: account, profile: profile, activeProfileId: activeProfileId)
    }
}

/// Session-scoped holder for the signed-in account's curation permissions.
/// Follows the `CurrentProfileStore` / `RequestsFeatureStore` pattern: loaded
/// once per authenticated session and reset on sign-out or server switch.
@MainActor
@Observable
final class MetadataCurationAuthorityStore {
    static let shared = MetadataCurationAuthorityStore()

    private(set) var account: APIv2Account?

    private var generation = 0
    private var inFlight: Task<Void, Never>?

    private var activeProfileId: String? {
        AuthService.shared.profileId
    }

    var isActingAdmin: Bool {
        MetadataCurationPolicy.isActingAdmin(
            account: account,
            profile: CurrentProfileStore.shared.profile,
            activeProfileId: activeProfileId
        )
    }

    var canCurateMetadata: Bool {
        MetadataCurationPolicy.canCurateMetadata(
            account: account,
            profile: CurrentProfileStore.shared.profile,
            activeProfileId: activeProfileId
        )
    }

    var canEditArtwork: Bool {
        MetadataCurationPolicy.canEditArtwork(
            account: account,
            profile: CurrentProfileStore.shared.profile,
            activeProfileId: activeProfileId
        )
    }

    func refresh(force: Bool = false) async {
        if !force, account != nil { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let gen = generation
        let task = Task {
            defer { if gen == generation { inFlight = nil } }
            guard let fetched = try? await SiloAPI.shared.apiV2Client.currentUser(),
                  gen == generation else { return }
            account = fetched
        }
        inFlight = task
        await task.value
    }

    func reset() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        account = nil
    }
}

// MARK: - Curation Change Broadcast & Cache Invalidation

struct MetadataItemChangeEvent: Equatable, Sendable {
    let contentId: String
    let replacedByContentId: String?
    let seriesId: String?
}

extension Notification.Name {
    /// Posted after metadata, artwork, match, or refresh changes land so open
    /// detail views reload (or swap `contentId`) and grids refetch updated DTOs.
    static let metadataItemDidChange = Notification.Name("Silo.metadataItemDidChange")
}

@MainActor
enum MetadataCurationCache {
    static func invalidateAfterMutation(
        contentId: String,
        replacedByContentId: String? = nil,
        seriesId: String? = nil
    ) {
        let cache = ResponseCache.shared

        // `removeItemMetadata` evicts both the exact `item:<id>` entry and its
        // colon-delimited family (`:seasons`, `:watchDetail`, `:similar`, …)
        // without touching sibling IDs that share a prefix (e.g., `movie:1` vs `movie:10`).
        cache.removeItemMetadata(contentId: contentId)

        if let replacedByContentId, replacedByContentId != contentId {
            cache.removeItemMetadata(contentId: replacedByContentId)
        }

        let effectiveSeriesId = seriesId ?? (contentId.hasPrefix("series:") ? contentId : nil)
        if let effectiveSeriesId {
            cache.removeItemMetadata(contentId: effectiveSeriesId)
        }

        // Clear Home, recommendations, library section rows, and browse grids
        // using the exact key families from `CacheKey`.
        cache.remove(CacheKey.homeSections)
        cache.remove(CacheKey.recommendations)
        cache.removeAll(withPrefix: "library:")
        cache.removeAll(withPrefix: "browse:")

        let event = MetadataItemChangeEvent(
            contentId: contentId,
            replacedByContentId: replacedByContentId,
            seriesId: effectiveSeriesId
        )
        NotificationCenter.default.post(name: .metadataItemDidChange, object: event)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }
}
#endif
