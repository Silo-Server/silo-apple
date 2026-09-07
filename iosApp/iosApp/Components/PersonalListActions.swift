import SwiftUI

/// The catalog surfaces that share displayed-owner membership semantics.
struct CatalogCardOwner: Equatable {
    let auth: CapturedOrdinaryRequestAuth
    let scope: String
    let filterKey: String
}

struct CatalogMembershipAction {
    let id: UUID
    let contentId: String
    let owner: CatalogCardOwner
    let generation: Int
    let target: APIv2PersonalListKind
    let included: Bool
}

@MainActor
protocol CatalogMembershipModel: AnyObject {
    var displayedRead: CatalogCardOwner? { get }
    var cardGeneration: Int { get }
    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CatalogMembershipAction?
    func performCardAction(_ action: CatalogMembershipAction) async -> Bool?
}

private struct CatalogMembershipModelKey: EnvironmentKey {
    static let defaultValue: (any CatalogMembershipModel)? = nil
}

private struct CatalogSearchModelKey: EnvironmentKey {
    static let defaultValue: SearchViewModel? = nil
}

private struct SavedPersonalListModelKey: EnvironmentKey {
    static let defaultValue: PersonalListViewModel? = nil
}

#if os(tvOS)
struct TVLibraryCardContext {
    let libraryId: Int
    let model: TVLibraryGridViewModel
}
#endif

struct LibraryCardAuthority: Equatable {
    let libraryId: Int
    let auth: CapturedOrdinaryRequestAuth?
}

private struct LibraryCardAuthorityKey: EnvironmentKey {
    static let defaultValue: LibraryCardAuthority? = nil
}

private struct HomePersonalListSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct HomePersonalListAuthKey: EnvironmentKey {
    static let defaultValue: CapturedOrdinaryRequestAuth? = nil
}

extension EnvironmentValues {
    var catalogMembershipModel: (any CatalogMembershipModel)? {
        get { self[CatalogMembershipModelKey.self] }
        set { self[CatalogMembershipModelKey.self] = newValue }
    }

    var catalogSearchModel: SearchViewModel? {
        get { self[CatalogSearchModelKey.self] }
        set { self[CatalogSearchModelKey.self] = newValue }
    }

    var savedPersonalListModel: PersonalListViewModel? {
        get { self[SavedPersonalListModelKey.self] }
        set { self[SavedPersonalListModelKey.self] = newValue }
    }

    var isHomePersonalListSurface: Bool {
        get { self[HomePersonalListSurfaceKey.self] }
        set { self[HomePersonalListSurfaceKey.self] = newValue }
    }

    var libraryCardAuthority: LibraryCardAuthority? {
        get { self[LibraryCardAuthorityKey.self] }
        set { self[LibraryCardAuthorityKey.self] = newValue }
    }

    var homePersonalListAuth: CapturedOrdinaryRequestAuth? {
        get { self[HomePersonalListAuthKey.self] }
        set { self[HomePersonalListAuthKey.self] = newValue }
    }
}

/// The favorite / watchlist entries shared by the media-card context
/// menus (long press on iOS/macOS, long press on the touch surface on
/// tvOS). Labels reflect the caller's current membership state; the
/// caller owns the optimistic flip and the API call.
struct PersonalListMenuItems: View {
    let isFavorite: Bool
    let inWatchlist: Bool
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void

    var body: some View {
        Group {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            Button(action: onToggleWatchlist) {
                Label(
                    inWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                    systemImage: inWatchlist ? "bookmark.slash" : "bookmark"
                )
            }
        }
    }
}

extension View {
    /// Attaches a long-press context menu with the given favorite /
    /// watchlist items, or leaves the view untouched when `nil` — so
    /// cards without a catalog identity never get an empty menu.
    @ViewBuilder
    func personalListContextMenu(_ items: PersonalListMenuItems?) -> some View {
        if let items {
            contextMenu { items }
        } else {
            self
        }
    }
}

/// Captured-owner server sync for Home and library landing cards. Successful
/// receipts invalidate derived caches without adopting unowned sibling state.
@MainActor
enum PersonalListSync {
    /// Home supplies the owner of its displayed response before scheduling.
    static func setHomeFavorite(contentId: String, isFavorite: Bool,
                                auth: CapturedOrdinaryRequestAuth,
                                api: SiloAPI = .shared, tokens: TokenStore = .shared) async -> Bool {
        do {
            try await api.toggleFavorite(contentId: contentId, isFavorite: isFavorite, auth: auth)
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil,
                  !Task.isCancelled else { return false }
            // Do not combine this receipt with an unscoped cached sibling flag.
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
            ResponseCache.shared.remove(CacheKey.favorites)
            ResponseCache.shared.remove(CacheKey.homeSections)
            return true
        } catch {
            return false
        }
    }

    /// Home supplies the owner of its displayed response before scheduling.
    static func setHomeWatchlist(contentId: String, inWatchlist: Bool,
                                auth: CapturedOrdinaryRequestAuth,
                                api: SiloAPI = .shared, tokens: TokenStore = .shared) async -> Bool {
        do {
            try await api.toggleWatchlist(contentId: contentId, isInWatchlist: inWatchlist, auth: auth)
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil,
                  !Task.isCancelled else { return false }
            // Do not combine this receipt with an unscoped cached sibling flag.
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
            ResponseCache.shared.remove(CacheKey.watchlist)
            ResponseCache.shared.remove(CacheKey.homeSections)
            return true
        } catch {
            return false
        }
    }

    static func setLibraryFavorite(contentId: String, isFavorite: Bool,
                                   owner: LibraryCardAuthority,
                                   api: SiloAPI = .shared, tokens: TokenStore = .shared) async -> Bool {
        guard let auth = owner.auth else { return false }
        do {
            try await api.toggleFavorite(contentId: contentId, isFavorite: isFavorite, auth: auth)
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil,
                  !Task.isCancelled else { return false }
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
            ResponseCache.shared.remove(CacheKey.favorites)
            let key = CacheKey.librarySections(owner.libraryId)
            let cached: APIv2LibrarySectionsRead? = ResponseCache.shared.get(key)
            if cached?.auth == auth { ResponseCache.shared.remove(key) }
            return true
        } catch { return false }
    }

    static func setLibraryWatchlist(contentId: String, inWatchlist: Bool,
                                   owner: LibraryCardAuthority,
                                   api: SiloAPI = .shared, tokens: TokenStore = .shared) async -> Bool {
        guard let auth = owner.auth else { return false }
        do {
            try await api.toggleWatchlist(contentId: contentId, isInWatchlist: inWatchlist, auth: auth)
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil,
                  !Task.isCancelled else { return false }
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
            ResponseCache.shared.remove(CacheKey.watchlist)
            let key = CacheKey.librarySections(owner.libraryId)
            let cached: APIv2LibrarySectionsRead? = ResponseCache.shared.get(key)
            if cached?.auth == auth { ResponseCache.shared.remove(key) }
            return true
        } catch { return false }
    }

}
