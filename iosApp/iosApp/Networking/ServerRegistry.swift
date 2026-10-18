import Foundation
import OSLog
import Synchronization

/// A single Silo server the user has added to the device.
///
/// The registry stores one of these per remembered server. Tokens live in
/// Keychain keyed by `id`, never in the entry itself. The display name is
/// always server-administered through the advertised `fetchedName`.
struct ServerEntry: Codable, Identifiable, Equatable, Hashable {
    /// Stable client-derived ID: base64url of the normalized URL; reversible
    /// via `url(forServerId:)`.
    let id: String

    /// Normalized base URL (trailing slash stripped, whitespace trimmed).
    var url: String

    /// Advertised by native branding. Filled on first successful connect and
    /// refreshed on server activation.
    var fetchedName: String?

    /// When this server was last activated. Used only for sorting the
    /// list; not part of identity.
    var lastUsedAt: Date

    /// The deployment identity the server reported from
    /// `GET /api/v2/system/identity` at this URL. It lets one deployment be
    /// recognised across public, LAN, and network-plugin addresses without
    /// changing `id`, which still keys credentials and settings. Self-asserted:
    /// it groups and matches servers but never authorizes anything by itself.
    var verifiedServerId: String?

    /// Display label for lists/menus. Server-advertised name → URL.
    var displayName: String {
        if let name = fetchedName, !name.isEmpty { return name }
        return url
    }

    /// Read only while migrating the pre-profile-launch registry schema. New
    /// registry writes deliberately omit profile identity because the server
    /// list is shared across Apple TV users while profile choice is not.
    fileprivate(set) var legacyProfileId: String?

    init(
        id: String,
        url: String,
        fetchedName: String?,
        profileId: String? = nil,
        lastUsedAt: Date,
        verifiedServerId: String? = nil
    ) {
        self.id = id
        self.url = url
        self.fetchedName = fetchedName
        self.lastUsedAt = lastUsedAt
        self.legacyProfileId = profileId
        self.verifiedServerId = ServerIdentity.usable(verifiedServerId)
    }

    /// This entry under `existing`'s id and URL.
    fileprivate func keepingIdentity(of existing: ServerEntry) -> ServerEntry {
        guard existing.id != id else { return self }
        var copy = ServerEntry(
            id: existing.id,
            url: existing.url,
            fetchedName: fetchedName,
            lastUsedAt: lastUsedAt,
            verifiedServerId: verifiedServerId
        )
        copy.legacyProfileId = legacyProfileId
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case fetchedName
        case profileId
        case lastUsedAt
        case verifiedServerId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        fetchedName = try container.decodeIfPresent(String.self, forKey: .fetchedName)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        legacyProfileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        verifiedServerId = ServerIdentity.usable(
            try container.decodeIfPresent(String.self, forKey: .verifiedServerId)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(fetchedName, forKey: .fetchedName)
        // Retain pre-split profile identity only until its current-user
        // launch mapping has been durably written and read back. New entries
        // always leave this nil, so normal registry payloads contain no
        // profile identity.
        try container.encodeIfPresent(legacyProfileId, forKey: .profileId)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(verifiedServerId, forKey: .verifiedServerId)
    }
}

/// Wire shape for the persisted registry. Kept as a separate struct so a
/// future schema bump can change keys without breaking `ServerEntry`.
private struct RegistryState: Codable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

private struct SharedRegistryState: Codable {
    var entries: [ServerEntry]
}

enum ServerRegistryError: LocalizedError {
    case persistenceFailed

    var errorDescription: String? {
        "Silo couldn't save the server list. Please try again."
    }
}

/// Owns the list of known Silo servers and which one is currently
/// active. Singleton via `.shared`; observed by SwiftUI via `@Observable`.
///
/// Per-server persistence splits across two stores:
/// - **UserDefaults** (`siloServerRegistry.v1`): the server list and
///   active ID on iOS/macOS. tvOS stores the shared list in the
///   user-independent Keychain and the active ID in current-user defaults.
/// - **Keychain**: saved sign-ins and per-server sessions, owned by
///   `TokenStore`.
///
/// The registry is the single source of truth for URL + name.
/// TokenStore is the single source of truth for tokens. A server can be
/// saved without a sign-in, and several users can sign in to one server.
/// They coordinate through `switchTo` — the registry writes the active ID
/// and the active URL to UserDefaults, then tells TokenStore which
/// credential on that server to select.
@Observable
final class ServerRegistry {
    static let shared = ServerRegistry()

    private let activeServerSnapshot = Mutex<String?>(nil)

    /// Actor-safe identity snapshot for background coordinators. SwiftUI uses
    /// the observable instance property below, while async services use this
    /// lock-protected mirror instead of racing that mutable UI state.
    static var activeServerIDSnapshot: String? {
        shared.activeServerSnapshot.withLock { $0 }
    }

    static let defaultsKey = SharedStorage.serverRegistryDefaultsKey
    static let migratedKey = "siloServerRegistry.migrated.v1"
    /// Pre-rename names of the two keys above; `adoptLegacyDefaultsKeys`
    /// moves them once.
    private static let legacyDefaultsKey = "continuumServerRegistry.v1"
    private static let legacyMigratedKey = "continuumServerRegistry.migrated.v1"
    private static let sharedTVRegistryAccount = SharedStorage.serverRegistryAccount
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ServerRegistry"
    )

