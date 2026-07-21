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

    /// Advertised by the server at `GET /api/v1/health` (`server_name`).
    /// Filled on first successful connect and refreshed opportunistically.
    var fetchedName: String?

    /// Remembered profile for this server. Set after `selectProfile`.
    var profileId: String?

    /// When this server was last activated. Used only for sorting the
    /// list; not part of identity.
    var lastUsedAt: Date

    /// Display label for lists/menus. Server-advertised name → URL.
    var displayName: String {
        if let name = fetchedName, !name.isEmpty { return name }
        return url
    }
}

/// Wire shape for the persisted registry. Kept as a separate struct so a
/// future schema bump can change keys without breaking `ServerEntry`.
private struct RegistryState: Codable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

/// Owns the list of known Silo servers and which one is currently
/// active. Singleton via `.shared`; observed by SwiftUI via `@Observable`.
///
/// Per-server persistence splits across two stores:
/// - **UserDefaults** (`continuumServerRegistry.v1`): the server list and
///   active ID, JSON-encoded. Non-secret metadata.
/// - **Keychain** (`SharedKeychain` service `com.continuum.app`, account
///   `com.continuum.<id>.{accessToken,refreshToken,profileToken}`): per-
///   server tokens, activated by `TokenStore.switchActiveServer`.
///
/// The registry is the single source of truth for URL + profileId + name.
/// TokenStore is the single source of truth for tokens. They coordinate
/// through `switchActiveServer` — the registry writes the active ID and
/// the active URL/profileId to UserDefaults, then tells TokenStore to
/// retarget its Keychain slot.
@Observable
final class ServerRegistry {
    static let shared = ServerRegistry()

