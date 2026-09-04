import Foundation
import OSLog
import Security

/// Cross-process storage used by the main app and the Top Shelf extension.
///
/// The Top Shelf extension runs in its own sandbox, so tokens and server
/// coordinates must be reachable from both sides:
/// - `UserDefaults(suiteName:)` backed by an App Group for preferences.
/// - Keychain items tagged with a shared `kSecAttrAccessGroup` for tokens.
///
/// The "topshelf" keychain accounts hold a mirrored copy of the *active*
/// server's access token + profile token under stable, server-independent
/// keys. The extension doesn't know the active server's ID, so it reads
/// these fixed-name slots instead of reconstructing the registry scheme.
enum SharedStorage {
    /// Must match the `com.apple.security.application-groups` entitlement
    /// on both the main app and the extension.
    static let appGroup = "group.org.siloserver.silo"

    /// Must match the `keychain-access-groups` entitlement on both sides.
    /// Resolved from a build-expanded Info.plist value so personal-team
    /// and paid-team builds can both read the same group they were signed for.
    static let keychainAccessGroup = RuntimeConfiguration.sharedKeychainAccessGroup

    /// Shared Keychain service name. Same on both sides.
    static let keychainService = "com.continuum.app"

    /// Stable account names for the mirrored active-server tokens.
    static let mirroredAccessTokenAccount = "com.continuum.topshelf.accessToken"
    static let mirroredProfileTokenAccount = "com.continuum.topshelf.profileToken"

    /// Long-lived, profile-scoped token the server returns from Apple push
    /// registration. The Notification Service extension prefers it over the
    /// mirrored access token because it cannot refresh an expired one.
    /// Written by `ApplePushRegistrationCoordinator`, cleared with the mirrors.
    static let applePushDisplayTokenAccount = "com.continuum.push.displayToken"
    /// App Group defaults key: RFC 3339 expiry of the stored display token,
    /// used by the app to renew it before the extension starts sending an
    /// expired credential. Not read by the extension.
    static let applePushDisplayTokenExpiresAtKey = "applePush.displayTokenExpiresAt"
    /// App Group defaults key: registry id of the server the stored display
    /// token was minted for. `TokenStore` clears the token only when the
    /// active server actually changes, not when the actor rehydrates the
    /// same persisted server on a cold launch.
    static let applePushDisplayTokenServerIdKey = "applePush.displayTokenServerId"

    static func accessTokenAccount(for serverID: String) -> String {
        "com.continuum.\(serverID).accessToken"
    }

    static func refreshTokenAccount(for serverID: String) -> String {
        "com.continuum.\(serverID).refreshToken"
    }

    static func profileTokenAccount(for serverID: String) -> String {
        "com.continuum.\(serverID).profileToken"
    }

    static func accountEpochAccount(for serverID: String) -> String {
        "com.continuum.\(serverID).accountEpoch"
    }

    /// UserDefaults keys shared between the app and the Top Shelf
    /// extension. Centralised here so the extension, `AuthService`,
    /// `TokenStore`, and `ServerRegistry` can't drift.
    static let serverUrlKey = "serverUrl"
    static let activeServerIdKey = "activeServerId"
    static let profileIdKey = "profileId"
    static let profileLaunchStateKey = "profileLaunchState.v1"

    /// Breadcrumb keys the Top Shelf extension writes after each run.
    /// The main app prints these on launch so device builds without a log
    /// stream attached to the extension process can still see what
    /// happened the last time tvOS invoked us.
    static let topShelfLastStatusKey = "topShelf.lastStatus"
    static let topShelfLastRunAtKey = "topShelf.lastRunAt"

    /// UserDefaults instance backed by the App Group suite. Callers that
    /// need per-process fallback behaviour should use `SharedDefaults`
    /// instead of touching this directly.
    static var suite: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }
}

enum SideloadKeychainFallbackPolicy {
    private static let canonicalAccessGroup = "org.siloserver.silo.shared"

    static func isEnabled(buildChannel: String, isPreIOS26: Bool) -> Bool {
        buildChannel == "sideload" && isPreIOS26
    }

