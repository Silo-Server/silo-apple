import Foundation
import OSLog

enum AccountStoreError: Error, Equatable {
    /// The keychain refused the write, or reading it back returned something
    /// else.
    case writeFailed
    /// The item decodes as JSON, but a build with another format wrote it.
    case unsupportedVersion(Int)
    /// The item exists but can't be decoded, or breaks an invariant.
    case corrupt
    /// A record names a different server or account than its key.
    case keyMismatch
    /// The server ID, account ID, origin, or credentials are not usable.
    case invalidIdentity
    /// No saved account has that ID on that server.
    case notFound
    /// The account's credentials changed since the caller read them.
    case credentialsChanged
}

/// The outcome of saving a sign-in (`AccountStore.saveSignIn`).
struct AccountSignInResult: Equatable, Sendable {
    /// The new account, or the saved account the sign-in refreshed.
    let account: Account
    /// Whether `account` was already saved: the sign-in named its server user.
    let refreshedExisting: Bool
    /// Accounts on the same server that the sign-in replaced. Their records
    /// are gone; callers delete the local data keyed by these IDs.
    let removedAccountIds: [String]
}

/// One saved server's accounts folded into another saved server's, planned
/// by `AccountStore.planServerMerge`.
struct AccountServerMerge: Sendable {
    /// An account removed locally because the merge keeps another account
    /// of the same server user. Its downloads go to the kept one.
    struct Removal: Sendable {
        let account: Account
        let keptLocalAccountId: String
    }

    let droppedServerId: String
    let survivorServerId: String
    /// The dropped server's accounts that move, as saved there. They keep
    /// their `localAccountId`, so their local data only changes server.
    let moved: [Account]
    /// Accounts of either server that the merge removes.
    let removed: [Removal]
    /// The dropped server's owner of data from before accounts.
    let legacyDataOwner: String?

    /// The account that keeps `localAccountId`'s place after the merge.
    func keptAccount(for localAccountId: String) -> String? {
        removed.first { $0.account.localAccountId == localAccountId }?.keptLocalAccountId
    }

    /// Whether the merge moves, removes, or keeps `localAccountId` (a kept
    /// account takes a removed one's downloads).
    func touches(_ localAccountId: String) -> Bool {
        moved.contains { $0.localAccountId == localAccountId }
            || removed.contains { $0.account.localAccountId == localAccountId || $0.keptLocalAccountId == localAccountId }
    }

    /// Where the dropped server's data from before accounts goes on the
    /// survivor: its owner when it moves, else the account kept in its place.
    var legacyDataTarget: String? {
        legacyDataOwner.map { keptAccount(for: $0) ?? $0 }
    }

    /// Each account whose local data moves, and the survivor account that
    /// takes it: a moved account takes its own, a kept account takes the
    /// downloads of the one removed in its favour.
    var downloadMoves: [(serverId: String, localAccountId: String, target: String)] {
        moved.map { (droppedServerId, $0.localAccountId, $0.localAccountId) }
            + removed.map { ($0.account.serverId, $0.account.localAccountId, $0.keptLocalAccountId) }
    }
}

/// Everything saved for one server's accounts at one moment, so a sign-in or
/// pairing that fails after writing can put it back exactly.
struct AccountServerSnapshot: Equatable, Sendable {
    let serverId: String
    let accounts: [Account]
    let legacyDataOwner: String?
}

/// Owns saved accounts, their tokens, and the current device user's account
/// selection. Records and the index live in the user-independent keychain,
/// so the household signs in once; profile proofs and the selection belong to
/// the current device user (on tvOS, the Apple TV user).
///
/// Reads are strict: a keychain error throws and is never reported as an
/// absent account. Every write reads the item back before it counts. Records
/// are written before the index that lists them and removed after it, so the
/// index is the commit point and a record it doesn't list is never read.
///
/// `TokenStore` caches the active account's credentials and routes every
/// credential change through here. Other writers only touch display fields
/// (profiles, username, last use), which updates merge into the stored record.
final class AccountStore: @unchecked Sendable {
    static let shared = AccountStore()

