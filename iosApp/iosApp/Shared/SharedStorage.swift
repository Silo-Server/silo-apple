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

private enum RuntimeConfiguration {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "RuntimeConfiguration"
    )

    static let sharedKeychainAccessGroup: String? = {
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "ContinuumKeychainAccessGroup"
        ) as? String else {
            logger.error("Missing ContinuumKeychainAccessGroup Info.plist value; shared auth tokens may not persist.")
            return nil
        }
        if group.hasSuffix(".org.siloserver.silo.shared") {
            return group
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
           let dot = group.firstIndex(of: ".") {
            return String(group[...dot])
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

    init(service: String = SharedStorage.keychainService,
         accessGroup: String? = SharedStorage.keychainAccessGroup,
         audience: KeychainAudience = .currentUser,
         usesUserIndependentKeychain: Bool = RuntimeConfiguration.usesUserIndependentKeychain) {
        self.service = service
        self.accessGroup = accessGroup
        self.audience = audience
        self.usesUserIndependentKeychain = usesUserIndependentKeychain
    }

    func withAudience(_ audience: KeychainAudience) -> SharedKeychain {
        SharedKeychain(
            service: service,
            accessGroup: accessGroup,
            audience: audience,
            usesUserIndependentKeychain: usesUserIndependentKeychain
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
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            Self.logger.error("Keychain update failed for account \(account, privacy: .public): status=\(updateStatus, privacy: .public)")
            return false
        }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        Self.logger.error("Keychain add failed for account \(account, privacy: .public): status=\(addStatus, privacy: .public)")
        return false
    }

    func get(_ account: String) -> String? {
        if let found = read(account: account, accessGroup: accessGroup) {
            return found
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
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        Self.logger.error("Keychain delete failed for account \(account, privacy: .public): status=\(status, privacy: .public)")
        return false
    }

    // MARK: - Private

    private func read(account: String, accessGroup: String?) -> String? {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