    static func resolvedAccessGroup(
        from configuredValue: String,
        allowsUnprefixedSideloadGroup: Bool
    ) -> String? {
        if configuredValue.hasSuffix(".\(canonicalAccessGroup)") {
            return configuredValue
        }
        if allowsUnprefixedSideloadGroup,
           configuredValue == canonicalAccessGroup {
            return configuredValue
        }
        return nil
    }

    static func teamPrefix(from resolvedAccessGroup: String) -> String? {
        let sharedGroupSuffix = ".\(canonicalAccessGroup)"
        guard resolvedAccessGroup.hasSuffix(sharedGroupSuffix) else { return nil }
        return String(resolvedAccessGroup.dropLast(sharedGroupSuffix.count)) + "."
    }
}

private enum RuntimeConfiguration {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "RuntimeConfiguration"
    )

    /// Third-party re-signers commonly cannot preserve Silo's shared
    /// Keychain entitlement. On legacy iOS, keep core authentication usable
    /// by allowing the explicitly stamped sideload build to use the app's
    /// implicit Keychain group when Security reports that exact mismatch.
    /// Release/dev builds, iOS 26+, tvOS, and macOS retain the shared-only
    /// behavior.
    static let allowsAppLocalKeychainFallback: Bool = {
        #if os(iOS) && !DEBUG
        let rawChannel = Bundle.main.object(forInfoDictionaryKey: "SiloBuildChannel") as? String
        let buildChannel = rawChannel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isPreIOS26: Bool
        if #available(iOS 26.0, *) {
            isPreIOS26 = false
        } else {
            isPreIOS26 = true
        }
        return SideloadKeychainFallbackPolicy.isEnabled(
            buildChannel: buildChannel,
            isPreIOS26: isPreIOS26
        )
        #else
        return false
        #endif
    }()

    static let sharedKeychainAccessGroup: String? = {
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "ContinuumKeychainAccessGroup"
        ) as? String else {
            logger.error("Missing ContinuumKeychainAccessGroup Info.plist value; shared auth tokens may not persist.")
            return nil
        }
        if let resolved = SideloadKeychainFallbackPolicy.resolvedAccessGroup(
            from: group,
            allowsUnprefixedSideloadGroup: allowsAppLocalKeychainFallback
        ) {
            return resolved
        }
        logger.error("Unexpected ContinuumKeychainAccessGroup value: \(group, privacy: .public)")
        return nil
    }()

    static let usesUserIndependentKeychain: Bool = {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "ContinuumUsesUserIndependentKeychain"
        ) as? Bool {
            return value
        }
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "ContinuumUsesUserIndependentKeychain"
        ) as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }()

    static let legacyTeamPrefix: String? = {
        if let group = sharedKeychainAccessGroup,
           let prefix = SideloadKeychainFallbackPolicy.teamPrefix(from: group) {
            return prefix
        }
        logger.error("Could not derive team prefix from ContinuumKeychainAccessGroup; legacy keychain migration will only try the default access group.")
        return nil
    }()
}

/// Wrapper around the App Group `UserDefaults` that mirrors every write
/// back to `UserDefaults.standard`. Legacy readers (AuthService,
/// SettingsViewModel, ProfileAvatarView) that still read `.standard`
/// directly keep working; the Top Shelf extension sees the same values
/// via the App Group suite.
///
/// Reads prefer the suite and fall back to `.standard` so the first
/// launch after the upgrade transparently uses pre-existing values until
/// the next write mirrors them forward.
struct SharedDefaults: @unchecked Sendable {
    static let shared = SharedDefaults()

    let suite: UserDefaults
    private let standard: UserDefaults

    init(suite: UserDefaults = SharedStorage.suite, standard: UserDefaults = .standard) {
        self.suite = suite
        self.standard = standard
    }

    func string(forKey key: String) -> String? {
        suite.string(forKey: key) ?? standard.string(forKey: key)
    }

