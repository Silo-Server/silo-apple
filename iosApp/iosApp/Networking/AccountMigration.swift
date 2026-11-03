import Foundation
import OSLog

/// Moves the per-server sessions from before accounts into `AccountStore`,
/// once, at launch and without the network.
///
/// Each saved server's session becomes one `Account` with a new
/// `localAccountId`, keeping its tokens and epoch and taking the session's
/// verified account ID as `serverUserId`. That account adopts the server's
/// existing local data (`AccountIndex.legacyDataOwners`). The old credential
/// slots are deleted only after the index listing the new records has been
/// written and read back. After that, nothing outside this type reads them.
///
/// Household state (the records and index) migrates once. Each device user's
/// own state (profile proof, remembered profile) is adopted the first time
/// that user launches, by `adoptCurrentUserState`.
struct AccountMigration {
    enum Outcome: Equatable {
        case notNeeded
        case migrated(accounts: Int)
        /// Nothing was committed; the next launch retries. Until then the
        /// old sessions are unreachable and the app reads as signed out.
        case deferred
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "AccountMigration"
    )

    let accounts: AccountStore
    let sessions: AccountSessionPersistence
    /// The user-independent keychain the per-token slots live in.
    let accountKeychain: SharedKeychain
    /// The current device user's keychain, which holds their profile proofs.
    let profileKeychain: SharedKeychain

    init(keychain: SharedKeychain = SharedKeychain(), accounts: AccountStore = .shared) {
        self.accounts = accounts
        self.sessions = AccountSessionPersistence(keychain: keychain)
        self.accountKeychain = keychain.withAudience(.userIndependent)
        self.profileKeychain = keychain.withAudience(.currentUser)
    }

    /// Migrates `servers`' sessions if the index doesn't say it's done, then
    /// retries deleting any old slots a previous run left. `serverListIsComplete`
    /// is false when the server list failed to load: an empty list is then
    /// not evidence that there is nothing to migrate.
    @discardableResult
    func runIfNeeded(servers: [(id: String, url: String)], serverListIsComplete: Bool) -> Outcome {
        let existing: AccountIndex?
        do { existing = try accounts.loadIndex() } catch {
            Self.logger.error("Account index unreadable; deferring account migration.")
            return .deferred
        }
        if let existing, existing.legacySessionsMigrated {
            cleanUpLegacySlots(existing.pendingLegacyCleanup)
            return .notNeeded
        }
        guard serverListIsComplete || !servers.isEmpty else { return .deferred }

        var migrated: [Account] = []
        var seen: Set<String> = []
        for server in servers where !server.id.isEmpty && seen.insert(server.id).inserted {
            let origin = ServerRegistry.normalize(url: server.url)
            do {
                if let account = try legacyAccount(serverId: server.id, origin: origin) {
                    migrated.append(account)
                }
            } catch is SharedKeychain.ReadError {
                Self.logger.error("A saved session is unreadable; deferring account migration.")
                return .deferred
            } catch {
                // A record that doesn't decode blocks its server until the next
                // sign-in today, so it is not a working session to carry over.
                continue
            }
        }

        let index: AccountIndex
        do {
            index = try accounts.commitMigration(migrated, pendingLegacyCleanup: Array(seen).sorted())
        } catch {
            Self.logger.error("Account migration could not be saved; it will retry.")
            return .deferred
        }
        cleanUpLegacySlots(index.pendingLegacyCleanup)
        Self.logger.info("Migrated \(migrated.count, privacy: .public) saved sessions to accounts")
        return .migrated(accounts: migrated.count)
    }

    /// Moves this device user's state from before accounts onto the account
    /// that adopted each server's data: the profile proof, and the remembered
    /// profile in `ProfileLaunchPreferences`. Runs until it has completed once
    /// for this device user (on tvOS, each Apple TV user), which a defaults
    /// flag in that user's domain records.
    func adoptCurrentUserState(launchPreferences: ProfileLaunchPreferences, defaults: SharedDefaults) {
        guard !defaults.bool(forKey: SharedStorage.accountUserStateAdoptedKey),
              let index = try? accounts.loadIndex(), index.legacySessionsMigrated else { return }
        var complete = true
        for (serverId, localAccountId) in index.legacyDataOwners {
            let legacyKey = SharedStorage.profileTokenAccount(for: serverId)
            guard let proof = profileKeychain.get(legacyKey), !proof.isEmpty else { continue }
            let adopted = accounts.profileToken(for: localAccountId, onServer: serverId) != nil
                || (accounts.setProfileToken(proof, for: localAccountId, onServer: serverId)
                    && accounts.profileToken(for: localAccountId, onServer: serverId) == proof)
            if !adopted || !profileKeychain.delete(legacyKey) { complete = false }
        }
        guard launchPreferences.adoptLegacyServerMemory(owners: index.legacyDataOwners), complete else { return }
        defaults.set(true, forKey: SharedStorage.accountUserStateAdoptedKey)
    }

    /// The account a server's old session becomes, or nil when it had none.
    /// Throws `SharedKeychain.ReadError` when a slot can't be read.
    private func legacyAccount(serverId: String, origin: String) throws -> Account? {
        switch try sessions.load(serverId) {
        case .signedOut:
            return nil
        case .session(let value):
            // A record bound to another address never authenticated this
            // server, so it is not carried over.
            guard let recordOrigin = value.origin, ServerRegistry.normalize(url: recordOrigin) == origin,
                  let access = value.accessToken, let refresh = value.refreshToken, let epoch = value.epoch else {
                return nil
            }
            return Account(
                serverId: serverId,
                origin: origin,
                serverUserId: value.accountID,
                accessToken: access,
                refreshToken: refresh,
                epoch: epoch
            )
        case .legacy:
            guard let access = try accountKeychain.getChecked(SharedStorage.accessTokenAccount(for: serverId)),
                  !access.isEmpty else { return nil }
            let refresh = try accountKeychain.getChecked(SharedStorage.refreshTokenAccount(for: serverId))
            // The epoch a remembered profile was bound to; a session that never
            // made one gets a new one, and its remembered profile no longer
            // matches, as after any sign-in.
            let epoch = try accountKeychain.getChecked(SharedStorage.accountEpochAccount(for: serverId))
                .flatMap(UUID.init(uuidString:)) ?? UUID()
            return Account(
                serverId: serverId,
                origin: origin,
                accessToken: access,
                refreshToken: refresh?.isEmpty == false ? refresh : nil,
                epoch: epoch
            )
        }
    }

    /// Deletes the old credential slots of each server in `serverIds`, then
    /// records which are left. Failures retry on the next launch; the slots
    /// are never read, so leaving one costs nothing but its stale tokens.
    private func cleanUpLegacySlots(_ serverIds: [String]) {
        guard !serverIds.isEmpty else { return }
        let remaining = serverIds.filter { serverId in
            let removed = [
                sessions.delete(serverId),
                accountKeychain.delete(SharedStorage.accessTokenAccount(for: serverId)),
                accountKeychain.delete(SharedStorage.refreshTokenAccount(for: serverId)),
                accountKeychain.delete(SharedStorage.accountEpochAccount(for: serverId)),
            ]
            return removed.contains(false)
        }
        guard remaining != serverIds else { return }
        do { try accounts.setPendingLegacyCleanup(remaining) } catch {
            Self.logger.error("Account migration cleanup could not be recorded; it will retry.")
        }
    }
}
