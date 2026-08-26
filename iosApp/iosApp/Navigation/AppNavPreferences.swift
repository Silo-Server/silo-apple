import Foundation
import Observation

/// Local, per-profile navigation/content preferences.
///
/// The preference is device-local and scoped by platform, server, and profile:
/// hiding audiobooks on Apple TV should not hide them on iPhone. tvOS keeps
/// its original storage key for compatibility with existing installs.
@Observable
final class AppNavPreferences {
    static let shared = AppNavPreferences()

    /// Whether audiobook library/search surfaces are shown for this platform.
    private(set) var showAudiobooks: Bool
    /// Whether iPhone and iPad Home promote the featured section into a hero.
    private(set) var showFeaturedHero: Bool
    /// Whether the mobile featured hero uses rounded poster-card framing.
    private(set) var useFeaturedHeroCards: Bool

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let storageKey: () -> String?
    @ObservationIgnored private let featuredHeroStorageKey: () -> String?
    @ObservationIgnored private let featuredHeroCardsStorageKey: () -> String?

    init(
        defaults: SharedDefaults = .shared,
        storageKey: @escaping () -> String? = AppNavPreferences.showAudiobooksKey,
        featuredHeroStorageKey: @escaping () -> String? = AppNavPreferences.showFeaturedHeroKey,
        featuredHeroCardsStorageKey: @escaping () -> String? = AppNavPreferences.useFeaturedHeroCardsKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.featuredHeroStorageKey = featuredHeroStorageKey
        self.featuredHeroCardsStorageKey = featuredHeroCardsStorageKey
        self.showAudiobooks = Self.readShowAudiobooks(from: defaults, key: storageKey())
        self.showFeaturedHero = Self.readShowFeaturedHero(
            from: defaults,
            key: featuredHeroStorageKey()
        )
        self.useFeaturedHeroCards = Self.readUseFeaturedHeroCards(
            from: defaults,
            key: featuredHeroCardsStorageKey()
        )
    }

    /// Persist the choice for the active profile and update the observed
    /// mirror so visible navigation/search surfaces update immediately.
    func setShowAudiobooks(_ value: Bool) {
        showAudiobooks = value
        guard let key = storageKey() else { return }
        defaults.set(value, forKey: key)
    }

    /// Persist hero visibility locally and update Home immediately.
    func setShowFeaturedHero(_ value: Bool) {
        showFeaturedHero = value
        guard let key = featuredHeroStorageKey() else { return }
        defaults.set(value, forKey: key)
    }

    /// Switch between rounded poster cards and an unframed full-width hero.
    func setUseFeaturedHeroCards(_ value: Bool) {
        useFeaturedHeroCards = value
        guard let key = featuredHeroCardsStorageKey() else { return }
        defaults.set(value, forKey: key)
    }

    /// Re-read the active profile's stored value. Call once the profile is
    /// known or after switching servers in place.
    func refresh() {
        showAudiobooks = Self.readShowAudiobooks(from: defaults, key: storageKey())
        showFeaturedHero = Self.readShowFeaturedHero(
            from: defaults,
            key: featuredHeroStorageKey()
        )
        useFeaturedHeroCards = Self.readUseFeaturedHeroCards(
            from: defaults,
            key: featuredHeroCardsStorageKey()
        )
    }

    // MARK: - Storage

    private static func readShowAudiobooks(from defaults: SharedDefaults, key: String?) -> Bool {
        guard let key else { return defaultShowAudiobooks }
        guard defaults.containsObject(forKey: key) else {
            return defaultShowAudiobooks
        }
        return defaults.bool(forKey: key)
    }

    private static func readShowFeaturedHero(from defaults: SharedDefaults, key: String?) -> Bool {
        guard let key else { return defaultShowFeaturedHero }
        guard defaults.containsObject(forKey: key) else {
            return defaultShowFeaturedHero
        }
        return defaults.bool(forKey: key)
    }

    private static func readUseFeaturedHeroCards(from defaults: SharedDefaults, key: String?) -> Bool {
        guard let key else { return defaultUseFeaturedHeroCards }
        guard defaults.containsObject(forKey: key) else {
            return defaultUseFeaturedHeroCards
        }
        return defaults.bool(forKey: key)
    }

    private static func showAudiobooksKey() -> String? {
        // No profile -> nothing to scope. Persisting under an anonymous key
        // would leak one user's choice into the next signed-in profile.
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "\(storagePrefix).\(serverId).\(profileId)"
    }

    private static func showFeaturedHeroKey() -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "\(featuredHeroStoragePrefix).\(serverId).\(profileId)"
    }

    private static func useFeaturedHeroCardsKey() -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "\(featuredHeroCardsStoragePrefix).\(serverId).\(profileId)"
    }

    /// Contract default for `nav.show_audiobooks`: this is an opt-in surface
    /// on every Apple platform. A stored per-profile choice still wins.
    private static let defaultShowAudiobooks = false
    private static let defaultShowFeaturedHero = true
    private static let defaultUseFeaturedHeroCards = true

    private static var storagePrefix: String {
        #if os(tvOS)
        "skyline.nav.showAudiobooks"
        #elseif os(iOS)
        "ios.nav.showAudiobooks"
        #elseif os(macOS)
        "mac.nav.showAudiobooks"
        #else
        "apple.nav.showAudiobooks"
        #endif
    }

    private static var featuredHeroStoragePrefix: String {
        #if os(iOS)
        "ios.home.showFeaturedHero"
        #elseif os(tvOS)
        "skyline.home.showFeaturedHero"
        #elseif os(macOS)
        "mac.home.showFeaturedHero"
        #else
        "apple.home.showFeaturedHero"
        #endif
    }

    private static var featuredHeroCardsStoragePrefix: String {
        #if os(iOS)
        "ios.home.useFeaturedHeroCards"
        #elseif os(tvOS)
        "skyline.home.useFeaturedHeroCards"
        #elseif os(macOS)
        "mac.home.useFeaturedHeroCards"
        #else
        "apple.home.useFeaturedHeroCards"
        #endif
    }
}