    func data(forKey key: String) -> Data? {
        suite.data(forKey: key) ?? standard.data(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        if suite.object(forKey: key) != nil { return suite.bool(forKey: key) }
        return standard.bool(forKey: key)
    }

    func containsObject(forKey key: String) -> Bool {
        suite.object(forKey: key) != nil || standard.object(forKey: key) != nil
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            suite.set(value, forKey: key)
            standard.set(value, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }

    func set(_ value: Data, forKey key: String) {
        suite.set(value, forKey: key)
        standard.set(value, forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        suite.set(value, forKey: key)
        standard.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        suite.removeObject(forKey: key)
        standard.removeObject(forKey: key)
    }
}

/// Minimal Keychain reader/writer targeted at the shared access group.
/// Used by both the main app (via `TokenStore`) and the Top Shelf
/// extension. Items are stored as generic passwords with accessibility
/// `AfterFirstUnlock` so the extension can read them when tvOS launches
/// it on the Home Screen (i.e. before any user interaction with the app).
struct SharedKeychain {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "SharedKeychain"
    )

    let service: String
    let accessGroup: String?
    let audience: KeychainAudience
    let usesUserIndependentKeychain: Bool
    let allowsAppLocalFallback: Bool

    init(service: String = SharedStorage.keychainService,
         accessGroup: String? = SharedStorage.keychainAccessGroup,
         audience: KeychainAudience = .currentUser,
         usesUserIndependentKeychain: Bool = RuntimeConfiguration.usesUserIndependentKeychain,
         allowsAppLocalFallback: Bool = RuntimeConfiguration.allowsAppLocalKeychainFallback) {
        self.service = service
        self.accessGroup = accessGroup
        self.audience = audience
        self.usesUserIndependentKeychain = usesUserIndependentKeychain
        self.allowsAppLocalFallback = allowsAppLocalFallback
    }

    func withAudience(_ audience: KeychainAudience) -> SharedKeychain {
        SharedKeychain(
            service: service,
            accessGroup: accessGroup,
            audience: audience,
            usesUserIndependentKeychain: usesUserIndependentKeychain,
            allowsAppLocalFallback: allowsAppLocalFallback
        )
    }

    /// Returns `true` when the value was successfully written. Callers
    /// performing a destructive migration (deleting a legacy copy after
    /// a successful re-save) must gate the delete on this return value.
    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.error("Failed to encode keychain value for account \(account, privacy: .public).")
            return false
        }
        let status = write(data, for: account, accessGroup: accessGroup)
        if status == errSecSuccess { return true }
        if shouldUseAppLocalFallback(for: status) {
            let fallbackStatus = write(data, for: account, accessGroup: nil)
            if fallbackStatus == errSecSuccess {
                Self.logger.notice("Shared Keychain entitlement unavailable; wrote app-local value.")
                return true
            }
            Self.logger.error("App-local Keychain fallback write failed: status=\(fallbackStatus, privacy: .public)")
            return false
        }
        Self.logger.error("Keychain write failed for account \(account, privacy: .public): status=\(status, privacy: .public)")
        return false
    }

