import Foundation
import OSLog

/// A single Silo server the user has added to the device.
///
/// The registry stores one of these per remembered server. Tokens live in
/// Keychain keyed by `id`, never in the entry itself. The display name is
/// always server-administered through the advertised `fetchedName`.
struct ServerEntry: Codable, Identifiable, Equatable, Hashable {
    /// Stable client-derived ID: base64url of the normalized URL's UTF-8
    /// bytes. Reversible — but the registry treats it as opaque.
    let id: String

    /// Normalized base URL (trailing slash stripped, whitespace trimmed).
    var url: String

    /// Advertised by native branding, with a legacy health-name fallback.
    /// Filled on first successful connect and refreshed on server activation.
    var fetchedName: String?

    /// When this server was last activated. Used only for sorting the
    /// list; not part of identity.
    var lastUsedAt: Date

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
        lastUsedAt: Date
    ) {
        self.id = id
        self.url = url
        self.fetchedName = fetchedName
        self.lastUsedAt = lastUsedAt
        self.legacyProfileId = profileId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case fetchedName
        case profileId
        case lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        fetchedName = try container.decodeIfPresent(String.self, forKey: .fetchedName)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        legacyProfileId = try container.decodeIfPresent(String.self, forKey: .profileId)
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

private final class ActiveServerIDSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func write(_ value: String?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

/// Owns the list of known Silo servers and which one is currently
/// active. Singleton via `.shared`; observed by SwiftUI via `@Observable`.
///
/// Per-server persistence splits across two stores:
/// - **UserDefaults** (`continuumServerRegistry.v1`): the server list and
///   active ID on iOS/macOS. tvOS stores the shared list in the
///   user-independent Keychain and the active ID in current-user defaults.
/// - **Keychain** (`SharedKeychain` service `com.continuum.app`, account
///   `com.continuum.<id>.{accessToken,refreshToken,profileToken}`): per-
///   server tokens, activated by `TokenStore.switchActiveServer`.
///
/// The registry is the single source of truth for URL + name.
/// TokenStore is the single source of truth for tokens. They coordinate
/// through `switchActiveServer` — the registry writes the active ID and
/// the active URL to UserDefaults, then tells TokenStore to
/// retarget its Keychain slot.
@Observable
final class ServerRegistry {
    static let shared = ServerRegistry()

    private let activeServerSnapshot = ActiveServerIDSnapshot()

    /// Actor-safe identity snapshot for background coordinators. SwiftUI uses
    /// the observable instance property below, while async services use this
    /// lock-protected mirror instead of racing that mutable UI state.
    static var activeServerIDSnapshot: String? {
        shared.activeServerSnapshot.read()
    }

    private static let defaultsKey = "continuumServerRegistry.v1"
    private static let migratedKey = "continuumServerRegistry.migrated.v1"
    private static let sharedTVRegistryAccount = "com.continuum.serverRegistry.v2"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "ServerRegistry"
    )

    // Active server state. Synchronous reads from SwiftUI bodies and async
    // reads from HTTPClient both flow through these. Mutation always goes
    // through `persist()` to keep UserDefaults and `@Observable` views in
    // sync.
    private(set) var entries: [ServerEntry] = []
    private(set) var activeServerId: String? {
        didSet { activeServerSnapshot.write(activeServerId) }
    }

    private let defaults: SharedDefaults
    private let keychain: SharedKeychain
    private let launchPreferences: ProfileLaunchPreferences
    private let persistenceOverride: (([ServerEntry], String?) -> Bool)?

    init(
        defaults: SharedDefaults = .shared,
        keychain: SharedKeychain = SharedKeychain(),
        launchPreferences: ProfileLaunchPreferences = .shared,
        persistenceOverride: (([ServerEntry], String?) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.launchPreferences = launchPreferences
        self.persistenceOverride = persistenceOverride
        load()
        migrateLegacyIfNeeded()
        migrateLegacyProfileMappingsIfNeeded()
        activeServerSnapshot.write(activeServerId)
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

    /// Insert or update an entry. `preservingProfile` remains as an account-
    /// replacement signal for existing callers; profile state itself lives in
    /// `ProfileLaunchPreferences`, never in the shared registry payload.
    @discardableResult
    func addOrUpdate(_ entry: ServerEntry, preservingProfile: Bool = true) -> ServerEntry? {
        let previousEntries = entries
        var merged = entry
        if let existing = self.entries.first(where: { $0.id == entry.id }) {
            if merged.fetchedName == nil || merged.fetchedName?.isEmpty == true {
                merged.fetchedName = existing.fetchedName
            }
        }
        let isExistingEntry = self.entries.contains(where: { $0.id == entry.id })
        if let idx = self.entries.firstIndex(where: { $0.id == entry.id }) {
            self.entries[idx] = merged
        } else {
            self.entries.append(merged)
        }
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
            launchPreferences.clearRememberedProfile(for: entry.id)
        }
        return merged
    }

    @discardableResult
    func updateFetchedName(for serverId: String, fetchedName: String?) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }) else { return false }
        let previousEntries = entries
        if let name = fetchedName, !name.isEmpty { entries[idx].fetchedName = name }
        guard persist() else {
            entries = previousEntries
            _ = persist()
            return false
        }
        return true
    }

    // MARK: - Server switching

    /// Activate a server. Updates the active ID, mirrors the URL, clears the
    /// previous request profile,
    /// into the legacy `UserDefaults` keys (read by sync callers like
    /// `ProfileAvatarView` and `AuthService`), and retargets `TokenStore`
    /// at the new server's Keychain slot.
    ///
    /// Ordering matters: legacy mirrors are written *before* the observable
    /// `activeServerId` change so any view that reacts to the change reads
    /// consistent UserDefaults values.
    @discardableResult
    func switchTo(
        serverId: String,
        resolveDestinationProfile: Bool = false
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
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
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
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        let committed = await commitSwitchTo(serverId: serverId, abortIfCancelled: true)
        guard committed else {
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        if resolveDestinationProfile, AuthService.shared.isLoggedIn {
            _ = await AuthService.shared.resolveActiveProfileForSession(
                holding: transitionLease
            )
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        await refreshFeaturesAfterServerSwitch()
        return true
    }

    /// Commit while the caller already holds HTTPClient's transition lease.
    /// Pairing uses this to publish its new tokens, defaults, and observable
    /// active server with no ungated A/B routing interval.
    @discardableResult
    func commitSwitchTo(
        serverId: String,
        holding transitionLease: HTTPIdentityTransitionLease
    ) async -> Bool {
        guard entries.contains(where: { $0.id == serverId }),
              await HTTPClient.shared.isIdentityTransitionActive(transitionLease) else {
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
        let committed = await commitSwitchTo(serverId: serverId, abortIfCancelled: false)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        return committed
    }

    func refreshFeaturesAfterGatedServerSwitch() async {
        await refreshFeaturesAfterServerSwitch()
    }

    /// Single commit funnel for both the plain and the lease-holding switch.
    ///
    /// Deliberately records no breadcrumb, and neither does the window just
    /// before it. Both callers open with
    /// `DiagnosticsCoordinator.activeProfileWillChange()`, which synchronously
    /// makes the active profile ineligible and closes the capture gate; the
    /// matching `activeProfileDidChange()` does not run until after this
    /// returns. A line emitted inside the funnel is therefore offered to a
    /// disabled journal and dropped.
    ///
    /// Moving it a few statements earlier — to just before the boundary, while
    /// the outgoing account can still capture — does not rescue it either, and
    /// that is the non-obvious part. `activeProfileWillChange()` does not only
    /// close the gate: once this launch's capture decision is in effect it
    /// calls `purgeBreadcrumbJournal()`, which deletes the journal directory
    /// outright and discards the early-boot staging buffer with it. A line
    /// written microseconds earlier is inside exactly the trail that purge
    /// destroys, so a pre-boundary "attempted" is not a durable
    /// last-word-of-the-outgoing-account — it is erased on every switch that
    /// gets far enough to matter, and survives only on the launches where the
    /// gate never opened and it was never written in the first place.
    ///
    /// Nor can the outcome be re-emitted after the boundary. This function
    /// *is* the identity change: it retargets the URL, active id, profile key,
    /// and token slot. A line written after `activeProfileDidChange()` lands
    /// in the destination account's journal, where an outgoing-account failure
    /// reason ("the switch away from your other server did not persist") is
    /// exactly the cross-account evidence the boundary exists to prevent.
    ///
    /// So this transition is deliberately not breadcrumbed on either side.
    /// The pre-boundary guards that reject a switch before any identity work
    /// (`unknownServer`, `transitionUnavailable`, `staleTransitionLease`) keep
    /// their lines: those return without ever reaching the boundary, so
    /// nothing purges them and they are unambiguously the outgoing account's.
    /// Failures *inside* the funnel go to OSLog only. What makes the switch
    /// readable in a report is the destination's own trail, which opens fresh
    /// immediately afterward: a user who switched servers and landed nowhere
    /// shows a journal whose first lines are the new server's.
    @discardableResult
    private func commitSwitchTo(
        serverId: String,
        abortIfCancelled: Bool
    ) async -> Bool {
        guard let entry = entries.first(where: { $0.id == serverId }) else {
            Self.logger.error("switchTo target was removed while waiting for transition")
            return false
        }
        await AuthService.shared.clearCachesForServerChange()
        guard !abortIfCancelled || !Task.isCancelled else {
            return false
        }

        let previousEntries = entries
        let previousActiveServerID = activeServerId
        let previousServerURL = defaults.string(forKey: SharedStorage.serverUrlKey)
        let previousMirroredServerID = defaults.string(forKey: SharedStorage.activeServerIdKey)
        let previousProfileID = defaults.string(forKey: SharedStorage.profileIdKey)

        defaults.set(entry.url, forKey: "serverUrl")
        defaults.set(serverId, forKey: SharedStorage.activeServerIdKey)
        defaults.removeObject(forKey: SharedStorage.profileIdKey)
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
            // A rolled-back persist leaves the *outgoing* server active, so
            // this is the one failure whose account is unambiguous. It still
            // cannot be recorded here — the gate closed above — and the
            // caller's `attempted` line with no successful switch afterward is
            // what makes it visible.
            Self.logger.error("switchTo failed to persist the destination server")
            return false
        }
        await TokenStore.shared.switchActiveServer(serverId: serverId)
        return true
    }

    private func refreshFeaturesAfterServerSwitch() async {
        // Switching between already-added servers is a per-server boundary too:
        // drop the previous server's AI capability/quota probes after the URL,
        // profile, active id, and token slot have all been retargeted so any
        // foreground refresh observes one consistent server context.
        await MainActor.run {
            AICapabilities.shared.reset()
            RequestsFeatureStore.shared.reset()
            SubtitleProvidersStore.shared.reset()
            RequestsEventBus.shared.reset()
            // Re-probe against the just-activated server: a switch between
            // signed-in servers can keep authState at .authenticated, so
            // without this the Requests entry points would stay hidden
            // until the next foreground. Fire-and-forget — the probe
            // degrades to disabled on any failure.
            Task { await RequestsFeatureStore.shared.refresh() }
            // Same reason, opposite default: the reset above restored
            // "available", so this re-probe is what *dims* the search row on
            // a destination server that has no providers configured.
            Task { await SubtitleProvidersStore.shared.refresh() }
        }
    }

    /// Sign out from `serverId` without removing the entry. Clears tokens
    /// and profile selection; URL + display name remain so the user can
    /// log back in. If `serverId` is the active server, the legacy
    /// `profileId` UserDefaults key is cleared too.
    ///
    /// The registry-wide diagnostics purge always runs: it clears reports and
    /// consent stored under *older* `server_instance_id`s recorded for this
    /// registry URL (e.g. after a server restore/reinstall at the same URL),
    /// which a current-binding-only purge would leave behind. Pass
    /// `purgeCurrentBinding: false` when the caller already purged the active
    /// binding while still authenticated (AuthService.signOut does, so the
    /// binding resolves against a live session) to avoid duplicate current work.
    func signOut(
        serverId: String,
        purgeCurrentBinding: Bool = true,
        purgeRegistryBindings: Bool = true
    ) async {
        #if os(iOS) || os(tvOS)
        if purgeCurrentBinding, serverId == activeServerId {
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        }
        if purgeRegistryBindings {
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverId)
        }
        #endif
        await TokenStore.shared.deleteTokens(for: serverId)
        launchPreferences.clearRememberedProfile(for: serverId)
        // Read *after* the awaits above, not snapshotted at entry: the legacy
        // `profileId` key always describes whichever server is active right
        // now. If a switch lands during those suspensions, this server is no
        // longer the one the key belongs to and clearing it would erase the
        // destination server's profile selection. The breadcrumb below reuses
        // the same value so the recorded reason always names the branch that
        // actually ran.
        let signsOutActiveServer = serverId == activeServerId
        if signsOutActiveServer {
            defaults.removeObject(forKey: SharedStorage.profileIdKey)
        }
        // Deliberately after the purge above, matching `remove`: the purge
        // wipes the whole journal, so a line written before it is lost, while
        // one written after explains why the journal starts empty. It is still
        // consent-gated — the journal re-checks capture on every append.
        // Signing out a *non-active* server leaves the UI unchanged, so the
        // two cases are distinguished to keep a later "why am I still signed
        // in" report answerable.
        //
        // Whether this appends depends on the caller, and only one of them can
        // ever see it. `AuthService.signOut` passes both purge flags false
        // precisely because it already purged the current binding itself —
        // and that purge cleared the breadcrumb consent context along with the
        // last-known status snapshot behind it, so nothing resolves a context
        // and this line is dropped on the whole active sign-out path. What
        // survives is the direct caller that never touched the current binding:
        // a non-active sign-out, where `otherServer` still records. The
        // `activeServer` reason is kept rather than deleted because the purge
        // flags are parameters — a future caller that signs out an active
        // server without pre-purging would land here with the gate open, and
        // that is the case the reason names.
        recordRegistryEvent(
            phase: "signOutServer",
            outcome: "succeeded",
            reason: signsOutActiveServer ? "activeServer" : "otherServer"
        )
    }

    /// Remove a server entirely (entry + tokens). If it was active, the
    /// next-most-recent server becomes active; if none remain, the active
    /// slot is cleared.
    ///
    /// Breadcrumbs here are deliberately asymmetric, and the asymmetry is the
    /// whole point. Removing a *non-active* server never opens an identity
    /// boundary: no `activeProfileWillChange()` runs, the capture gate stays
    /// open, and every outcome below is recorded normally. The registry-wide
    /// purge that does run empties the journal but leaves the consent context
    /// intact, so a line written after it still appends — the same position
    /// `signOut` takes, and for the same reason.
    ///
    /// Removing the *active* server cannot record any outcome. The boundary at
    /// the top of that branch closes the capture gate synchronously, and its
    /// matching `activeProfileDidChange()` only starts an async re-resolution
    /// that cannot land before this function returns — so every later line is
    /// offered to a disabled journal. Nor does moving one earlier help: the
    /// boundary also calls `purgeBreadcrumbJournal()` once this launch's
    /// capture decision is in effect, deleting the journal directory and the
    /// early-boot staging buffer, so a pre-boundary line sits in exactly the
    /// trail that purge destroys. See `commitSwitchTo` for the long form.
    ///
    /// The cost is real and worth naming: the `activeServerNoFallback` /
    /// `activeServerFellBack` distinction — which server the user gets bounced
    /// to, or whether they land at setup — is what a "my servers disappeared"
    /// report wants most, and it is unrecordable anywhere in this function.
    /// Claiming otherwise with a line that never appends would be worse, so
    /// the active branch keeps only its OSLog failure line, and what makes the
    /// removal readable in a report is the fallback identity's own trail,
    /// which opens fresh once eligibility re-resolves.
    @discardableResult
    func remove(
        serverId: String,
        resolveFallbackProfile: Bool = false
    ) async -> Bool {
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "failed",
                reason: "transitionUnavailable"
            )
            return false
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "cancelled",
                reason: "taskCancelled"
            )
            return false
        }
        guard entries.contains(where: { $0.id == serverId }) else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
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
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        }
        await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverId)
        #endif
        guard !Task.isCancelled else {
            #if os(iOS) || os(tvOS)
            if removesActiveServer {
                DiagnosticsCoordinator.activeProfileDidChange()
            }
            #endif
            await HTTPClient.shared.endIdentityTransition(transitionLease)
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
            await HTTPClient.shared.cancelInFlightRequests()
            await AuthService.shared.clearCachesForServerChange()
            guard !Task.isCancelled else {
                #if os(iOS) || os(tvOS)
                DiagnosticsCoordinator.activeProfileDidChange()
                #endif
                await HTTPClient.shared.endIdentityTransition(transitionLease)
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
            let fallback = entries.sorted { $0.lastUsedAt > $1.lastUsedAt }.first
            if let fallback {
                defaults.set(fallback.url, forKey: "serverUrl")
                defaults.set(fallback.id, forKey: SharedStorage.activeServerIdKey)
                defaults.removeObject(forKey: SharedStorage.profileIdKey)
            } else {
                defaults.removeObject(forKey: "serverUrl")
                defaults.removeObject(forKey: SharedStorage.activeServerIdKey)
                defaults.removeObject(forKey: SharedStorage.profileIdKey)
            }
            activeServerId = fallback?.id
        }
        guard persist() else {
            entries = previousEntries
            activeServerId = previousActiveServerID
            _ = persist()
            defaults.set(previousServerURL, forKey: SharedStorage.serverUrlKey)
            defaults.set(previousMirroredServerID, forKey: SharedStorage.activeServerIdKey)
            defaults.set(previousProfileID, forKey: SharedStorage.profileIdKey)
            #if os(iOS) || os(tvOS)
            if removesActiveServer {
                DiagnosticsCoordinator.activeProfileDidChange()
            }
            #endif
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            // A rolled-back persist restores the outgoing server, so on the
            // active branch this is the same unrecordable position `switchTo`
            // is in: the gate closed above and the rollback does not reopen it.
            if removesActiveServer {
                Self.logger.error("removeServer failed to persist the removal")
            } else {
                recordRegistryEvent(
                    phase: "removeServer",
                    outcome: "failed",
                    reason: "persistFailed"
                )
            }
            return false
        }

        // Only the non-active removal can say anything here. Its gate was never
        // closed, and this position — after the registry-wide purge — is the
        // one `signOut` uses: the purge empties the journal without clearing
        // the consent context, so this line appends and explains why the trail
        // above it is gone. The active-server outcomes that would be more
        // valuable (`activeServerNoFallback` / `activeServerFellBack`) are the
        // ones the boundary makes unrecordable; see this function's doc
        // comment. Emitting them anyway would put a line in the source that no
        // report can ever contain.
        if !removesActiveServer {
            recordRegistryEvent(
                phase: "removeServer",
                outcome: "succeeded",
                reason: "otherServer"
            )
        }
        if removesActiveServer {
            await TokenStore.shared.switchActiveServer(serverId: activeServerId ?? "")
        }
        await TokenStore.shared.deleteTokens(for: serverId)
        launchPreferences.clearRememberedProfile(for: serverId)
        if removesActiveServer,
           resolveFallbackProfile,
           AuthService.shared.isLoggedIn {
            _ = await AuthService.shared.resolveActiveProfileForSession(
                holding: transitionLease
            )
        }
        #if os(iOS) || os(tvOS)
        if removesActiveServer {
            // Keep diagnostics closed until the fallback identity is fully
            // restored or deliberately left at Who's Watching.
            DiagnosticsCoordinator.activeProfileDidChange()
        }
        #endif
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        if removesActiveServer {
            await MainActor.run {
                AICapabilities.shared.reset()
                RequestsFeatureStore.shared.reset()
                SubtitleProvidersStore.shared.reset()
                RequestsEventBus.shared.reset()
                // Same rationale as `switchTo`: the fallback server may
                // already be signed in, with no auth-state change to
                // trigger the usual probe.
                Task { await RequestsFeatureStore.shared.refresh() }
                Task { await SubtitleProvidersStore.shared.refresh() }
            }
        }
        return true
    }

    // MARK: - ID derivation

    /// Canonical registry ID for a URL. Two URLs that normalize to the
    /// same string share an ID; otherwise they are treated as distinct
    /// servers (which may produce duplicate entries for the same instance
    /// reached at e.g. LAN vs Tailscale — an accepted limitation).
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
    private func migrateLegacyProfileMappingsIfNeeded() {
        let accountKeychain = keychain.withAudience(.userIndependent)
        let profileKeychain = keychain.withAudience(.currentUser)
        for index in entries.indices {
            guard let profileID = entries[index].legacyProfileId,
                  !profileID.isEmpty else { continue }
            let serverID = entries[index].id
            let accessKey = TokenStore.accessTokenKey(for: serverID)
            let epochKey = TokenStore.accountEpochKey(for: serverID)

            guard accountKeychain.get(accessKey) != nil else {
                // A signed-out legacy entry has no account to which the old
                // profile could safely be bound.
                let legacyProfileID = entries[index].legacyProfileId
                entries[index].legacyProfileId = nil
                if !persist() {
                    entries[index].legacyProfileId = legacyProfileID
                }
                continue
            }

            let accountEpoch: String
            if let existing = accountKeychain.get(epochKey), !existing.isEmpty {
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

        guard let raw = defaults.string(forKey: "serverUrl")?
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
            profileId: defaults.string(forKey: "profileId"),
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
            defaults.set(normalized, forKey: "serverUrl")
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
        Self.logger.info("Migrated legacy single-server state to registry id=\(id, privacy: .public)")
    }
}