    // Active server state. Synchronous reads from SwiftUI bodies and async
    // reads from HTTPClient both flow through these. Mutation always goes
    // through `persist()` to keep UserDefaults and `@Observable` views in
    // sync.
    private(set) var entries: [ServerEntry] = []
    private(set) var activeServerId: String? {
        didSet {
            let value = activeServerId
            activeServerSnapshot.withLock { $0 = value }
        }
    }

    private let defaults: SharedDefaults
    private let keychain: SharedKeychain
    private let launchPreferences: ProfileLaunchPreferences
    private let tokenStore: TokenStore
    private let httpClient: HTTPClient
    private let persistenceOverride: (([ServerEntry], String?) -> Bool)?
    /// Turns the server's push registration off (`ApplePushRegistrationCoordinator.unregister`).
    private let unregisterPush: @Sendable (String) async -> Void
    /// Turns it back on after a removal that did not happen (`ApplePushRegistrationCoordinator.restore`).
    private let restorePush: @Sendable (String) async -> Void
    /// The identity-boundary cache wipe (`AuthService.clearCachesForServerChange`).
    private let clearCaches: @MainActor () async -> Void
    /// Whether the selected credential is signed in (`AuthService.isLoggedIn`).
    private let isLoggedIn: () -> Bool
    /// Restores the destination's remembered profile under the switch's lease
    /// (`AuthService.resolveActiveProfileForSession(holding:)`).
    private let resolveProfile: (HTTPIdentityTransitionLease) async -> Bool
    /// True while `activeServerId` came from a fallback (the newest entry at
    /// load, or the survivor of a removal) rather than from this Apple TV
    /// user (or device) opening it. Saved beside the per-user mirror, which
    /// keeps naming the fallback for sync readers, so a later launch doesn't
    /// mistake it for history either.
    @ObservationIgnored private var activeServerIsFallback = false {
        didSet {
            guard activeServerIsFallback != oldValue else { return }
            if activeServerIsFallback {
                defaults.set(true, forKey: Self.activeServerFallbackKey)
            } else {
                defaults.removeObject(forKey: Self.activeServerFallbackKey)
            }
        }
    }
    /// Per-user defaults: the active-server mirror names a fallback.
    /// `TokenStore.launchSelection` reads it too.
    static let activeServerFallbackKey = "activeServerIdIsFallback"

    /// The server this Apple TV user (or device) last opened, as the
    /// per-user `activeServerId` mirror recorded it. Nil when nobody chose
    /// the active server, such as a new Apple TV user's first launch, so the
    /// launch rules don't mistake a fallback for history (plan §2.8 rule 4).
    var activeServerMirror: String? {
        activeServerIsFallback ? nil : activeServerId
    }

    init(
        defaults: SharedDefaults = .shared,
        keychain: SharedKeychain = SharedKeychain(),
        launchPreferences: ProfileLaunchPreferences = .shared,
        persistenceOverride: (([ServerEntry], String?) -> Bool)? = nil,
        tokenStore: TokenStore = .shared,
        httpClient: HTTPClient = .shared,
        unregisterPush: @escaping @Sendable (String) async -> Void = { serverID in
            #if os(iOS)
            await ApplePushRegistrationCoordinator.shared.unregister(serverID: serverID)
            #endif
        },
        restorePush: @escaping @Sendable (String) async -> Void = { serverID in
            #if os(iOS)
            await ApplePushRegistrationCoordinator.shared.restore(serverID: serverID)
            #endif
        },
        clearCaches: @escaping @MainActor () async -> Void = { await AuthService.shared.clearCachesForServerChange() },
        isLoggedIn: @escaping () -> Bool = { AuthService.shared.isLoggedIn },
        resolveProfile: @escaping (HTTPIdentityTransitionLease) async -> Bool = {
            await AuthService.shared.resolveActiveProfileForSession(holding: $0)
        }
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.launchPreferences = launchPreferences
        self.persistenceOverride = persistenceOverride
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.unregisterPush = unregisterPush
        self.restorePush = restorePush
        self.clearCaches = clearCaches
        self.isLoggedIn = isLoggedIn
        self.resolveProfile = resolveProfile
        Self.adoptLegacyDefaultsKeys(defaults)
        load()
        migrateLegacyIfNeeded()
        migrateLegacyProfileMappingsIfNeeded()
        let initialActiveServerId = activeServerId
        activeServerSnapshot.withLock { $0 = initialActiveServerId }
    }

    // MARK: - Sync accessors (SwiftUI-safe)

    var activeServer: ServerEntry? {
        guard let id = activeServerId else { return nil }
        return entries.first(where: { $0.id == id })
    }

    var activeServerUrl: String { activeServer?.url ?? "" }
    var activeProfileId: String? { defaults.string(forKey: SharedStorage.profileIdKey) }
    var hasActiveServer: Bool { activeServer != nil }

    // MARK: - Lookups

    func entry(with id: String) -> ServerEntry? {
        entries.first(where: { $0.id == id })
    }

    /// Sort for the picker: active first, then most-recently-used.
    var sortedEntries: [ServerEntry] {
        entries.sorted { a, b in
            if a.id == activeServerId { return true }
            if b.id == activeServerId { return false }
            return a.lastUsedAt > b.lastUsedAt
        }
    }

    // MARK: - Mutations

