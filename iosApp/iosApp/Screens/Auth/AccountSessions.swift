import Foundation

/// Why switching to a saved account did not happen.
enum AccountSwitchError: LocalizedError {
    case serverSwitchFailed
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .serverSwitchFailed: "Couldn't switch to that server. Try again."
        case .accountUnavailable: "That account needs to sign in again."
        }
    }
}

/// Moving between, signing out of, and removing the saved accounts listed
/// in Change Account and Settings › Accounts. Shared by every platform; the screens decide what to
/// ask first and where to go after.
///
/// Every step reuses an existing identity boundary: a server switch through
/// `ServerRegistry.switchTo`, an account switch under the HTTP identity gate
/// with diagnostics closed (as a server switch does), and the active
/// account's sign-out through `AuthService.signOut()`.
@MainActor
enum AccountSessions {
    /// Makes `localAccountId` on `serverId` the account requests use,
    /// switching server first when needed. No profile is selected after it.
    /// The server's push installation follows the account
    /// (`TokenStore.switchActiveAccount`).
    static func switchTo(account localAccountId: String, onServer serverId: String) async throws {
        guard !(await TokenStore.shared.hasTemporaryScope()) else {
            throw ProfileTransitionError.temporaryIdentityActive
        }
        let registry = ServerRegistry.shared
        if registry.activeServerId != serverId {
            guard await registry.switchTo(serverId: serverId) else { throw AccountSwitchError.serverSwitchFailed }
        }
        defer { AccountDirectory.shared.reload() }
        // Already the account requests send: nothing to switch. A server
        // whose account was just signed out loads none until one is chosen.
        guard await TokenStore.shared.refreshAccountIdentity()?.localAccountId != localAccountId else { return }
        guard let lease = await HTTPClient.shared.beginIdentityTransition() else { throw CancellationError() }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await HTTPClient.shared.cancelInFlightRequests()
        let switched = await TokenStore.shared.switchActiveAccount(localAccountId: localAccountId)
        if switched {
            // An account boundary is as hard as a server one: nothing cached
            // in memory for the previous account may show for this one. Its
            // saved snapshots stay, keyed by account.
            AuthService.shared.clearCachesForAccountChange()
        }
        await HTTPClient.shared.endIdentityTransition(lease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        guard switched else { throw AccountSwitchError.accountUnavailable }
        await registry.refreshFeaturesAfterGatedServerSwitch()
    }

    /// Signs out of one saved account (spec §4.4): deletes its downloads and
    /// local data first, while it still owns them, then removes its
    /// credentials, turns its push installation off, and revokes its session.
    /// Other accounts, including others on the same server, are untouched,
    /// and the server stays saved.
    ///
    /// The account requests use signs out through `AuthService.signOut()`;
    /// any other account is removed without touching the session in use.
    static func signOut(account localAccountId: String, onServer serverId: String) async -> AuthService.SignOutOutcome {
        let tokenStore = TokenStore.shared
        guard !(await tokenStore.hasTemporaryScope()),
              let account = try? AccountStore.shared.account(localAccountId, onServer: serverId) else { return .refused }
        await deleteLocalData(of: account)

        defer { AccountDirectory.shared.reload() }
        // Read after the deletion, which suspends: an account switch
        // meanwhile changes which path signs this account out.
        // Only a loaded session signs out through AuthService; a selected
        // account that needs to sign in again has none and signs out below.
        if await tokenStore.loadedAccountId(onServer: serverId) == localAccountId {
            return await AuthService.shared.signOut(expecting: localAccountId).outcome
        }

        #if os(iOS)
        // Another server's last-used account holds that server's push
        // installation; the account used there next takes it back.
        let pushHolder = await tokenStore.savedSessionAccount(for: serverId)?.localAccountID
        let holdsPush = ServerRegistry.shared.activeServerId != serverId && pushHolder == localAccountId
        if holdsPush {
            await ApplePushRegistrationCoordinator.shared.unregister(serverID: serverId, signingOutActiveAccount: true)
        }
        #endif
        let result = await tokenStore.signOutInactiveAccount(localAccountId, onServer: serverId)
        guard result.durable else {
            #if os(iOS)
            if holdsPush { await ApplePushRegistrationCoordinator.shared.restore(serverID: serverId) }
            #endif
            return .refused
        }
        ProfileLaunchPreferences.shared.clearRememberedProfile(forAccount: localAccountId)
        revoke(account)
        return .completed
    }

    /// Removes a saved server: every account on it is signed out (its
    /// downloads and local data deleted, its session revoked), then the
    /// server and its credentials are forgotten. `onlyIf` is checked again
    /// just before the removal commits (`ServerRegistry.remove`).
    static func removeServer(_ serverId: String, onlyIf stillRemovable: (@MainActor () -> Bool)? = nil) async -> Bool {
        guard !(await TokenStore.shared.hasTemporaryScope()) else { return false }
        let accounts = (try? AccountStore.shared.accounts(onServer: serverId)) ?? []
        for account in accounts { await deleteLocalData(of: account) }
        let wasActive = ServerRegistry.shared.activeServerId == serverId
        let removed = await ServerRegistry.shared.remove(serverId: serverId, resolveFallbackProfile: wasActive,
                                                         onlyIf: stillRemovable)
        if removed { accounts.forEach(revoke) }
        AccountDirectory.shared.reload()
        return removed
    }

    /// Whether no account, signed in or waiting to sign in again, is saved
    /// on `serverId`. False when the account index can't be read or the
    /// accounts aren't migrated yet, so a server is never removed on a guess.
    static func hasNoAccounts(onServer serverId: String) -> Bool {
        guard let index = try? AccountStore.shared.loadIndex(), index.legacySessionsMigrated else { return false }
        return !index.entries.contains { $0.serverId == serverId }
    }

    /// Removes saved servers with no account on them: a server isn't kept
    /// once its last account is gone (spec §4.4). Earlier builds kept one
    /// after a sign-out, and the migration makes accounts only from saved
    /// sessions. Runs at launch, after the migration and the duplicate-server
    /// merge (`ServerRegistry.init`), before the route is read. The active
    /// server stays while no account is signed in, since launch opens its
    /// sign-in. Such a server has no session to revoke.
    ///
    /// Only the active server, which the route reads, is removed before
    /// this returns (and the one the registry falls back to, until one has
    /// an account). The others go after, without holding up launch: each
    /// removal can wait seconds to turn its server's pushes off.
    static func removeServersWithoutAccounts() async {
        let registry = ServerRegistry.shared
        let keepsActive = AppRouter.signedOutDestination(activeServerId: registry.activeServerId) != .changeAccount
        while !keepsActive, let activeId = registry.activeServerId, hasNoAccounts(onServer: activeId) {
            guard await removeServer(activeId) else { break }
        }
        let activeId = registry.activeServerId
        let others = registry.entries.map(\.id).filter { $0 != activeId && hasNoAccounts(onServer: $0) }
        guard !others.isEmpty else { return }
        Task {
            // Checked again: one may have been opened, or signed in to, since,
            // including while its removal waits to turn its pushes off.
            for serverId in others {
                let stillRemovable: @MainActor () -> Bool = {
                    serverId != registry.activeServerId && hasNoAccounts(onServer: serverId)
                }
                guard stillRemovable() else { continue }
                _ = await removeServer(serverId, onlyIf: stillRemovable)
            }
        }
    }

    /// How many downloads `localAccountId` keeps on this device, for the
    /// sign-out confirmation. Nil where there are no downloads (tvOS).
    static func downloadSummary(account localAccountId: String, onServer serverId: String) async -> DownloadAccountSummary? {
        #if os(tvOS)
        return nil
        #else
        return await DownloadManager.shared.downloadSummary(forAccount: localAccountId, serverId: serverId)
        #endif
    }

    /// Before an "add an account" sign-in: an account migrated without its
    /// server user is verified first, so signing in as that same person
    /// refreshes it instead of adding a duplicate (spec §5). Best effort:
    /// when the check can't run, the accounts are treated as different.
    static func verifyActiveAccountIfNeeded() async {
        guard AuthService.shared.isLoggedIn, AuthService.shared.accountID == nil else { return }
        _ = try? await AuthService.shared.currentAccount()
    }

    // MARK: - Private

    /// Downloads and local data go before the account record: the record's
    /// legacy-data ownership decides what else is the account's.
    private static func deleteLocalData(of account: Account) async {
        let ownsLegacyData = LegacyLocalDataOwner.localAccountId(forServer: account.serverId) == account.localAccountId
        #if !os(tvOS)
        await DownloadManager.shared.deleteAllDownloads(forAccount: account.localAccountId, serverId: account.serverId)
        #endif
        AccountLocalData.purge(localAccountId: account.localAccountId, serverId: account.serverId,
                               ownedLegacyData: ownsLegacyData)
    }

    /// Ends the signed-out account's session on its server, by its own
    /// bearer. Best effort: local sign-out never waits on the network.
    private static func revoke(_ account: Account) {
        guard let token = account.accessToken, !token.isEmpty else { return }
        let origin = account.origin
        Task { await HTTPClient.shared.revokeSession(accessToken: token, serverURL: origin) }
    }
}