    /// Shared by every Apple TV user: the household signs in once.
    static let audience: KeychainAudience = .userIndependent
    /// Each Apple TV user's own: a PIN entered by one never opens a profile
    /// for another.
    static let profileTokenAudience: KeychainAudience = .currentUser

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "AccountStore"
    )

    /// One lock for every instance: the app, tests, and migration can build
    /// several stores over the same keychain, and each read-modify-write of
    /// the index must see the others' commits.
    private static let lock = NSRecursiveLock()

    private let readItem: @Sendable (String) throws -> String?
    private let writeItem: @Sendable (String, String) -> Bool
    private let removeItem: @Sendable (String) -> Bool
    private let profileKeychain: SharedKeychain
    private let defaults: SharedDefaults

    init(keychain: SharedKeychain = SharedKeychain(), defaults: SharedDefaults = .shared) {
        let shared = keychain.withAudience(Self.audience)
        readItem = { try shared.getChecked($0) }
        writeItem = { shared.set($0, for: $1) }
        removeItem = { shared.delete($0) }
        profileKeychain = keychain.withAudience(Self.profileTokenAudience)
        self.defaults = defaults
    }

    // MARK: - Index

    /// Nil means the index was never written, so migration hasn't run. An
    /// index that can't be decoded falls back to the backup copy; without
    /// one, it throws. A keychain read error always throws.
    func loadIndex() throws -> AccountIndex? {
        try locked {
            let index = try readIndex()
            publishLegacyDataOwners(index)
            return index
        }
    }

    private func readIndex() throws -> AccountIndex? {
        guard let raw = try readItem(SharedStorage.accountIndexAccount) else { return nil }
        do {
            return try Self.decode(AccountIndex.self, from: raw, currentVersion: AccountIndex.currentVersion)
        } catch AccountStoreError.corrupt {
            Self.logger.error("Account index can't be decoded; trying its backup copy.")
            guard let backup = try readItem(SharedStorage.accountIndexBackupAccount) else {
                throw AccountStoreError.corrupt
            }
            return try Self.decode(AccountIndex.self, from: backup, currentVersion: AccountIndex.currentVersion)
        }
    }

    /// Keeps `LegacyLocalDataOwner` in step with the shared store's index.
    /// Other instances (tests, isolated keychains) don't describe this
    /// device's data.
    private func publishLegacyDataOwners(_ index: AccountIndex?) {
        guard self === Self.shared else { return }
        LegacyLocalDataOwner.publish(index?.legacyDataOwners ?? [:])
        MergedServerIds.publish(index?.mergedServerIds ?? [:], legacyDataOwners: index?.mergedLegacyDataOwners ?? [:])
        MergedAccountIds.publish(index?.mergedAccountIds ?? [:])
    }

    /// Writes the index and reads it back; this write is the commit point.
    /// The backup copy is then rewritten to match. If that write fails, the
    /// backup is removed rather than left older than the index.
    func saveIndex(_ index: AccountIndex) throws {
        guard index.version == AccountIndex.currentVersion else {
            throw AccountStoreError.unsupportedVersion(index.version)
        }
        try locked {
            let raw = try Self.encode(index)
            try writeVerified(raw, to: SharedStorage.accountIndexAccount)
            publishLegacyDataOwners(index)
            if !writeItem(raw, SharedStorage.accountIndexBackupAccount) {
                Self.logger.error("Account index backup write failed; removing the stale backup.")
                if !removeItem(SharedStorage.accountIndexBackupAccount) {
                    Self.logger.error("Stale account index backup could not be removed.")
                }
            }
        }
    }

    // MARK: - Reads

    /// Every saved account, most recently used first. Empty before migration.
    func accounts() throws -> [Account] {
        try locked {
            guard let index = try loadIndex() else { return [] }
            return try index.entries.compactMap { try loadRecord($0) }.sorted(by: Self.mostRecentFirst)
        }
    }

    /// The server's saved accounts, most recently used first.
    func accounts(onServer serverId: String) throws -> [Account] {
        try locked {
            guard let index = try loadIndex() else { return [] }
            return try index.entries
                .filter { $0.serverId == serverId }
                .compactMap { try loadRecord($0) }
                .sorted(by: Self.mostRecentFirst)
        }
    }

    /// Nil when no such account is saved. Throws when its record can't be
    /// read or decoded.
    func account(_ localAccountId: String, onServer serverId: String) throws -> Account? {
        try locked {
            guard let index = try loadIndex() else { return nil }
            let entry = AccountIndex.Entry(serverId: serverId, localAccountId: localAccountId)
            guard index.entries.contains(entry) else { return nil }
            return try loadRecord(entry)
        }
    }

    /// The account requests on `serverId` use: the selected one when it is on
    /// that server, otherwise the server's most recently used account.
    func activeAccount(onServer serverId: String) throws -> Account? {
        try locked {
            if let chosen = selection(), chosen.serverId == serverId,
               let selected = try account(chosen.localAccountId, onServer: serverId) {
                return selected
            }
            return try accounts(onServer: serverId).first
        }
    }

    /// The account that adopted `serverId`'s local data from before accounts
    /// existed. Nil before migration, after that account is gone, and for
    /// servers that had no session to migrate.
    func legacyDataOwner(forServer serverId: String) throws -> String? {
        try loadIndex()?.legacyDataOwners[serverId]
    }

    // MARK: - Selection

    /// The current device user's selected account. Requests use it while its
    /// server is the active one.
    func selection() -> AccountSelection? {
        AccountSelection.load(from: defaults)
    }

    /// Selects `account` for the current device user, or clears the
    /// selection. Returns false when the mirror did not read back.
    @discardableResult
    func select(_ account: Account?) -> Bool {
        guard let account else {
            defaults.removeObject(forKey: SharedStorage.activeAccountKey)
            return defaults.data(forKey: SharedStorage.activeAccountKey) == nil
        }
        let selection = AccountSelection(serverId: account.serverId, localAccountId: account.localAccountId)
        guard selection != self.selection() else { return true }
        guard let data = try? JSONEncoder().encode(selection) else { return false }
        defaults.set(data, forKey: SharedStorage.activeAccountKey)
        return self.selection() == selection
    }

    // MARK: - Sign-in

    /// Saves the tokens a sign-in returned. A sign-in as a server user that
    /// is already saved refreshes that account, keeping its `localAccountId`
    /// and local data; otherwise a new account is added. With
    /// `replacingOtherAccounts`, every other account on the server is removed
    /// in the same commit (one visible account per server).
    ///
    /// Every refresh installs a new epoch and clears `needsSignIn`.
    func saveSignIn(
        serverId: String,
        origin: String,
        serverUserId: String?,
        username: String?,
        accessToken: String,
        refreshToken: String?,
        replacingOtherAccounts: Bool
    ) throws -> AccountSignInResult {
        guard Account.isValidServerId(serverId), !origin.isEmpty, !accessToken.isEmpty,
              serverUserId?.isEmpty != true, refreshToken?.isEmpty != true else {
            throw AccountStoreError.invalidIdentity
        }
        return try locked {
            var index = try loadIndex() ?? AccountIndex()
            let existing = try accounts(onServer: serverId)
            let now = Date()
            // The registry ID is derived from the URL, so a saved account on
            // this server holds the same origin; the check keeps the bearer
            // from ever reaching an address the record wasn't saved for.
            let match = serverUserId.flatMap { id in
                existing.first { $0.serverUserId == id && $0.origin == origin }
            }
            let account: Account
            if var refreshed = match {
                refreshed.accessToken = accessToken
                refreshed.refreshToken = refreshToken
                refreshed.epoch = UUID()
                refreshed.needsSignIn = false
                refreshed.username = username ?? refreshed.username
                refreshed.lastUsedAt = now
                account = refreshed
            } else {
                account = Account(
                    serverId: serverId,
                    origin: origin,
                    serverUserId: serverUserId,
                    username: username,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    epoch: UUID(),
                    addedAt: now,
                    lastUsedAt: now
                )
            }
            try writeRecord(account)

            let removed = replacingOtherAccounts
                ? existing.map(\.localAccountId).filter { $0 != account.localAccountId }
                : []
            let entry = AccountIndex.Entry(serverId: serverId, localAccountId: account.localAccountId)
            let previousIndex = index
            if !index.entries.contains(entry) { index.entries.append(entry) }
            index.entries.removeAll { $0.serverId == serverId && removed.contains($0.localAccountId) }
            if let owner = index.legacyDataOwners[serverId], removed.contains(owner) {
                index.legacyDataOwners[serverId] = nil
            }
            if index != previousIndex {
                do { try saveIndex(index) } catch {
                    // A new record that no index lists is never read; remove it
                    // so its tokens don't linger. A refreshed record already
                    // holds the new tokens, and the caller's rollback puts the
                    // old ones back.
                    if match == nil { removeRecord(entry) }
                    throw error
                }
            }
            for id in removed {
                removeRecord(AccountIndex.Entry(serverId: serverId, localAccountId: id))
            }
            return AccountSignInResult(account: account, refreshedExisting: match != nil, removedAccountIds: removed)
        }
    }

    // MARK: - Credential updates

    /// Stores a rotated token pair, but only while the account still holds
    /// `expected`: a sign-out, a new sign-in, or another rotation since the
    /// caller read it keeps what is stored and throws `.credentialsChanged`.
    func rotateTokens(
        expected: AccountCredentials,
        onServer serverId: String,
        accessToken: String,
        refreshToken: String
    ) throws -> Account {
        guard !accessToken.isEmpty, !refreshToken.isEmpty else { throw AccountStoreError.invalidIdentity }
        return try update(expected.localAccountId, onServer: serverId) { account in
            guard account.credentials == expected, account.isSignedIn else {
                throw AccountStoreError.credentialsChanged
            }
            account.accessToken = accessToken
            account.refreshToken = refreshToken
        }
    }

    /// Records the server user a verified account read named, and the
    /// username it reported. Throws `.invalidIdentity` when the account is
    /// already bound to a different user, or another account on the server
    /// already holds this one, and `.credentialsChanged` when the account's
    /// credentials moved since `expected`.
    func bindServerUser(
        _ serverUserId: String,
        username: String?,
        expected: AccountCredentials,
        onServer serverId: String
    ) throws -> Account {
        guard !serverUserId.isEmpty else { throw AccountStoreError.invalidIdentity }
        return try locked {
            let others = try accounts(onServer: serverId).filter { $0.localAccountId != expected.localAccountId }
            guard !others.contains(where: { $0.serverUserId == serverUserId }) else {
                throw AccountStoreError.invalidIdentity
            }
            return try update(expected.localAccountId, onServer: serverId) { account in
                guard account.credentials == expected else { throw AccountStoreError.credentialsChanged }
                guard account.serverUserId == nil || account.serverUserId == serverUserId else {
                    throw AccountStoreError.invalidIdentity
                }
                account.serverUserId = serverUserId
                if let username, !username.isEmpty { account.username = username }
            }
        }
    }

    /// The server rejected the account's credentials. Its tokens are removed;
    /// the account and its local data stay until the person signs in again
    /// or signs out.
    func markNeedsSignIn(expected: AccountCredentials, onServer serverId: String) throws {
        _ = try update(expected.localAccountId, onServer: serverId) { account in
            guard account.credentials == expected else { throw AccountStoreError.credentialsChanged }
            account.accessToken = nil
            account.refreshToken = nil
            account.epoch = nil
            account.needsSignIn = true
        }
    }

    /// Refreshes the profiles cached for the picker. A no-op when nothing
    /// changed, so callers can pass every fetched list.
    func updateCachedProfiles(_ profiles: [AccountProfile], for localAccountId: String, onServer serverId: String) throws {
        _ = try update(localAccountId, onServer: serverId) { account in
            account.cachedProfiles = profiles
        }
    }

    /// Records that the account was just used. Orders the server's accounts.
    func markUsed(_ localAccountId: String, onServer serverId: String, at date: Date = Date()) throws {
        _ = try update(localAccountId, onServer: serverId) { account in
            account.lastUsedAt = date
        }
    }

    // MARK: - Removal

    /// Signs out of one account: its record, legacy-data ownership, and this
    /// device user's profile proof are removed. Returns the removed
    /// `localAccountId` so callers can delete the local data keyed by it.
    /// Throws when the index can't be committed, in which case nothing changed.
    @discardableResult
    func signOut(_ localAccountId: String, onServer serverId: String) throws -> String {
        try locked {
            let entry = AccountIndex.Entry(serverId: serverId, localAccountId: localAccountId)
            guard var index = try loadIndex(), index.entries.contains(entry) else { return localAccountId }
            index.entries.removeAll { $0 == entry }
            if index.legacyDataOwners[serverId] == localAccountId {
                index.legacyDataOwners[serverId] = nil
            }
            try saveIndex(index)
            removeRecord(entry)
            return localAccountId
        }
    }

    /// Signs out of every account on `serverId` and returns their IDs.
    @discardableResult
    func removeServer(_ serverId: String) throws -> [String] {
        try locked {
            guard var index = try loadIndex() else { return [] }
            let removed = index.entries.filter { $0.serverId == serverId }
            guard !removed.isEmpty || index.legacyDataOwners[serverId] != nil else { return [] }
            index.entries.removeAll { $0.serverId == serverId }
            index.legacyDataOwners[serverId] = nil
            try saveIndex(index)
            removed.forEach(removeRecord)
            return removed.map(\.localAccountId)
        }
    }

    // MARK: - Migration

    /// Writes the accounts migration made from per-server sessions, then the
    /// index that lists them and marks migration done; that write commits
    /// them. Each migrated account adopts its server's local data. A server
    /// the index already lists (signed in while migration was deferred) keeps
    /// its accounts and its migrated session is dropped. Returns the index.
    func commitMigration(_ migrated: [Account], pendingLegacyCleanup: [String]) throws -> AccountIndex {
        try locked {
            var index = try loadIndex() ?? AccountIndex()
            guard !index.legacySessionsMigrated else { return index }
            let listed = Set(index.entries.map(\.serverId))
            let adopted = migrated.filter { !listed.contains($0.serverId) }
            var written: [AccountIndex.Entry] = []
            do {
                for account in adopted {
                    try writeRecord(account)
                    written.append(AccountIndex.Entry(serverId: account.serverId, localAccountId: account.localAccountId))
                }
                index.entries.append(contentsOf: written)
                for entry in written where index.legacyDataOwners[entry.serverId] == nil {
                    index.legacyDataOwners[entry.serverId] = entry.localAccountId
                }
                index.legacySessionsMigrated = true
                index.pendingLegacyCleanup = pendingLegacyCleanup
                try saveIndex(index)
            } catch {
                // Records no index lists are never read; remove their tokens.
                written.forEach(removeRecord)
                throw error
            }
            return index
        }
    }

    /// Records which servers' old credential slots are still to be deleted.
    func setPendingLegacyCleanup(_ serverIds: [String]) throws {
        try locked {
            guard var index = try loadIndex() else { return }
            guard index.pendingLegacyCleanup != serverIds else { return }
            index.pendingLegacyCleanup = serverIds
            try saveIndex(index)
        }
    }

    // MARK: - Server merge

    /// What folding `droppedServerId`'s accounts into `survivorServerId`
    /// does (`ServerRegistry.mergeDuplicateServers`), read from the saved
    /// accounts alone. Every dropped account moves, except one whose server
    /// user already has an account on the survivor: of the two, the
    /// signed-in one stays, else the one in use (the most recently used of
    /// all), else the most recently used, and the other is removed. Running
    /// it again before the commit plans the same merge.
    func planServerMerge(dropping droppedServerId: String, into survivorServerId: String) throws -> AccountServerMerge {
        try locked {
            let index = try loadIndex() ?? AccountIndex()
            var survivors = try accounts(onServer: survivorServerId)
            let inUse = selection()?.localAccountId
            var moved: [Account] = []
            var removed: [AccountServerMerge.Removal] = []
            for account in try accounts(onServer: droppedServerId) {
                guard let user = account.serverUserId,
                      let existing = survivors.first(where: { $0.serverUserId == user }) else {
                    moved.append(account)
                    continue
                }
                if Self.keeps(account, over: existing, inUse: inUse) {
                    moved.append(account)
                    removed.append(.init(account: existing, keptLocalAccountId: account.localAccountId))
                    survivors.removeAll { $0.localAccountId == existing.localAccountId }
                } else {
                    removed.append(.init(account: account, keptLocalAccountId: existing.localAccountId))
                }
            }
            return AccountServerMerge(
                droppedServerId: droppedServerId,
                survivorServerId: survivorServerId,
                moved: moved,
                removed: removed,
                legacyDataOwner: index.legacyDataOwners[droppedServerId]
            )
        }
    }

    /// Commits `merge`: the moved accounts' records are written under the
    /// survivor with `origin`, then one index write lists them there, drops
    /// the dropped server and the removed accounts, hands legacy-data
    /// ownership on, and records the merged ID. Their old records are
    /// deleted after it (`finishServerMergeCleanup`). The current device
    /// user's selection and profile proofs follow the accounts.
    func commitServerMerge(_ merge: AccountServerMerge, origin: String) throws {
        let dropped = merge.droppedServerId, survivor = merge.survivorServerId
        try locked {
            // Before migration, sessions still sit in per-server slots that
            // dropping the server would orphan.
            guard var index = try loadIndex(), index.legacySessionsMigrated else { throw AccountStoreError.notFound }
            for account in merge.moved {
                try writeRecord(Account(
                    localAccountId: account.localAccountId,
                    serverId: survivor,
                    origin: origin,
                    serverUserId: account.serverUserId,
                    username: account.username,
                    accessToken: account.accessToken,
                    refreshToken: account.refreshToken,
                    epoch: account.epoch,
                    cachedProfiles: account.cachedProfiles,
                    addedAt: account.addedAt,
                    lastUsedAt: account.lastUsedAt,
                    needsSignIn: account.needsSignIn
                ))
                if let proof = profileToken(for: account.localAccountId, onServer: dropped),
                   profileToken(for: account.localAccountId, onServer: survivor) == nil {
                    setProfileToken(proof, for: account.localAccountId, onServer: survivor)
                }
            }
            let removedIds = Set(merge.removed.map(\.account.localAccountId))
            let unlisted = index.entries.filter {
                $0.serverId == dropped || ($0.serverId == survivor && removedIds.contains($0.localAccountId))
            }
            index.entries.removeAll { unlisted.contains($0) }
            for account in merge.moved {
                let entry = AccountIndex.Entry(serverId: survivor, localAccountId: account.localAccountId)
                if !index.entries.contains(entry) { index.entries.append(entry) }
            }
            // The dropped server's data from before accounts moved to its
            // owner's place on the survivor (`ServerMerge.moveLocalData`).
            index.legacyDataOwners[dropped] = nil
            if let owner = index.legacyDataOwners[survivor], let kept = merge.keptAccount(for: owner) {
                index.legacyDataOwners[survivor] = kept
            }
            var merged = index.mergedServerIds ?? [:]
            for (id, target) in merged where target == dropped { merged[id] = survivor }
            merged[dropped] = survivor
            merged[survivor] = nil
            index.mergedServerIds = merged
            var mergedAccounts = index.mergedAccountIds ?? [:]
            for removal in merge.removed {
                let removedId = removal.account.localAccountId, keptId = removal.keptLocalAccountId
                for (id, target) in mergedAccounts where target == removedId { mergedAccounts[id] = keptId }
                mergedAccounts[removedId] = keptId
                mergedAccounts[keptId] = nil
            }
            if !mergedAccounts.isEmpty { index.mergedAccountIds = mergedAccounts }
            if let target = merge.legacyDataTarget {
                var owners = index.mergedLegacyDataOwners ?? [:]
                owners[dropped] = target
                index.mergedLegacyDataOwners = owners
            }
            var pending = index.pendingRecordRemovals ?? []
            pending += unlisted.filter { !pending.contains($0) }
            index.pendingRecordRemovals = pending
            try saveIndex(index)

            if let chosen = AccountSelection.load(from: defaults, resolvingMergedServers: false),
               chosen.serverId == dropped || chosen.serverId == survivor {
                let next = AccountSelection(
                    serverId: survivor,
                    localAccountId: merge.keptAccount(for: chosen.localAccountId) ?? chosen.localAccountId
                )
                if next != chosen, let data = try? JSONEncoder().encode(next) {
                    defaults.set(data, forKey: SharedStorage.activeAccountKey)
                }
            }
        }
        finishServerMergeCleanup()
    }

    /// Deletes the records a server merge stopped listing. Retried at every
    /// launch until it completes.
    func finishServerMergeCleanup() {
        locked {
            guard var index = try? loadIndex(), let pending = index.pendingRecordRemovals, !pending.isEmpty else {
                return
            }
            let listed = Set(index.entries)
            pending.filter { !listed.contains($0) }.forEach(removeRecord)
            index.pendingRecordRemovals = nil
            try? saveIndex(index)
        }
    }

    /// A server saved again at an address that was merged into another: it
    /// is its own server from now on, and nothing resolves to the other.
    func forgetMergedServer(_ serverId: String) {
        locked {
            guard var index = try? loadIndex(),
                  index.mergedServerIds?[serverId] != nil || index.mergedLegacyDataOwners?[serverId] != nil else { return }
            index.mergedServerIds?[serverId] = nil
            index.mergedLegacyDataOwners?[serverId] = nil
            try? saveIndex(index)
        }
    }

    // MARK: - Snapshots

    func snapshot(ofServer serverId: String) throws -> AccountServerSnapshot {
        try locked {
            let index = try loadIndex() ?? AccountIndex()
            return AccountServerSnapshot(
                serverId: serverId,
                accounts: try accounts(onServer: serverId),
                legacyDataOwner: index.legacyDataOwners[serverId]
            )
        }
    }

    /// Puts a server's accounts back exactly as `snapshot` holds them:
    /// records are rewritten, accounts added since are removed.
    func restore(_ snapshot: AccountServerSnapshot) throws {
        try locked {
            var index = try loadIndex() ?? AccountIndex()
            for account in snapshot.accounts { try writeRecord(account) }
            let kept = Set(snapshot.accounts.map(\.localAccountId))
            let dropped = index.entries.filter { $0.serverId == snapshot.serverId && !kept.contains($0.localAccountId) }
            index.entries.removeAll { $0.serverId == snapshot.serverId }
            index.entries.append(contentsOf: snapshot.accounts.map {
                AccountIndex.Entry(serverId: snapshot.serverId, localAccountId: $0.localAccountId)
            })
            index.legacyDataOwners[snapshot.serverId] = snapshot.legacyDataOwner.flatMap { kept.contains($0) ? $0 : nil }
            try saveIndex(index)
            dropped.forEach(removeRecord)
        }
    }

    // MARK: - Profile proofs

    /// The current device user's profile verification proof for `account`.
    func profileToken(for localAccountId: String, onServer serverId: String) -> String? {
        profileKeychain.get(SharedStorage.accountProfileTokenAccount(serverID: serverId, localAccountID: localAccountId))
    }

    /// Strict read for snapshots: a keychain error throws.
    func checkedProfileToken(for localAccountId: String, onServer serverId: String) throws -> String? {
        try profileKeychain.getChecked(
            SharedStorage.accountProfileTokenAccount(serverID: serverId, localAccountID: localAccountId)
        )
    }

    @discardableResult
    func setProfileToken(_ token: String?, for localAccountId: String, onServer serverId: String) -> Bool {
        let key = SharedStorage.accountProfileTokenAccount(serverID: serverId, localAccountID: localAccountId)
        if let token { return profileKeychain.set(token, for: key) }
        return profileKeychain.delete(key)
    }

    // MARK: - Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    /// Applies `change` to the stored record, under the lock, and writes it
    /// back. Fields the change leaves alone keep the stored values, so a
    /// display update never undoes a credential change made meanwhile.
    private func update(
        _ localAccountId: String,
        onServer serverId: String,
        _ change: (inout Account) throws -> Void
    ) throws -> Account {
        try locked {
            guard var account = try account(localAccountId, onServer: serverId) else {
                throw AccountStoreError.notFound
            }
            let previous = account
            try change(&account)
            guard account != previous else { return account }
            guard account.isWellFormed else { throw AccountStoreError.invalidIdentity }
            try writeRecord(account)
            return account
        }
    }

    /// Nil when the item is absent: an index entry whose record is gone is
    /// skipped, as if signed out.
    private func loadRecord(_ entry: AccountIndex.Entry) throws -> Account? {
        let key = SharedStorage.accountRecordAccount(serverID: entry.serverId, localAccountID: entry.localAccountId)
        guard let raw = try readItem(key) else {
            Self.logger.error("An indexed account has no record; skipping it.")
            return nil
        }
        let account = try Self.decode(Account.self, from: raw, currentVersion: Account.currentVersion)
        guard account.serverId == entry.serverId, account.localAccountId == entry.localAccountId else {
            throw AccountStoreError.keyMismatch
        }
        guard account.isWellFormed else { throw AccountStoreError.corrupt }
        return account
    }

    private func writeRecord(_ account: Account) throws {
        guard account.version == Account.currentVersion else {
            throw AccountStoreError.unsupportedVersion(account.version)
        }
        guard account.isWellFormed else { throw AccountStoreError.invalidIdentity }
        try writeVerified(
            try Self.encode(account),
            to: SharedStorage.accountRecordAccount(serverID: account.serverId, localAccountID: account.localAccountId)
        )
    }

    /// Removes a record and this device user's proof for it. Failures are
    /// logged only: the index no longer lists the record, so it is never read.
    private func removeRecord(_ entry: AccountIndex.Entry) {
        if !removeItem(SharedStorage.accountRecordAccount(serverID: entry.serverId, localAccountID: entry.localAccountId)) {
            Self.logger.error("An unlisted account record could not be removed.")
        }
        setProfileToken(nil, for: entry.localAccountId, onServer: entry.serverId)
    }

    private func writeVerified(_ raw: String, to account: String) throws {
        guard writeItem(raw, account), try readItem(account) == raw else {
            throw AccountStoreError.writeFailed
        }
    }

    private static func mostRecentFirst(_ lhs: Account, _ rhs: Account) -> Bool {
        if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
        return lhs.addedAt < rhs.addedAt
    }

    /// Of two saved accounts of one server user, the one a merge keeps.
    private static func keeps(_ lhs: Account, over rhs: Account, inUse: String?) -> Bool {
        if lhs.isSignedIn != rhs.isSignedIn { return lhs.isSignedIn }
        if let inUse, lhs.localAccountId == inUse || rhs.localAccountId == inUse {
            return lhs.localAccountId == inUse
        }
        return mostRecentFirst(lhs, rhs)
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    /// Reads the version before the body, so a record from another format
    /// fails closed as unsupported instead of looking corrupt.
    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from raw: String,
        currentVersion: Int
    ) throws -> Value {
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: data) else {
            throw AccountStoreError.corrupt
        }
        guard header.version == currentVersion else {
            throw AccountStoreError.unsupportedVersion(header.version)
        }
        guard let value = try? decoder.decode(Value.self, from: data) else {
            throw AccountStoreError.corrupt
        }
        return value
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension AccountStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .writeFailed:
            return "Sign-in could not be saved on this device. Try again."
        case .unsupportedVersion, .corrupt, .keyMismatch:
            return "The sign-in saved on this device is unreadable. Sign in again."
        case .invalidIdentity, .notFound, .credentialsChanged:
            return "The active server changed before sign-in could be saved."
        }
    }
}