    /// Insert or update an entry. `preservingProfile: false` forgets the
    /// profile remembered for the server's own session (before sign-ins, or
    /// a pending legacy server); saved sign-ins keep theirs, because a new
    /// session for one of them clears only its own.
    @discardableResult
    func addOrUpdate(_ entry: ServerEntry, preservingProfile: Bool = true) -> ServerEntry? {
        let previousEntries = entries
        var merged = entry
        let existingIndex = index(matching: entry.id)
        if let existingIndex {
            let existing = entries[existingIndex]
            // A saved entry for the same origin keeps its id and URL, which
            // key its credentials and settings, even when this one differs
            // only in scheme or host case.
            merged = entry.keepingIdentity(of: existing)
            if merged.fetchedName == nil || merged.fetchedName?.isEmpty == true {
                merged.fetchedName = existing.fetchedName
            }
            if merged.verifiedServerId == nil {
                merged.verifiedServerId = existing.verifiedServerId
            }
            entries[existingIndex] = merged
        } else {
            entries.append(merged)
        }
        let isExistingEntry = existingIndex != nil
        guard persist() else {
            entries = previousEntries
            _ = persist()
            // "Add server" silently doing nothing is a top unreproducible
            // report; on tvOS this means the shared Keychain write failed.
            recordRegistryEvent(
                phase: "addServer",
                outcome: "failed",
                reason: "persistFailed"
            )
            return nil
        }
        registerDiagnosticsSensitiveHosts([entry])
        // Emitted after host registration, not before: this line carries no
        // hostname, but on the very first add there is a window where the
        // redactor does not yet know this host, and no diagnostics line should
        // be written inside it.
        recordRegistryEvent(
            phase: "addServer",
            outcome: "succeeded",
            reason: isExistingEntry ? "updatedExisting" : "addedNew"
        )
        if !preservingProfile {
            launchPreferences.forgetLegacyProfile(forServer: merged.id)
        }
        return merged
    }

    /// The saved entry for `serverId`'s origin: an exact id, else one whose
    /// scheme and host differ only in case (or that spells out a default port).
    func entry(matching serverId: String) -> ServerEntry? {
        index(matching: serverId).map { entries[$0] }
    }

    private func index(matching serverId: String) -> Int? {
        entries.firstIndex(where: { $0.id == serverId })
            ?? entries.firstIndex(where: { Self.serverIdsMatch($0.id, serverId) })
    }