    private static let defaultsKey = "continuumServerRegistry.v1"
    private static let migratedKey = "continuumServerRegistry.migrated.v1"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "ServerRegistry"
    )

    // Active server state. Synchronous reads from SwiftUI bodies and async
    // reads from HTTPClient both flow through these. Mutation always goes
    // through `persist()` to keep UserDefaults and `@Observable` views in
    // sync.
    private(set) var entries: [ServerEntry] = []
    private(set) var activeServerId: String?

    private let defaults: SharedDefaults
    private let keychain: SharedKeychain

    init(defaults: SharedDefaults = .shared,
         keychain: SharedKeychain = SharedKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
        load()
        migrateLegacyIfNeeded()
    }

    // MARK: - Sync accessors (SwiftUI-safe)

    var activeServer: ServerEntry? {
        guard let id = activeServerId else { return nil }
        return entries.first(where: { $0.id == id })
    }

    var activeServerUrl: String { activeServer?.url ?? "" }
    var activeProfileId: String? { activeServer?.profileId }
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

    /// Insert or update an entry. Preserves an existing `profileId` when the
    /// incoming entry leaves it nil, so callers that only know the URL and
    /// fetched name do not clobber remembered session state.
    @discardableResult
    func addOrUpdate(_ entry: ServerEntry, preservingProfile: Bool = true) -> ServerEntry {
        registerDiagnosticsSensitiveHosts([entry])
        var merged = entry
        if let existing = self.entries.first(where: { $0.id == entry.id }) {
            if preservingProfile, merged.profileId == nil {
                merged.profileId = existing.profileId
            }
            if merged.fetchedName == nil || merged.fetchedName?.isEmpty == true {
                merged.fetchedName = existing.fetchedName
            }
        }
        if let idx = self.entries.firstIndex(where: { $0.id == entry.id }) {
            self.entries[idx] = merged
        } else {
            self.entries.append(merged)
        }
        persist()
        return merged
    }

    func setProfileId(_ profileId: String?, for serverId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }) else { return }
        entries[idx].profileId = profileId
        persist()
    }

    func updateFetchedName(for serverId: String, fetchedName: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }) else { return }
        if let name = fetchedName, !name.isEmpty { entries[idx].fetchedName = name }
        persist()
    }

    private func touchLastUsed(_ serverId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == serverId }) else { return }
        entries[idx].lastUsedAt = Date()
        persist()
    }

    // MARK: - Server switching

    /// Activate a server. Updates the active ID, mirrors URL + profileId
    /// into the legacy `UserDefaults` keys (read by sync callers like
    /// `ProfileAvatarView` and `AuthService`), and retargets `TokenStore`
    /// at the new server's Keychain slot.
    ///
    /// Ordering matters: legacy mirrors are written *before* the observable
    /// `activeServerId` change so any view that reacts to the change reads
    /// consistent UserDefaults values.
    func switchTo(serverId: String) async {
        guard entries.contains(where: { $0.id == serverId }) else {
            Self.logger.error("switchTo called with unknown serverId=\(serverId, privacy: .public)")
            return
        }
        // Cancel before retargeting: a response from the old server must
        // not be able to land on the new server's token slot. See
        // `HTTPClient.cancelInFlightRequests` for the ordering contract.
        await HTTPClient.shared.cancelInFlightRequests()
        await AuthService.shared.clearCachesForServerChange()

        let entry = entries.first(where: { $0.id == serverId })!
        defaults.set(entry.url, forKey: "serverUrl")
        if let pid = entry.profileId {
            defaults.set(pid, forKey: "profileId")
        } else {
            defaults.removeObject(forKey: "profileId")
        }
        #if os(iOS) || os(tvOS)
        // Activating a server restores its saved profile via the mirror above,
        // bypassing AuthService's profileId setter. Re-evaluate diagnostics
        // eligibility so a restored child profile can't inherit the previous
        // server's adult eligibility for the breadcrumb/sentinel gate.
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        activeServerId = serverId
        touchLastUsed(serverId)
        await TokenStore.shared.switchActiveServer(serverId: serverId)

        // Switching between already-added servers is a per-server boundary too:
        // drop the previous server's AI capability/quota probes after the URL,
        // profile, active id, and token slot have all been retargeted so any
        // foreground refresh observes one consistent server context.
        await MainActor.run {
            AICapabilities.shared.reset()
            RequestsFeatureStore.shared.reset()
            RequestsEventBus.shared.reset()
            // Re-probe against the just-activated server: a switch between
            // signed-in servers can keep authState at .authenticated, so
            // without this the Requests entry points would stay hidden
            // until the next foreground. Fire-and-forget — the probe
            // degrades to disabled on any failure.
            Task { await RequestsFeatureStore.shared.refresh() }
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
    func signOut(serverId: String, purgeCurrentBinding: Bool = true) async {
        #if os(iOS) || os(tvOS)
        if purgeCurrentBinding, serverId == activeServerId {
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        }
        await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverId)
        #endif
        await TokenStore.shared.deleteTokens(for: serverId)
        if let idx = entries.firstIndex(where: { $0.id == serverId }) {
            entries[idx].profileId = nil
            persist()
        }
        if serverId == activeServerId {
            defaults.removeObject(forKey: "profileId")
        }
    }

    /// Remove a server entirely (entry + tokens). If it was active, the
    /// next-most-recent server becomes active; if none remain, the active
    /// slot is cleared.
    func remove(serverId: String) async {
        let removesActiveServer = activeServerId == serverId
        #if os(iOS) || os(tvOS)
        if removesActiveServer {
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        }
        await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverId)
        #endif
        if removesActiveServer {
            // Stop old-server responses and clear every process-wide cache
            // before publishing the fallback ID to observing views.
            await HTTPClient.shared.cancelInFlightRequests()
            await AuthService.shared.clearCachesForServerChange()
        }
        await TokenStore.shared.deleteTokens(for: serverId)
        entries.removeAll(where: { $0.id == serverId })
        if removesActiveServer {
            let fallback = entries.sorted { $0.lastUsedAt > $1.lastUsedAt }.first
            activeServerId = fallback?.id
            if let fallback {
                defaults.set(fallback.url, forKey: "serverUrl")
                if let pid = fallback.profileId {
                    defaults.set(pid, forKey: "profileId")
                } else {
                    defaults.removeObject(forKey: "profileId")
                }
                await TokenStore.shared.switchActiveServer(serverId: fallback.id)
            } else {
                defaults.removeObject(forKey: "serverUrl")
                defaults.removeObject(forKey: "profileId")
                await TokenStore.shared.switchActiveServer(serverId: "")
            }
            #if os(iOS) || os(tvOS)
            // Removing the active server restores a different profile (the
            // fallback's, or none) via the mirror above without AuthService's
            // setter. Fail the diagnostics gate closed until the new active
            // profile is confirmed, same as `switchTo`.
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
            await MainActor.run {
                AICapabilities.shared.reset()
                RequestsFeatureStore.shared.reset()
                RequestsEventBus.shared.reset()
                // Same rationale as `switchTo`: the fallback server may
                // already be signed in, with no auth-state change to
                // trigger the usual probe.
                Task { await RequestsFeatureStore.shared.refresh() }
            }
        }
        persist()
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
                if let pid = active.profileId {
                    defaults.set(pid, forKey: SharedStorage.profileIdKey)
                }
            }
        }
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

    private func persist() {
        let state = RegistryState(activeServerId: activeServerId, entries: entries)
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Registry encode failed: \(error.localizedDescription, privacy: .public)")
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
        defer { defaults.set(true, forKey: Self.migratedKey) }
        guard entries.isEmpty else { return }

        guard let raw = defaults.string(forKey: "serverUrl")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }

        let normalized = Self.normalize(url: raw)
        let id = Self.serverId(for: normalized)

        let legacyToNew: [(legacy: String, new: String)] = [
            ("com.continuum.app.accessToken",  TokenStore.accessTokenKey(for: id)),
            ("com.continuum.app.refreshToken", TokenStore.refreshTokenKey(for: id)),
            ("com.continuum.app.profileToken", TokenStore.profileTokenKey(for: id)),
        ]
        for (legacy, new) in legacyToNew {
            if let v = keychain.get(legacy) {
                keychain.set(v, for: new)
            }
            keychain.delete(legacy)
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
        persist()
        Self.logger.info("Migrated legacy single-server state to registry id=\(id, privacy: .public)")
    }
}