    func get(_ account: String) -> String? {
        let configuredRead = readResult(account: account, accessGroup: accessGroup)
        if let found = configuredRead.value {
            return found
        }
        if shouldUseAppLocalFallback(for: configuredRead.status) {
            let fallbackRead = readResult(account: account, accessGroup: nil)
            if fallbackRead.status != errSecSuccess,
               fallbackRead.status != errSecItemNotFound {
                Self.logger.error("App-local Keychain fallback read failed: status=\(fallbackRead.status, privacy: .public)")
            }
            // The app-local group is the active store for this build. Return
            // directly instead of passing through legacy migration, which
            // would otherwise delete the same value it just found.
            return fallbackRead.value
        }
        #if os(tvOS)
        // Account credentials written before Runs-as-Current-User were stored
        // in the ordinary persona Keychain. Copy them into the shared account
        // audience only after a verified write, then retire that one legacy
        // copy. Profile tokens never take this path because their audience is
        // intentionally current-user scoped.
        if audience == .userIndependent {
            let legacyKeychain = withAudience(.currentUser)
            if let legacy = legacyKeychain.get(account) {
                if set(legacy, for: account) {
                    legacyKeychain.delete(account)
                }
                return legacy
            }
        }
        #endif
        // Transparent migration: pre-access-group entries live in the
        // app's bundle-id-based default access group. Once the app has
        // a `keychain-access-groups` entitlement, SecItemCopyMatching
        // with no `kSecAttrAccessGroup` does *not* always unify across
        // the default group and the entitlement groups on tvOS, so we
        // have to try each candidate access group explicitly.
        guard accessGroup != nil else { return nil }
        for candidate in Self.legacyFallbackAccessGroups() {
            guard let legacy = read(account: account, accessGroup: candidate) else { continue }
            // Only retire the legacy entry once the shared-access-group
            // write confirms. If the write fails, leave legacy in place.
            if set(legacy, for: account) {
                deleteLegacy(account: account, accessGroup: candidate)
            }
            return legacy
        }
        return nil
    }

    /// Candidate access groups we may have stored items in before the
    /// shared keychain group was added: the unified-search default
    /// (`nil`, which should in theory see items in any group the app
    /// can access), and the bundle's implicit access group derived from
    /// the team prefix + current bundle id. Computing the second at
    /// runtime keeps us correct across iOS / tvOS / debug / release.
    private static func legacyFallbackAccessGroups() -> [String?] {
        var groups: [String?] = [nil]
        if let bundleId = Bundle.main.bundleIdentifier,
           let teamPrefix = RuntimeConfiguration.legacyTeamPrefix {
            groups.append(teamPrefix + bundleId)
        }
        return groups
    }

    @discardableResult
    func delete(_ account: String) -> Bool {
        let status = deleteStatus(account: account, accessGroup: accessGroup)
        if status == errSecSuccess || status == errSecItemNotFound {
            guard allowsAppLocalFallback, accessGroup != nil else { return true }
            let cleanupStatus = deleteStatus(account: account, accessGroup: nil)
            if cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound {
                return true
            }
            Self.logger.error("App-local Keychain cleanup failed: status=\(cleanupStatus, privacy: .public)")
            return false
        }
        if shouldUseAppLocalFallback(for: status) {
            let fallbackStatus = deleteStatus(account: account, accessGroup: nil)
            if fallbackStatus == errSecSuccess || fallbackStatus == errSecItemNotFound {
                Self.logger.notice("Shared Keychain entitlement unavailable; deleted app-local value.")
                return true
            }
            Self.logger.error("App-local Keychain fallback delete failed: status=\(fallbackStatus, privacy: .public)")
            return false
        }
        Self.logger.error("Keychain delete failed for account \(account, privacy: .public): status=\(status, privacy: .public)")
        return false
    }

    // MARK: - Private

    private func read(account: String, accessGroup: String?) -> String? {
        readResult(account: account, accessGroup: accessGroup).value
    }

    private func readResult(account: String, accessGroup: String?) -> (status: OSStatus, value: String?) {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (status, nil)
        }
        return (status, String(data: data, encoding: .utf8))
    }

    private func write(_ data: Data, for account: String, accessGroup: String?) -> OSStatus {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        query.merge(attributes) { _, new in new }
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteStatus(account: String, accessGroup: String?) -> OSStatus {
        let query = baseQuery(account: account, accessGroup: accessGroup)
        return SecItemDelete(query as CFDictionary)
    }

    private func shouldUseAppLocalFallback(for status: OSStatus) -> Bool {
        allowsAppLocalFallback
            && accessGroup != nil
            && status == errSecMissingEntitlement
    }

    private func deleteLegacy(account: String, accessGroup: String?) {
        let query = baseQuery(account: account, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        baseQuery(account: account, accessGroup: accessGroup)
    }

    private func baseQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(tvOS)
        if audience == .userIndependent, usesUserIndependentKeychain {
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        }
        #endif
        return query
    }
}