    @discardableResult
    func updateFetchedName(for serverId: String, fetchedName: String?) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }) else { return false }
        // Runs on launch, every switch and every reachability recovery; skip
        // the persist (a Keychain round trip on tvOS) when nothing changed.
        guard let name = fetchedName, !name.isEmpty, entries[idx].fetchedName != name else { return true }
        let previousEntries = entries
        entries[idx].fetchedName = name
        guard persist() else {
            entries = previousEntries
            _ = persist()
            return false
        }
        return true
    }

    /// Records the deployment identity a server reported at its registry URL.
    /// A blank value is ignored: losing the identity is never an improvement
    /// over a stale one, and both only affect matching, never authorization.
    @discardableResult
    func updateVerifiedServerId(for serverId: String, verifiedServerId: String?) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }),
              let identity = ServerIdentity.usable(verifiedServerId) else { return false }
        guard entries[idx].verifiedServerId != identity else { return true }
        let previousEntries = entries
        entries[idx].verifiedServerId = identity
        guard persist() else {
            entries = previousEntries
            _ = persist()
            return false
        }
        return true
    }

    /// The saved server that belongs to the deployment `verifiedServerId`,
    /// if any. Prefers the active server when it qualifies.
    func entry(verifiedServerId: String?) -> ServerEntry? {
        guard let identity = ServerIdentity.usable(verifiedServerId) else { return nil }
        if let active = activeServer, active.verifiedServerId == identity { return active }
        return sortedEntries.first { $0.verifiedServerId == identity }
    }

    // MARK: - Server switching

    /// Activate a server and select `credential` on it for `userID`: write
    /// the URL/active-ID mirrors and clear the profile id, then publish
    /// `activeServerId` and select the credential in TokenStore. Mirrors are
    /// written first so views reacting to the change read consistent
    /// defaults.
    @discardableResult
    func switchTo(
        serverId: String,
        credential: CredentialSelection,
        userID: String?,
        resolveDestinationProfile: Bool = false
    ) async -> Bool {
        await performSwitch(serverId: serverId, credential: credential, userID: userID,
                            resolveDestinationProfile: resolveDestinationProfile)
    }

    private func performSwitch(
        serverId: String,
        credential: CredentialSelection,
        userID: String?,
        resolveDestinationProfile: Bool
    ) async -> Bool {
        guard entries.contains(where: { $0.id == serverId }) else {
            Self.logger.error("switchTo called with unknown server id")
            recordRegistryEvent(
                phase: "switchServer",
                outcome: "failed",
                reason: "unknownServer"
            )
            return false
        }
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            // No lease means another identity transition owns the client. The
            // tap appears to do nothing, with no error surfaced anywhere else.
            recordRegistryEvent(
                phase: "switchServer",
                outcome: "failed",
                reason: "transitionUnavailable"
            )
            return false
        }
        guard !Task.isCancelled else {
            await httpClient.endIdentityTransition(transitionLease)
            return false
        }
        await httpClient.cancelInFlightRequests()
        guard !Task.isCancelled else {
            await httpClient.endIdentityTransition(transitionLease)
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        let committed = await commitSwitchTo(serverId: serverId, credential: credential, userID: userID,
                                             abortIfCancelled: true)
        guard committed else {
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
            await httpClient.endIdentityTransition(transitionLease)
            return false
        }
        if resolveDestinationProfile, isLoggedIn() {
            _ = await resolveProfile(transitionLease)
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        await httpClient.endIdentityTransition(transitionLease)
        await refreshFeaturesAfterServerSwitch()
        return true
    }

    /// Commit while the caller already holds HTTPClient's transition lease.
    /// Pairing uses this to publish its new tokens, defaults, and observable
    /// active server with no ungated A/B routing interval.
    @discardableResult
    func commitSwitchTo(
        serverId: String,
        credential: CredentialSelection,
        userID: String?,
        holding transitionLease: HTTPIdentityTransitionLease
    ) async -> Bool {
        guard entries.contains(where: { $0.id == serverId }),
              await httpClient.isIdentityTransitionActive(transitionLease) else {
            Self.logger.error("gated switchTo called without its identity transition")
            recordRegistryEvent(
                phase: "switchServer",
                outcome: "failed",
                reason: "staleTransitionLease"
            )
            return false
        }
        // Pairing has already written the new credential slot under this
        // lease. Finish the registry/default commit even if cancellation
        // arrives now; aborting would publish a split A/B routing state.
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        let committed = await commitSwitchTo(serverId: serverId, credential: credential, userID: userID,
                                             abortIfCancelled: false)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        return committed
    }

    func refreshFeaturesAfterGatedServerSwitch() async {
        await refreshFeaturesAfterServerSwitch()
    }

    /// Single commit funnel for both switch paths. Records no breadcrumb:
    /// callers already called `activeProfileWillChange()`, which closes the
    /// capture gate and purges the outgoing journal, and anything written
    /// after `activeProfileDidChange()` lands in the destination account's
    /// journal. Failures here go to OSLog only.
    @discardableResult
    private func commitSwitchTo(
        serverId: String,
        credential: CredentialSelection,
        userID: String?,
        abortIfCancelled: Bool
    ) async -> Bool {
        guard let entry = entries.first(where: { $0.id == serverId }) else {
            Self.logger.error("switchTo target was removed while waiting for transition")
            return false
        }
        await clearCaches()
        guard !abortIfCancelled || !Task.isCancelled else {
            return false
        }

        let previousEntries = entries
        let previousActiveServerID = activeServerId
        let previousServerURL = defaults.string(forKey: SharedStorage.serverUrlKey)
        let previousMirroredServerID = defaults.string(forKey: SharedStorage.activeServerIdKey)
        let previousProfileID = defaults.string(forKey: SharedStorage.profileIdKey)
        let previousAccountID = defaults.string(forKey: SharedStorage.activeAccountIdKey)

        defaults.set(entry.url, forKey: SharedStorage.serverUrlKey)
        defaults.set(serverId, forKey: SharedStorage.activeServerIdKey)
        defaults.removeObject(forKey: SharedStorage.profileIdKey)
        // TokenStore rewrites the account mirror when it selects below; until
        // then no reader may pair the new server with the old account.
        defaults.removeObject(forKey: SharedStorage.activeAccountIdKey)
        activeServerId = serverId
        if let index = entries.firstIndex(where: { $0.id == serverId }) {
            entries[index].lastUsedAt = Date()
        }
        guard persist() else {
            entries = previousEntries
            activeServerId = previousActiveServerID
            _ = persist()
            defaults.set(previousServerURL, forKey: SharedStorage.serverUrlKey)
            defaults.set(previousMirroredServerID, forKey: SharedStorage.activeServerIdKey)
            defaults.set(previousProfileID, forKey: SharedStorage.profileIdKey)
            defaults.set(previousAccountID, forKey: SharedStorage.activeAccountIdKey)
            Self.logger.error("switchTo failed to persist the destination server")
            return false
        }
        activeServerIsFallback = false
        await tokenStore.select(serverID: serverId, credential: credential, userID: userID)
        return true
    }

    private func refreshFeaturesAfterServerSwitch() async {
        // Switching between already-added servers is a per-server boundary too:
        // drop the previous server's AI capability/quota probes after the URL,
        // profile, active id, and token slot have all been retargeted so any
        // foreground refresh observes one consistent server context.
        await MainActor.run {
            AICapabilities.shared.reset()
            CardDescriptionTranslation.shared.reset()
            ImageSizeCapability.shared.reset()
            WatchPartySession.shared.leave(forgetRecent: true)
            RequestsFeatureStore.shared.reset()
            ShuffleFeatureStore.shared.reset()
            CurrentProfileStore.shared.reset()
            SubtitleProvidersStore.shared.reset()
            RequestsEventBus.shared.reset()
            // Re-probe against the just-activated server: a switch between
            // signed-in servers can keep authState at .authenticated, so
            // without this the Requests entry points would stay hidden
            // until the next foreground. Fire-and-forget — the probe
            // degrades to disabled on any failure.
            Task { await RequestsFeatureStore.shared.refresh() }
            Task { await ShuffleFeatureStore.shared.refresh() }
            Task { await CurrentProfileStore.shared.refresh() }
            // Same shape: without a re-probe the destination server's
            // image-size support would stay unknown, and TV requests would
            // silently fall back to the server's default image variants.
            Task { await ImageSizeCapability.shared.refresh() }
            // Same reason, opposite default: the reset above restored
            // "available", so this re-probe is what *dims* the search row on
            // a destination server that has no providers configured.
            Task { await SubtitleProvidersStore.shared.refresh() }
            #if os(iOS) || os(tvOS)
            // Watch Party entry points likewise need the destination's support.
            if WatchPartyEntry.isEnabled { Task { await WatchPartySession.shared.refreshCapabilities() } }
            #endif
        }
    }

    /// Forget the entry and every user's sign-in on it, revoking each session
    /// once it is gone locally. Removing the active server makes the most
    /// recently used remaining server active, with the credential the launch
    /// rules give it outside a chooser; the caller then applies the launch
    /// rules (spec §6.2), which pick the user and server to open.
    @discardableResult
    func remove(serverId: String) async -> Bool {
        // Only a device that can still authenticate can tell the server to
        // stop pushing, so this runs before the credentials are deleted. A
        // removal that then fails leaves the server saved and signed in, so
        // its pushes are turned back on.
        let turnsPushOff = entries.contains(where: { $0.id == serverId })
        if turnsPushOff {
            await unregisterPush(serverId)
        }
        let removed = await removeEntry(serverId: serverId)
        if turnsPushOff, !removed {
            await restorePush(serverId)
        }
        return removed
    }

    private func removeEntry(serverId: String) async -> Bool {
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "failed",
                reason: "transitionUnavailable"
            )
            return false
        }
        guard !Task.isCancelled else {
            await httpClient.endIdentityTransition(transitionLease)
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "cancelled",
                reason: "taskCancelled"
            )
            return false
        }
        guard entries.contains(where: { $0.id == serverId }) else {
            await httpClient.endIdentityTransition(transitionLease)
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "failed",
                reason: "unknownServer"
            )
            return false
        }
        let removesActiveServer = activeServerId == serverId
        #if os(iOS) || os(tvOS)
        if removesActiveServer {
            // Close the synchronous capture gate before any await or before
            // publishing a fallback server/profile combination.
            DiagnosticsCoordinator.activeProfileWillChange()
        }
        guard await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverId) else {
            if removesActiveServer {
                DiagnosticsCoordinator.activeProfileDidChange()
            }
            await httpClient.endIdentityTransition(transitionLease)
            Self.logger.error("removeServer failed to purge local diagnostics")
            return false
        }
        #endif
        guard !Task.isCancelled else {
            #if os(iOS) || os(tvOS)
            if removesActiveServer {
                DiagnosticsCoordinator.activeProfileDidChange()
            }
            #endif
            await httpClient.endIdentityTransition(transitionLease)
            // Diagnostics for this server were already purged above but the
            // entry survives, so the reason names the abandonment point and the
            // resulting half-cleaned state stays recognizable in a report. Only
            // reachable when the gate was never closed; the active-server
            // cancellation is an OSLog line because nothing would append.
            if removesActiveServer {
                Self.logger.error("removeServer cancelled after the diagnostics purge")
            } else {
                recordRegistryEvent(
                    phase: "removeServer",
                    outcome: "cancelled",
                    reason: "taskCancelledAfterPurge"
                )
            }
            return false
        }
        if removesActiveServer {
            // Stop old-server responses and clear every process-wide cache
            // before publishing the fallback ID to observing views.
            await httpClient.cancelInFlightRequests()
            await clearCaches()
            guard !Task.isCancelled else {
                #if os(iOS) || os(tvOS)
                DiagnosticsCoordinator.activeProfileDidChange()
                #endif
                await httpClient.endIdentityTransition(transitionLease)
                // Inside the active-server branch, so the gate is always
                // closed here. OSLog only.
                Self.logger.error("removeServer cancelled after clearing caches")
                return false
            }
        }

        let previousEntries = entries
        let previousActiveServerID = activeServerId
        let previousServerURL = defaults.string(forKey: SharedStorage.serverUrlKey)
        let previousMirroredServerID = defaults.string(forKey: SharedStorage.activeServerIdKey)
        let previousProfileID = defaults.string(forKey: SharedStorage.profileIdKey)

        entries.removeAll(where: { $0.id == serverId })
        if removesActiveServer {
            let fallback = entries.max { $0.lastUsedAt < $1.lastUsedAt }
            if let fallback {
                defaults.set(fallback.url, forKey: SharedStorage.serverUrlKey)
                defaults.set(fallback.id, forKey: SharedStorage.activeServerIdKey)
            } else {
                defaults.removeObject(forKey: SharedStorage.serverUrlKey)
                defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
            }
            defaults.removeObject(forKey: SharedStorage.profileIdKey)
            defaults.removeObject(forKey: SharedStorage.activeAccountIdKey)
            activeServerId = fallback?.id
        }
        // Two durable writes happen here: the registry without this entry,
        // then the tombstone for its canonical session. Neither may stay
        // committed when the other fails. The registry goes first because
        // its rollback is a plain re-persist of the previous entries; when
        // the tombstone then fails, that same rollback restores the entry so
        // the server is neither half-removed nor silently signed out.
        func rollBackRemoval(reason: String) async {
            entries = previousEntries
            activeServerId = previousActiveServerID
            // The rollback is itself a durable write. When it fails after the
            // registry removal was already persisted, the in-memory entry is
            // restored for this process but the next launch will not have
            // it, while the session record (which is what failed to tombstone
            // on the other branch) survives. That is reported distinctly so
            // it is never mistaken for a clean refusal; the record itself is
            // unreachable until the same server is added again, at which
            // point the new sign-in replaces it.
            let rolledBack = persist()
            let reason = rolledBack ? reason : "\(reason)+rollbackPersistFailed"
            defaults.set(previousServerURL, forKey: SharedStorage.serverUrlKey)
            defaults.set(previousMirroredServerID, forKey: SharedStorage.activeServerIdKey)
            defaults.set(previousProfileID, forKey: SharedStorage.profileIdKey)
            // TokenStore owns the account mirror, and a failed removal may
            // already have dropped the selected sign-in, so it comes from
            // the selection rather than from before the removal.
            defaults.set(await tokenStore.currentSignInKey()?.accountID, forKey: SharedStorage.activeAccountIdKey)
            #if os(iOS) || os(tvOS)
            if removesActiveServer {
                DiagnosticsCoordinator.activeProfileDidChange()
            }
            #endif
            await httpClient.endIdentityTransition(transitionLease)
            // A rolled-back persist restores the outgoing server, so on the
            // active branch this is the same unrecordable position `switchTo`
            // is in: the gate closed above and the rollback does not reopen it.
            if removesActiveServer {
                Self.logger.error("removeServer rolled back: \(reason, privacy: .public)")
            } else {
                recordRegistryEvent(phase: "removeServer", outcome: "failed", reason: reason)
            }
        }
        guard persist() else {
            await rollBackRemoval(reason: "persistFailed")
            return false
        }
        // A sign-in that cannot be removed would outlive the entry and
        // restore the session when the same server is added again, so the
        // entry comes back instead. Process-local credentials for the server
        // are already cleared and its runtime is blocked. Each session that
        // is gone for good is revoked, after the local deletion and without
        // waiting: removing a server never waits on the network.
        let removals = await tokenStore.removeServer(serverId)
        revoke(removals)
        guard removals.allSatisfy(\.durable) else {
            await rollBackRemoval(reason: "sessionInvalidationFailed")
            return false
        }

        // Only a non-active removal can be breadcrumbed; active-server outcomes
        // fall inside the closed diagnostics gate (see `commitSwitchTo`).
        if !removesActiveServer {
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "succeeded",
                reason: "otherServer"
            )
        }
        if removesActiveServer {
            // The fallback serves what the launch rules would give it there
            // (before migration, its own session). Screens then apply the
            // launch rules (spec §6.2), which may open another user.
            activeServerIsFallback = true
            let fallbackID = activeServerId ?? ""
            let fallback = await tokenStore.launchSelection(forServer: fallbackID)
            await tokenStore.select(serverID: fallbackID, credential: fallback.credential, userID: fallback.userID)
        }
        launchPreferences.forgetServer(serverId)
        // Branding is cached by address; another saved entry for the same
        // address still uses it.
        if let removedURL = previousEntries.first(where: { $0.id == serverId })?.url,
           !entries.contains(where: { Self.normalize(url: $0.url) == Self.normalize(url: removedURL) }) {
            ServerBrandingCache.remove(for: removedURL)
        }
        #if os(iOS) || os(tvOS)
        if removesActiveServer {
            // Keep diagnostics closed until the fallback identity is fully
            // restored or deliberately left at Who's Watching.
            DiagnosticsCoordinator.activeProfileDidChange()
        }
        #endif
        await httpClient.endIdentityTransition(transitionLease)
        if removesActiveServer {
            // The fallback server may already be signed in, with no
            // auth-state change to trigger the usual probes.
            await refreshFeaturesAfterServerSwitch()
        }
        return true
    }

    private func revoke(_ removals: [SignInRemoval]) {
        var sent: Set<String> = []
        for credential in removals.filter(\.durable).compactMap(\.credential)
        where sent.insert(credential.accessToken).inserted {
            Task { [httpClient] in await httpClient.revoke(credential) }
        }
    }

    // MARK: - ID derivation

    /// Registry key for a URL. The exact normalized spelling is deliberately
    /// preserved because this value already scopes credentials and local data.
    /// User-facing server comparisons must use ``serverIdsMatch(_:_:)`` so
    /// harmless URL spelling differences do not split one server in two.
    static func serverId(for url: String) -> String {
        let normalized = normalize(url: url)
        let data = Data(normalized.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func normalize(url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Reverses the legacy URL-derived registry key. This is intentionally
    /// narrow: the decoded value must be a plausible HTTP(S) server URL and
    /// must round-trip to the exact supplied ID. Unknown future ID formats are
    /// therefore never mistaken for a URL.
    static func url(forServerId serverId: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        var base64 = serverId
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding != 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let normalized = normalize(url: decoded)
        guard canonicalComparisonURL(for: normalized) != nil,
              self.serverId(for: normalized) == serverId else {
            return nil
        }
        return normalized
    }

    /// Compares local registry IDs as server origins without changing either
    /// device's persisted key. URL schemes and hosts are case-insensitive and
    /// default ports are equivalent; credentials, paths, queries, and
    /// fragments retain their ordinary case-sensitive semantics.
    static func serverIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        guard let lhsURL = url(forServerId: lhs),
              let rhsURL = url(forServerId: rhs),
              let lhsCanonical = canonicalComparisonURL(for: lhsURL),
              let rhsCanonical = canonicalComparisonURL(for: rhsURL) else {
            return false
        }
        return lhsCanonical == rhsCanonical
    }

    /// Whether two servers are one deployment. Registry IDs still match by
    /// origin; additionally, two verified deployment identities that are equal
    /// recognise one server across different addresses (public URL, LAN, or a
    /// network plugin origin). Used for visibility and grouping only: it never
    /// merges credentials and never authorizes a handoff by itself.
    static func serversMatch(
        serverId lhsId: String?, verifiedServerId lhsIdentity: String?,
        serverId rhsId: String?, verifiedServerId rhsIdentity: String?
    ) -> Bool {
        if serverIdsMatch(lhsId, rhsId) { return true }
        guard let lhs = ServerIdentity.usable(lhsIdentity),
              let rhs = ServerIdentity.usable(rhsIdentity) else { return false }
        return lhs == rhs
    }

    private static func canonicalComparisonURL(for url: String) -> String? {
        guard var components = URLComponents(string: normalize(url: url)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.string
    }

    // MARK: - Persistence

    private func load() {
        #if os(tvOS)
        let sharedKeychain = keychain.withAudience(.userIndependent)
        if let encoded = sharedKeychain.get(Self.sharedTVRegistryAccount),
           let data = encoded.data(using: .utf8),
           let state = try? JSONDecoder().decode(SharedRegistryState.self, from: data) {
            entries = state.entries
            activeServerId = defaults.string(forKey: SharedStorage.activeServerIdKey)
        } else if let data = defaults.data(forKey: Self.defaultsKey),
                  let legacy = try? JSONDecoder().decode(RegistryState.self, from: data) {
            entries = legacy.entries
            activeServerId = legacy.activeServerId
            persist()
        }
        if activeServerId == nil || !entries.contains(where: { $0.id == activeServerId }) {
            activeServerId = entries.sorted { $0.lastUsedAt > $1.lastUsedAt }.first?.id
            activeServerIsFallback = true
        } else {
            activeServerIsFallback = defaults.bool(forKey: Self.activeServerFallbackKey)
        }
        registerDiagnosticsSensitiveHosts(entries)
        mirrorActiveServer()
        #else
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        do {
            let state = try JSONDecoder().decode(RegistryState.self, from: data)
            self.entries = state.entries
            self.activeServerId = state.activeServerId
            registerDiagnosticsSensitiveHosts(state.entries)
        } catch {
            Self.logger.error("Registry decode failed: \(error.localizedDescription, privacy: .public). Starting empty.")
            return
        }
        // Seed the shared App Group suite on first launch after upgrade.
        // `SharedDefaults.data(forKey:)` falls back to `.standard`, so the
        // registry loads fine on the first run, but the Top Shelf extension
        // only sees the suite. Re-persist to mirror the state forward.
        if defaults.suite.data(forKey: Self.defaultsKey) == nil {
            persist()
            if let active = activeServer {
                defaults.set(active.url, forKey: SharedStorage.serverUrlKey)
            }
        }
        #endif
    }

    /// Registry transition line.
    ///
    /// Nothing this type owns is loggable: an entry is a URL, a display name,
    /// and an id that is just base64 of the URL, so `serverId` is a hostname
    /// in disguise. `registerDiagnosticsSensitiveHosts` makes the redactor
    /// hash hostnames that slip through elsewhere, but that is a backstop, not
    /// a licence — these lines carry only the transition and its outcome.
    private func recordRegistryEvent(phase: String, outcome: String, reason: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Servers",
            message: "server registry changed",
            attrs: [
                "phase": .string(phase),
                "outcome": .string(outcome),
                "reason": .string(reason),
            ]
        )
        #endif
    }

    /// Diagnostics log lines replace known server hostnames with hashed
    /// tokens; every remembered server's host is sensitive, not just the
    /// active one.
    private func registerDiagnosticsSensitiveHosts(_ entries: [ServerEntry]) {
        #if os(iOS) || os(tvOS)
        for entry in entries {
            if let host = URL(string: entry.url)?.host {
                DiagLog.registerSensitiveHost(host)
            }
        }
        #endif
    }

    @discardableResult
    private func persist() -> Bool {
        if let persistenceOverride, !persistenceOverride(entries, activeServerId) {
            return false
        }
        #if os(tvOS)
        do {
            let data = try JSONEncoder().encode(SharedRegistryState(entries: entries))
            guard let encoded = String(data: data, encoding: .utf8) else { return false }
            let sharedKeychain = keychain.withAudience(.userIndependent)
            guard sharedKeychain.set(encoded, for: Self.sharedTVRegistryAccount),
                  sharedKeychain.get(Self.sharedTVRegistryAccount) == encoded else { return false }
            defaults.removeObject(forKey: Self.defaultsKey)
            if let activeServerId {
                defaults.set(activeServerId, forKey: SharedStorage.activeServerIdKey)
                guard defaults.string(forKey: SharedStorage.activeServerIdKey) == activeServerId else {
                    return false
                }
            } else {
                defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
                guard defaults.string(forKey: SharedStorage.activeServerIdKey) == nil else {
                    return false
                }
            }
            return true
        } catch {
            Self.logger.error("Registry encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        let state = RegistryState(activeServerId: activeServerId, entries: entries)
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.defaultsKey)
            return defaults.data(forKey: Self.defaultsKey) == data
        } catch {
            Self.logger.error("Registry encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #endif
    }

    private func mirrorActiveServer() {
        guard let active = activeServer else {
            defaults.removeObject(forKey: SharedStorage.serverUrlKey)
            defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
            return
        }
        defaults.set(active.url, forKey: SharedStorage.serverUrlKey)
        defaults.set(active.id, forKey: SharedStorage.activeServerIdKey)
    }

    /// Move the old registry-owned profile ID into the current user's launch
    /// store. The legacy field remains encoded until the destination mapping
    /// and account epoch can be read back, making interruption retry-safe.
    /// After sign-in migration the server's raw slots are gone, and the
    /// sign-in that took over its data supplies the epoch.
    private func migrateLegacyProfileMappingsIfNeeded() {
        let accountKeychain = keychain.withAudience(.userIndependent)
        let profileKeychain = keychain.withAudience(.currentUser)
        for index in entries.indices {
            guard let profileID = entries[index].legacyProfileId,
                  !profileID.isEmpty else { continue }
            let serverID = entries[index].id
            let accessKey = TokenStore.accessTokenKey(for: serverID)
            let epochKey = TokenStore.accountEpochKey(for: serverID)

            let accountEpoch: String
            if accountKeychain.get(accessKey) == nil {
                guard let epoch = migratedSignInEpoch(forServerID: serverID) else {
                    // A signed-out legacy entry has no account to which the old
                    // profile could safely be bound.
                    let legacyProfileID = entries[index].legacyProfileId
                    entries[index].legacyProfileId = nil
                    if !persist() {
                        entries[index].legacyProfileId = legacyProfileID
                    }
                    continue
                }
                accountEpoch = epoch
            } else if let existing = accountKeychain.get(epochKey), !existing.isEmpty {
                accountEpoch = existing
            } else {
                let generated = UUID().uuidString
                guard accountKeychain.set(generated, for: epochKey),
                      accountKeychain.get(epochKey) == generated else {
                    continue
                }
                accountEpoch = generated
            }

            guard launchPreferences.migrateLegacyProfile(
                profileID: profileID,
                requiresPIN: profileKeychain.get(
                    TokenStore.profileTokenKey(for: serverID)
                ) != nil,
                accountEpoch: accountEpoch,
                for: serverID
            ) else {
                continue
            }
            entries[index].legacyProfileId = nil
            if !persist() {
                entries[index].legacyProfileId = profileID
            }
        }
    }

    /// The epoch of the signed-in saved sign-in that took over a server's
    /// data from before sign-ins existed, if any.
    private func migratedSignInEpoch(forServerID serverID: String) -> String? {
        let store = SavedSignInStore(keychain: keychain)
        guard let index = try? store.loadIndex(),
              let accountID = index.legacyDataOwnerByServerID?[serverID],
              let key = SignInKey(serverID: serverID, accountID: accountID),
              let signIn = try? store.loadSignIn(key), signIn.isSignedIn else { return nil }
        return signIn.epoch?.uuidString
    }

    // MARK: - Migration from the continuum → silo rename

    /// Moves the registry's UserDefaults keys to their post-rename names.
    /// The legacy key is removed only once the current one reads back, and a
    /// current value always wins over a legacy one.
    static func adoptLegacyDefaultsKeys(_ defaults: SharedDefaults) {
        if !defaults.containsObject(forKey: defaultsKey), let data = defaults.data(forKey: legacyDefaultsKey) {
            defaults.set(data, forKey: defaultsKey)
        }
        if defaults.data(forKey: defaultsKey) != nil {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        if !defaults.containsObject(forKey: migratedKey), defaults.containsObject(forKey: legacyMigratedKey) {
            defaults.set(defaults.bool(forKey: legacyMigratedKey), forKey: migratedKey)
        }
        if defaults.containsObject(forKey: migratedKey) {
            defaults.removeObject(forKey: legacyMigratedKey)
        }
    }

    // MARK: - Migration from legacy single-server state

    /// One-shot migration at first launch after upgrading to multi-server.
    /// Reads the legacy `serverUrl` UserDefaults key and the three
    /// fixed-name Keychain entries (`com.continuum.app.{access,refresh,
    /// profile}Token`), creates a ServerEntry for them, re-keys the
    /// Keychain entries under the new per-server scheme, and deletes the
    /// legacy Keychain accounts. Legacy UserDefaults keys
    /// (`serverUrl`, `profileId`) are intentionally left in place — they
    /// act as the active-server mirror read by sync callers.
    private func migrateLegacyIfNeeded() {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        guard entries.isEmpty else {
            defaults.set(true, forKey: Self.migratedKey)
            return
        }

        guard let raw = defaults.string(forKey: SharedStorage.serverUrlKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            defaults.set(true, forKey: Self.migratedKey)
            return
        }

        let normalized = Self.normalize(url: raw)
        let id = Self.serverId(for: normalized)

        let legacyToNew: [(legacy: String, new: String, audience: KeychainAudience)] = [
            ("com.continuum.app.accessToken", TokenStore.accessTokenKey(for: id), .userIndependent),
            ("com.continuum.app.refreshToken", TokenStore.refreshTokenKey(for: id), .userIndependent),
            ("com.continuum.app.profileToken", TokenStore.profileTokenKey(for: id), .currentUser),
        ]
        var copiedLegacyAccounts: [String] = []
        for (legacy, new, audience) in legacyToNew {
            if let v = keychain.get(legacy) {
                let destination = keychain.withAudience(audience)
                guard destination.set(v, for: new), destination.get(new) == v else { return }
                copiedLegacyAccounts.append(legacy)
            }
        }

        let entry = ServerEntry(
            id: id,
            url: normalized,
            fetchedName: nil,
            profileId: defaults.string(forKey: SharedStorage.profileIdKey),
            lastUsedAt: Date()
        )
        self.entries = [entry]
        self.activeServerId = id
        // load() registers persisted entries for redaction, but migration
        // installs this entry directly and returns before that path. Register
        // it here so the legacy host is hashed in diagnostics logs on the very
        // first post-upgrade launch.
        registerDiagnosticsSensitiveHosts([entry])
        if normalized != raw {
            defaults.set(normalized, forKey: SharedStorage.serverUrlKey)
        }
        guard persist() else {
            self.entries = []
            self.activeServerId = nil
            return
        }
        for legacy in copiedLegacyAccounts {
            guard keychain.delete(legacy) else { return }
        }
        defaults.set(true, forKey: Self.migratedKey)
        // The id is the server's hostname in disguise, so it is never logged.
        Self.logger.info("Migrated legacy single-server state to the registry")
    }
}
