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

    /// What the iOS tab bar's last slot opens. Device-local and per profile,
    /// like `showAudiobooks`.
    private(set) var lastTab: LastTabChoice

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let storageKey: () -> String?

    init(
        defaults: SharedDefaults = .shared,
        storageKey: @escaping () -> String? = AppNavPreferences.showAudiobooksKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.showAudiobooks = Self.readShowAudiobooks(from: defaults, key: storageKey())
        self.lastTab = Self.readLastTab(from: defaults, key: storageKey())
    }

    /// Persist the choice for the active profile and update the observed
    /// mirror so visible navigation/search surfaces update immediately.
    func setShowAudiobooks(_ value: Bool) {
        showAudiobooks = value
        guard let key = storageKey() else { return }
        defaults.set(value, forKey: key)
    }

    /// Re-read the active profile's stored value. Call once the profile is
    /// known or after switching servers in place.
    func refresh() {
        showAudiobooks = Self.readShowAudiobooks(from: defaults, key: storageKey())
        lastTab = Self.readLastTab(from: defaults, key: storageKey())
    }

    func setLastTab(_ choice: LastTabChoice) {
        lastTab = choice
        guard let key = storageKey() else { return }
        defaults.set(choice.storageValue, forKey: Self.lastTabKey(key))
    }

    // MARK: - Storage

    private static func readShowAudiobooks(from defaults: SharedDefaults, key: String?) -> Bool {
        guard let key else { return defaultShowAudiobooks }
        guard defaults.containsObject(forKey: key) else {
            return defaultShowAudiobooks
        }
        return defaults.bool(forKey: key)
    }

    private static func readLastTab(from defaults: SharedDefaults, key: String?) -> LastTabChoice {
        guard let key,
              let raw = defaults.string(forKey: lastTabKey(key)),
              let choice = LastTabChoice(storageValue: raw)
        else { return .downloads }
        return choice
    }

    /// Shares the audiobook key's server/profile scope.
    private static func lastTabKey(_ scopedKey: String) -> String {
        "\(scopedKey).lastTab"
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

    /// Contract default for `nav.show_audiobooks`: this is an opt-in surface
    /// on every Apple platform. A stored per-profile choice still wins.
    private static let defaultShowAudiobooks = false

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
}
