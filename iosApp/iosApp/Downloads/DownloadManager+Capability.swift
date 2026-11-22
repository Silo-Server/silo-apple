import Foundation

/// Pure rules for the download capability check: which scope the store loads
/// and when to read the capability again. `DownloadManager` owns the state;
/// these stay free of it so tests can pin them down.
extension DownloadManager {
    /// The account requests run as (`TokenStore.captureOrdinaryRequestAuth`).
    /// `localAccountId` is nil without a signed-in session, and under a
    /// temporary remote scope.
    struct SignedInIdentity: Equatable {
        let serverId: String
        let localAccountId: String?
        let profileId: String?
    }

    /// The `(server, account, profile)` whose store to load. Empty fields
    /// mean no scope.
    struct ScopeChoice: Equatable {
        let serverId: String
        let localAccountId: String
        let profileId: String
        /// The selection mirror was missing or named another account than
        /// the session. Logged: it is the state that used to leave
        /// Download hidden until a relaunch.
        let selectionDisagreed: Bool
    }

    /// The signed-in account wins, because `captureScopeOwner` only lets a
    /// store read the server under that same identity. A store loaded for
    /// the mirror's account while requests ran as another could never read
    /// its capability. Without a session, the mirror keeps the selected
    /// account's downloads playable offline.
    ///
    /// When the selection names the session's account, its profile wins:
    /// both come from the same stored profile, and the selection is read
    /// after the session capture's await, so it sees a Who's Watching pick
    /// or profile switch that landed during it.
    nonisolated static func downloadScope(
        activeServerId: String,
        signedIn: SignedInIdentity?,
        selection: AccountScope?
    ) -> ScopeChoice {
        if !activeServerId.isEmpty, let signedIn, signedIn.serverId == activeServerId,
           let account = signedIn.localAccountId, !account.isEmpty {
            let agrees = selection?.serverId == activeServerId && selection?.localAccountId == account
            return ScopeChoice(
                serverId: activeServerId,
                localAccountId: account,
                profileId: (agrees ? selection?.profileId : signedIn.profileId) ?? "",
                selectionDisagreed: !agrees
            )
        }
        let onServer = selection?.serverId == activeServerId ? selection : nil
        return ScopeChoice(
            serverId: activeServerId,
            localAccountId: onServer?.localAccountId ?? "",
            profileId: onServer?.profileId ?? "",
            selectionDisagreed: false
        )
    }

    /// How long a capability answer counts as fresh for a detail page.
    nonisolated static let capabilityMaxAge: TimeInterval = 5 * 60

    /// Whether to read the capability again. A missing answer is always
    /// read: Download stays hidden until there is one. Any answer the server
    /// gave, including "not for this account", is trusted for `maxAge`.
    nonisolated static func capabilityReadIsDue(hasAnswer: Bool, fetchedAt: Date?, now: Date,
                                                maxAge: TimeInterval = capabilityMaxAge) -> Bool {
        guard hasAnswer, let fetchedAt, fetchedAt <= now else { return true }
        return now.timeIntervalSince(fetchedAt) >= maxAge
    }
}
